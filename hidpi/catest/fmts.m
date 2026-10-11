// fmts: the same partial-redraw scene as partial.m, once per pixel format, on a plain texture and on an IOSurface texture
// (a linear image over shared VRAM once the surface has >= NVMTL_SURF_SHARE_MINPX pixels). Window shape masks and text
// masks are single-channel (A8/R8) in WindowServer, so formats matter. Compares the GPU view (getBytes) of both targets and
// the surface's CPU pages after the GPU is done.   usage: fmts [W H]
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurface.h>
static NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
 "struct V { float4 p [[position]]; float2 uv; };\n"
 "vertex V vs(uint i [[vertex_id]], constant float2 *pts [[buffer(0)]]) { V o; o.p = float4(pts[i], 0, 1); o.uv = pts[i] * float2(0.5, -0.5) + 0.5; return o; }\n"
 "fragment float4 fs(constant float4 &c [[buffer(0)]]) { return c; }\n";
static id<MTLDevice> dev; static id<MTLCommandQueue> q; static id<MTLLibrary> lib;
static const float QUAD[] = { -1, -1, 1, -1, -1, 1, 1, -1, 1, 1, -1, 1 };
static void fill(id<MTLTexture> t, MTLPixelFormat pf, MTLLoadAction la, MTLClearColor cc, BOOL blend, const float col[4], const MTLScissorRect *sc) {
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new]; pd.vertexFunction = [lib newFunctionWithName:@"vs"]; pd.fragmentFunction = [lib newFunctionWithName:@"fs"];
    pd.colorAttachments[0].pixelFormat = pf;
    if (blend) { pd.colorAttachments[0].blendingEnabled = YES; pd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
        pd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha; pd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
        pd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha; }
    NSError *e = nil; id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:pd error:&e]; if (!ps) { printf("pso(%lu): %s\n", (unsigned long)pf, e.description.UTF8String); exit(1); }
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = t; rp.colorAttachments[0].loadAction = la; rp.colorAttachments[0].clearColor = cc; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLRenderCommandEncoder> en = [cb renderCommandEncoderWithDescriptor:rp];
    [en setRenderPipelineState:ps]; [en setVertexBytes:QUAD length:sizeof QUAD atIndex:0]; if (sc) [en setScissorRect:*sc];
    [en setFragmentBytes:col length:16 atIndex:0]; [en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6]; [en endEncoding]; [cb commit]; [cb waitUntilCompleted];
}
int main(int argc, char **argv) { @autoreleasepool {
    dev = MTLCreateSystemDefaultDevice(); q = [dev newCommandQueue];
    NSError *e = nil; lib = [dev newLibraryWithSource:src options:nil error:&e]; if (!lib) { printf("lib: %s\n", e.description.UTF8String); return 1; }
    const int W = argc > 2 ? atoi(argv[1]) : 288, H = argc > 2 ? atoi(argv[2]) : 32; int bad = 0;
    struct { const char *n; MTLPixelFormat pf; uint32_t code; int bpp; } F[] = {
        { "BGRA8",   MTLPixelFormatBGRA8Unorm,  'BGRA', 4 }, { "RGBA8",   MTLPixelFormatRGBA8Unorm,  'RGBA', 4 },
        { "R8",      MTLPixelFormatR8Unorm,     'L008', 1 }, { "A8",      MTLPixelFormatA8Unorm,     'L008', 1 },
        { "RGBA16F", MTLPixelFormatRGBA16Float, 'RGhA', 8 }, { "BGR10A2", MTLPixelFormatBGR10A2Unorm,'l10r', 4 } };
    for (unsigned fi = 0; fi < sizeof F / sizeof *F; fi++) {
        uint8_t *img[2] = { 0, 0 }, *cpu = NULL; size_t n = (size_t)W * H * F[fi].bpp; int skipped = 0;
        for (int target = 0; target < 2 && !skipped; target++) {
            MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:F[fi].pf width:W height:H mipmapped:NO];
            td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead; td.storageMode = MTLStorageModeShared;
            IOSurfaceRef s = NULL; id<MTLTexture> t;
            if (target) { const size_t pitch = ((size_t)W * F[fi].bpp + 63) & ~(size_t)63;
                s = IOSurfaceCreate((__bridge CFDictionaryRef)@{ (id)kIOSurfaceWidth: @(W), (id)kIOSurfaceHeight: @(H), (id)kIOSurfaceBytesPerElement: @(F[fi].bpp),
                    (id)kIOSurfaceBytesPerRow: @(pitch), (id)kIOSurfacePixelFormat: @(F[fi].code) });
                if (!s) { skipped = 1; break; }
                t = [dev newTextureWithDescriptor:td iosurface:s plane:0]; if (!t) { skipped = 1; CFRelease(s); break; }
            } else t = [dev newTextureWithDescriptor:td];
            MTLScissorRect sc = { (NSUInteger)(W / 5 + 3), (NSUInteger)(H / 4 + 1), (NSUInteger)(W / 2 + 7), (NSUInteger)(H / 2 + 5) };
            const float a[4] = { 0.5f, 0.5f, 0.5f, 0.25f }, b[4] = { 0.9f, 0.1f, 0.1f, 0.75f };
            fill(t, F[fi].pf, MTLLoadActionClear, MTLClearColorMake(0, 0, 0, 0), NO, a, NULL);                // frame 1, full
            fill(t, F[fi].pf, MTLLoadActionLoad, MTLClearColorMake(0, 0, 0, 0), YES, b, &sc);                 // frame 2, damaged rect, blended over frame 1
            img[target] = malloc(n); [t getBytes:img[target] bytesPerRow:(size_t)W * F[fi].bpp fromRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0];
            if (target) { IOSurfaceLock(s, kIOSurfaceLockReadOnly, NULL); const uint8_t *base = IOSurfaceGetBaseAddress(s); size_t row = IOSurfaceGetBytesPerRow(s);
                cpu = malloc(n); for (int y = 0; y < H; y++) memcpy(cpu + (size_t)y * W * F[fi].bpp, base + y * row, (size_t)W * F[fi].bpp);
                IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL); CFRelease(s); }
        }
        if (skipped) { printf("%-8s %dx%d: surface/texture unsupported, skipped\n", F[fi].n, W, H); continue; }
        size_t d1 = 0, d2 = 0; int m1 = 0, m2 = 0;
        for (size_t i = 0; i < n; i++) { int d = abs(img[0][i] - img[1][i]); if (d > 2) d1++; if (d > m1) m1 = d; int c = abs(img[0][i] - cpu[i]); if (c > 2) d2++; if (c > m2) m2 = c; }
        printf("%-8s %dx%d: GPU view vs plain: %zu bytes differ (max %d) %s | CPU pages vs plain: %zu differ (max %d) %s\n", F[fi].n, W, H, d1, m1, d1 ? "MISMATCH" : "ok", d2, m2, d2 ? "MISMATCH" : "ok");
        bad += (d1 != 0) + (d2 != 0); free(img[0]); free(img[1]); free(cpu);
    }
    printf("mismatches: %d\n", bad); return 0;
}}
