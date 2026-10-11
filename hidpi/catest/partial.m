// partial: what WindowServer does when it re-composites an exposed window: load the previous contents, redraw only a
// damaged rect, copy a sub-rect out as a backdrop, and sample a GPU-written surface. Runs each case on a plain texture and
// on an IOSurface texture (a linear image over shared VRAM when the surface is big enough) and prints mismatches.
// usage: partial [W H]
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurface.h>
static NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
 "struct V { float4 p [[position]]; float2 uv; };\n"
 "vertex V vs(uint i [[vertex_id]], constant float2 *pts [[buffer(0)]]) { V o; o.p = float4(pts[i], 0, 1); o.uv = pts[i] * float2(0.5, -0.5) + 0.5; return o; }\n"
 "fragment float4 fs(constant float4 &c [[buffer(0)]]) { return c; }\n"
 "fragment float4 fsamp(V in [[stage_in]], texture2d<float> t [[texture(0)]]) { constexpr sampler s(filter::linear, address::clamp_to_edge); return t.sample(s, in.uv); }\n";
static id<MTLDevice> dev; static id<MTLCommandQueue> q; static id<MTLLibrary> lib;
static const float QUAD[] = { -1, -1, 1, -1, -1, 1, 1, -1, 1, 1, -1, 1 };
static id<MTLRenderPipelineState> pso(NSString *fsn, BOOL blend) {
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new]; pd.vertexFunction = [lib newFunctionWithName:@"vs"]; pd.fragmentFunction = [lib newFunctionWithName:fsn];
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    if (blend) { pd.colorAttachments[0].blendingEnabled = YES; pd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
        pd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha; pd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
        pd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha; }
    NSError *e = nil; id<MTLRenderPipelineState> p = [dev newRenderPipelineStateWithDescriptor:pd error:&e]; if (!p) { printf("pso: %s\n", e.description.UTF8String); exit(1); } return p;
}
static void fill(id<MTLTexture> t, MTLLoadAction la, MTLClearColor cc, id<MTLRenderPipelineState> ps, const float col[4], const MTLScissorRect *sc, id<MTLTexture> sampled) {
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = t; rp.colorAttachments[0].loadAction = la; rp.colorAttachments[0].clearColor = cc; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLRenderCommandEncoder> en = [cb renderCommandEncoderWithDescriptor:rp];
    [en setRenderPipelineState:ps]; [en setVertexBytes:QUAD length:sizeof QUAD atIndex:0];
    if (sc) [en setScissorRect:*sc];
    if (sampled) [en setFragmentTexture:sampled atIndex:0]; else [en setFragmentBytes:col length:16 atIndex:0];
    [en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6]; [en endEncoding]; [cb commit]; [cb waitUntilCompleted];
}
static uint8_t *readback(id<MTLTexture> t, int W, int H) { uint8_t *b = malloc((size_t)W * H * 4); [t getBytes:b bytesPerRow:W * 4 fromRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0]; return b; }
static id<MTLTexture> mk(int target, int W, int H, IOSurfaceRef *out) {
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:W height:H mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead; td.storageMode = MTLStorageModeShared;
    if (!target) { *out = NULL; return [dev newTextureWithDescriptor:td]; }
    const size_t pitch = ((size_t)W * 4 + 63) & ~(size_t)63;
    IOSurfaceRef s = IOSurfaceCreate((__bridge CFDictionaryRef)@{ (id)kIOSurfaceWidth: @(W), (id)kIOSurfaceHeight: @(H), (id)kIOSurfaceBytesPerElement: @4,
        (id)kIOSurfaceBytesPerRow: @(pitch), (id)kIOSurfacePixelFormat: @((uint32_t)'BGRA') });
    *out = s; return [dev newTextureWithDescriptor:td iosurface:s plane:0];
}
int main(int argc, char **argv) { @autoreleasepool {
    dev = MTLCreateSystemDefaultDevice(); q = [dev newCommandQueue];
    NSError *e = nil; lib = [dev newLibraryWithSource:src options:nil error:&e]; if (!lib) { printf("lib: %s\n", e.description.UTF8String); return 1; }
    const int W = argc > 2 ? atoi(argv[1]) : 288, H = argc > 2 ? atoi(argv[2]) : 32; int bad = 0;
    id<MTLRenderPipelineState> opaque = pso(@"fs", NO), blend = pso(@"fs", YES), samp = pso(@"fsamp", NO);
    const char *nm[] = { "load + scissor redraw", "load + blend over previous", "blit sub-rect out (backdrop)", "sample GPU-written surface", "clear transparent, scissor draw, load again" };
    for (int cs = 0; cs < 5; cs++) {
        uint8_t *img[2] = { 0, 0 };
        for (int target = 0; target < 2; target++) {
            IOSurfaceRef s = NULL; id<MTLTexture> t = mk(target, W, H, &s); const float red[4] = { 0.9f, 0.1f, 0.1f, 1 }, half[4] = { 0.1f, 0.4f, 0.9f, 0.5f };
            MTLScissorRect sc = { (NSUInteger)(W / 5 + 3), (NSUInteger)(H / 4 + 1), (NSUInteger)(W / 2 + 7), (NSUInteger)(H / 2 + 5) };
            const float grey[4] = { 0.5f, 0.5f, 0.5f, 1 };
            if (cs == 0) { fill(t, MTLLoadActionClear, MTLClearColorMake(0.5, 0.5, 0.5, 1), opaque, grey, NULL, nil);   // frame 1: full
                           fill(t, MTLLoadActionLoad, MTLClearColorMake(0, 0, 0, 0), opaque, red, &sc, nil); img[target] = readback(t, W, H); }
            if (cs == 1) { fill(t, MTLLoadActionClear, MTLClearColorMake(0.5, 0.5, 0.5, 1), opaque, grey, NULL, nil);
                           fill(t, MTLLoadActionLoad, MTLClearColorMake(0, 0, 0, 0), blend, half, NULL, nil); img[target] = readback(t, W, H); }
            if (cs == 2) { fill(t, MTLLoadActionClear, MTLClearColorMake(0.2, 0.7, 0.3, 1), opaque, grey, NULL, nil);
                           fill(t, MTLLoadActionLoad, MTLClearColorMake(0, 0, 0, 0), opaque, red, &sc, nil);
                           const int bw = W / 3 + 5, bh = H / 3 + 3, ox = W / 7 + 1, oy = H / 9 + 1;
                           MTLTextureDescriptor *bd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:bw height:bh mipmapped:NO];
                           bd.storageMode = MTLStorageModePrivate; bd.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget; id<MTLTexture> bt = [dev newTextureWithDescriptor:bd];
                           id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
                           [be copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(ox, oy, 0) sourceSize:MTLSizeMake(bw, bh, 1) toTexture:bt destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
                           [be endEncoding]; [cb commit]; [cb waitUntilCompleted];
                           MTLTextureDescriptor *od = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:bw height:bh mipmapped:NO]; od.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead; od.storageMode = MTLStorageModeShared;
                           id<MTLTexture> ot = [dev newTextureWithDescriptor:od]; fill(ot, MTLLoadActionDontCare, MTLClearColorMake(0, 0, 0, 0), samp, NULL, NULL, bt);
                           img[target] = readback(ot, bw, bh); if (!target) { printf("   (backdrop %dx%d at %d,%d)\n", bw, bh, ox, oy); } }
            if (cs == 3) { fill(t, MTLLoadActionClear, MTLClearColorMake(0.5, 0.5, 0.5, 1), opaque, grey, NULL, nil); fill(t, MTLLoadActionLoad, MTLClearColorMake(0, 0, 0, 0), opaque, red, &sc, nil);
                           MTLTextureDescriptor *od = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:W height:H mipmapped:NO]; od.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead; od.storageMode = MTLStorageModeShared;
                           id<MTLTexture> ot = [dev newTextureWithDescriptor:od]; fill(ot, MTLLoadActionDontCare, MTLClearColorMake(0, 0, 0, 0), samp, NULL, NULL, t); img[target] = readback(ot, W, H); }
            if (cs == 4) { MTLScissorRect in = { (NSUInteger)(W / 10), (NSUInteger)(H / 10), (NSUInteger)(W * 4 / 5), (NSUInteger)(H * 4 / 5) };
                           fill(t, MTLLoadActionClear, MTLClearColorMake(0, 0, 0, 0), opaque, grey, &in, nil);                       // transparent corners, like a window shape
                           fill(t, MTLLoadActionLoad, MTLClearColorMake(0, 0, 0, 0), opaque, red, &sc, nil);
                           fill(t, MTLLoadActionLoad, MTLClearColorMake(0, 0, 0, 0), blend, half, &sc, nil); img[target] = readback(t, W, H); }
            if (s) CFRelease(s);
        }
        int w = cs == 2 ? W / 3 + 5 : W, h = cs == 2 ? H / 3 + 3 : H, diff = 0, maxd = 0;
        for (int i = 0; i < w * h * 4; i++) { int d = abs(img[0][i] - img[1][i]); if (d > 2) diff++; if (d > maxd) maxd = d; }
        printf("%-44s %dx%d: %d bytes differ (max %d) %s\n", nm[cs], W, H, diff, maxd, diff ? "MISMATCH" : "ok"); bad += diff != 0; free(img[0]); free(img[1]);
    }
    printf("mismatching cases: %d\n", bad); return 0;
}}
