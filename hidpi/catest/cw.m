// cw: a compute kernel writes a pattern into a ShaderWrite texture, once on a plain texture and once on an IOSurface texture
// (a linear image over shared VRAM when the surface has >= NVMTL_SURF_SHARE_MINPX pixels). WindowServer's blur / vibrancy
// passes are compute or storage writes; a storage write the driver cannot honour is silently lost.   usage: cw [W H]
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurface.h>
static NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
 "kernel void kw4(texture2d<float, access::write> o [[texture(0)]], uint2 g [[thread_position_in_grid]]) {\n"
 "  if (g.x >= o.get_width() || g.y >= o.get_height()) return; o.write(float4(float(g.x % 251) / 251.0, float(g.y % 241) / 241.0, 0.5, 1.0), g); }\n"
 "kernel void kw1(texture2d<float, access::write> o [[texture(0)]], uint2 g [[thread_position_in_grid]]) {\n"
 "  if (g.x >= o.get_width() || g.y >= o.get_height()) return; o.write(float4(float((g.x + g.y) % 251) / 251.0, 0, 0, float((g.x + g.y) % 251) / 251.0), g); }\n";
int main(int argc, char **argv) { @autoreleasepool {
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice(); id<MTLCommandQueue> q = [dev newCommandQueue]; NSError *e = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:src options:nil error:&e]; if (!lib) { printf("lib: %s\n", e.description.UTF8String); return 1; }
    const int W = argc > 2 ? atoi(argv[1]) : 288, H = argc > 2 ? atoi(argv[2]) : 32; int bad = 0;
    struct { const char *n; MTLPixelFormat pf; uint32_t code; int bpp; const char *k; } F[] = {
        { "BGRA8",   MTLPixelFormatBGRA8Unorm,  'BGRA', 4, "kw4" }, { "RGBA8",   MTLPixelFormatRGBA8Unorm,  'RGBA', 4, "kw4" },
        { "R8",      MTLPixelFormatR8Unorm,     'L008', 1, "kw1" }, { "A8",      MTLPixelFormatA8Unorm,     'L008', 1, "kw1" },
        { "RGBA16F", MTLPixelFormatRGBA16Float, 'RGhA', 8, "kw4" } };
    for (unsigned fi = 0; fi < sizeof F / sizeof *F; fi++) {
        uint8_t *img[2] = { 0, 0 }; const size_t n = (size_t)W * H * F[fi].bpp; int skipped = 0; int nz[2] = { 0, 0 };
        id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@(F[fi].k)] error:&e]; if (!ps) { printf("cps: %s\n", e.description.UTF8String); return 1; }
        for (int target = 0; target < 2 && !skipped; target++) {
            MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:F[fi].pf width:W height:H mipmapped:NO];
            td.usage = MTLTextureUsageShaderWrite | MTLTextureUsageShaderRead; td.storageMode = MTLStorageModeShared;
            IOSurfaceRef s = NULL; id<MTLTexture> t;
            if (target) { const size_t pitch = ((size_t)W * F[fi].bpp + 63) & ~(size_t)63;
                s = IOSurfaceCreate((__bridge CFDictionaryRef)@{ (id)kIOSurfaceWidth: @(W), (id)kIOSurfaceHeight: @(H), (id)kIOSurfaceBytesPerElement: @(F[fi].bpp),
                    (id)kIOSurfaceBytesPerRow: @(pitch), (id)kIOSurfacePixelFormat: @(F[fi].code) });
                if (!s) { skipped = 1; break; }
                t = [dev newTextureWithDescriptor:td iosurface:s plane:0]; if (!t) { skipped = 1; CFRelease(s); break; }
            } else t = [dev newTextureWithDescriptor:td];
            id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLComputeCommandEncoder> en = [cb computeCommandEncoder];
            [en setComputePipelineState:ps]; [en setTexture:t atIndex:0];
            [en dispatchThreads:MTLSizeMake(W, H, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)]; [en endEncoding]; [cb commit]; [cb waitUntilCompleted];
            img[target] = malloc(n); [t getBytes:img[target] bytesPerRow:(size_t)W * F[fi].bpp fromRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0];
            for (size_t i = 0; i < n; i++) nz[target] += img[target][i] != 0;
            if (s) CFRelease(s);
        }
        if (skipped) { printf("%-8s %dx%d: unsupported, skipped\n", F[fi].n, W, H); continue; }
        size_t d = 0; int m = 0; for (size_t i = 0; i < n; i++) { int c = abs(img[0][i] - img[1][i]); if (c > 2) d++; if (c > m) m = c; }
        printf("%-8s %dx%d: compute write vs plain: %zu bytes differ (max %d), non-zero bytes plain %d / iosurface %d %s\n", F[fi].n, W, H, d, m, nz[0], nz[1], d ? "MISMATCH" : "ok");
        bad += d != 0; free(img[0]); free(img[1]);
    }
    printf("mismatches: %d\n", bad); return 0;
}}
