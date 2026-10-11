// rshtest: the tiled render shadow of shared-VRAM IOSurface render targets (plugin: draws such a surface into a private
// tiled image and copies it back when anything else could look). Each case records one command buffer that mixes
// render encoders on a window-sized IOSurface with the other ways of reading or writing it, once on the IOSurface and
// once on a plain private texture (the reference), and compares the final pixels - texture readback AND surface pages.
// usage: rshtest [plugin] [W H]   prints one line per case and PASS / FAIL
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurface.h>
#import <IOKit/IOKitLib.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
static NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
 "struct V { float4 p [[position]]; float2 uv; };\n"
 "vertex V vs(uint i [[vertex_id]], constant float4 &r [[buffer(0)]]) {\n"
 "  float2 k = float2((i == 1 || i == 2 || i == 4) ? 1 : 0, (i == 2 || i == 4 || i == 5) ? 1 : 0);\n"
 "  V o; o.p = float4(mix(r.xy, r.zw, k), 0, 1); o.uv = k; return o; }\n"
 "fragment float4 fcol(constant float4 &c [[buffer(0)]]) { return c; }\n"
 "struct VC { float4 p [[position]]; float4 c; };\n"
 "vertex VC vstex(uint i [[vertex_id]], constant float4 &r [[buffer(0)]], texture2d<float> t [[texture(0)]]) {\n"
 "  float2 k = float2((i == 1 || i == 2 || i == 4) ? 1 : 0, (i == 2 || i == 4 || i == 5) ? 1 : 0);\n"
 "  VC o; o.p = float4(mix(r.xy, r.zw, k), 0, 1); o.c = t.read(uint2(t.get_width() / 2 + i * 50, t.get_height() / 3)); return o; }\n"
 "fragment float4 fvc(VC v [[stage_in]]) { return v.c; }\n"
 // samples a texture with an offset: makes reading the target visible (feedback / copy-through cases)
 "fragment float4 ftex(V v [[stage_in]], texture2d<float> t [[texture(0)]], constant float4 &c [[buffer(0)]]) {\n"
 "  constexpr sampler s(filter::nearest); float2 sz = float2(t.get_width(), t.get_height());\n"
 "  return t.sample(s, (v.p.xy + float2(37, 11)) / sz) * c.w + float4(c.xyz, 0) * (1 - c.w); }\n";
static id<MTLDevice> dev; static id<MTLCommandQueue> q; static id<MTLRenderPipelineState> pCol, pTex, pCol4, pVtx;
static int W, H;
static void quad(id<MTLRenderCommandEncoder> en, float x0, float y0, float x1, float y1) {
    float r[4] = { x0, y0, x1, y1 }; [en setVertexBytes:r length:16 atIndex:0]; [en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6]; }
static id<MTLRenderCommandEncoder> pass(id<MTLCommandBuffer> cb, id<MTLTexture> t, MTLLoadAction la, float gray) {
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = t; rp.colorAttachments[0].loadAction = la; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(gray, gray * 0.5, 1 - gray, 1);
    return [cb renderCommandEncoderWithDescriptor:rp]; }
static void colq(id<MTLRenderCommandEncoder> en, float r, float g, float b, float x0, float y0, float x1, float y1) {
    float c[4] = { r, g, b, 1 }; [en setRenderPipelineState:pCol]; [en setFragmentBytes:c length:16 atIndex:0]; quad(en, x0, y0, x1, y1); }
static void texq(id<MTLRenderCommandEncoder> en, id<MTLTexture> t, float mixw, float x0, float y0, float x1, float y1) {
    float c[4] = { 0.2f, 0.9f, 0.3f, mixw }; [en setRenderPipelineState:pTex]; [en setFragmentTexture:t atIndex:0];
    [en setFragmentBytes:c length:16 atIndex:0]; quad(en, x0, y0, x1, y1); }
// One case: `body` records into cb using target `t` (and `t2`, a second texture object of the same storage; for the
// private reference it is the same object) and helper texture `aux`. Returns the final pixels of `t`.
typedef void (^Body)(id<MTLCommandBuffer> cb, id<MTLTexture> t, id<MTLTexture> t2, id<MTLTexture> aux, id<MTLBuffer> buf);
static uint8_t *runcase(int surface, Body body, long *pagesDiff) {
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:W height:H mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    IOSurfaceRef s = surface ? IOSurfaceCreate((__bridge CFDictionaryRef)@{ (id)kIOSurfaceWidth: @(W), (id)kIOSurfaceHeight: @(H),
        (id)kIOSurfaceBytesPerElement: @4, (id)kIOSurfacePixelFormat: @((uint32_t)'BGRA') }) : NULL;
    id<MTLTexture> t = surface ? [dev newTextureWithDescriptor:td iosurface:s plane:0] : [dev newTextureWithDescriptor:td];
    id<MTLTexture> t2 = surface ? [dev newTextureWithDescriptor:td iosurface:s plane:0] : t;
    id<MTLTexture> aux = [dev newTextureWithDescriptor:td];
    id<MTLBuffer> buf = [dev newBufferWithLength:(size_t)W * H * 4 options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb = [q commandBuffer];
    { id<MTLRenderCommandEncoder> en = pass(cb, aux, MTLLoadActionClear, 0.3f); colq(en, 0.9f, 0.1f, 0.1f, -0.5f, -0.5f, 0.2f, 0.7f); [en endEncoding]; }
    body(cb, t, t2, aux, buf);
    [cb commit]; [cb waitUntilCompleted];
    uint8_t *img = malloc((size_t)W * H * 4);
    [t getBytes:img bytesPerRow:(NSUInteger)W * 4 fromRegion:MTLRegionMake2D(0, 0, (NSUInteger)W, (NSUInteger)H) mipmapLevel:0];
    // the blit target buffer is part of the result too (copy-through cases)
    const uint8_t *bb = buf.contents; long bsum = 0; for (size_t i = 0; i < (size_t)W * H * 4; i += 997) bsum += bb[i];
    img[0] ^= (uint8_t)(bsum & 0); // keep the buffer alive; compared separately below
    *pagesDiff = 0;
    if (s) { IOSurfaceLock(s, kIOSurfaceLockReadOnly, NULL); const uint8_t *b = IOSurfaceGetBaseAddress(s); const size_t row = IOSurfaceGetBytesPerRow(s);
        for (int y = 0; y < H; y += 5) for (int x = 0; x < W * 4; x += 7) if (abs(b[(size_t)y * row + x] - img[(size_t)y * W * 4 + x]) > 2) (*pagesDiff)++;
        IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL); CFRelease(s); }
    uint8_t *out = malloc((size_t)W * H * 8); memcpy(out, img, (size_t)W * H * 4); memcpy(out + (size_t)W * H * 4, bb, (size_t)W * H * 4); free(img);
    return out;
}
int main(int argc, char **argv) { @autoreleasepool {
    int ai = 1;
    if (argc > 1 && strchr(argv[1], '/')) { if (!dlopen(argv[1], RTLD_NOW)) { printf("dlopen: %s\n", dlerror()); return 2; }
        io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"));
        dev = ((id (*)(id, SEL, mach_port_t))objc_msgSend)([objc_getClass("NVMTLDevice") alloc], sel_registerName("initWithAcceleratorPort:"), svc); ai = 2;
    } else dev = MTLCreateSystemDefaultDevice();
    W = argc > ai ? atoi(argv[ai]) : 3038; H = argc > ai + 1 ? atoi(argv[ai + 1]) : 1802;
    q = [dev newCommandQueue]; NSError *e = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:src options:nil error:&e]; if (!lib) { printf("lib: %s\n", e.description.UTF8String); return 1; }
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new]; pd.vertexFunction = [lib newFunctionWithName:@"vs"];
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    pd.fragmentFunction = [lib newFunctionWithName:@"fcol"]; pCol = [dev newRenderPipelineStateWithDescriptor:pd error:&e];
    pd.fragmentFunction = [lib newFunctionWithName:@"ftex"]; pTex = [dev newRenderPipelineStateWithDescriptor:pd error:&e];
    pd.vertexFunction = [lib newFunctionWithName:@"vstex"]; pd.fragmentFunction = [lib newFunctionWithName:@"fvc"]; pVtx = [dev newRenderPipelineStateWithDescriptor:pd error:&e];
    pd.vertexFunction = [lib newFunctionWithName:@"vs"];
    pd.fragmentFunction = [lib newFunctionWithName:@"fcol"]; pd.rasterSampleCount = 4; pCol4 = [dev newRenderPipelineStateWithDescriptor:pd error:&e];
    if (!pCol || !pTex || !pCol4 || !pVtx) { printf("pso: %s\n", e.description.UTF8String); return 1; }
    MTLTextureDescriptor *md = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:W height:H mipmapped:NO];
    md.textureType = MTLTextureType2DMultisample; md.sampleCount = 4; md.usage = MTLTextureUsageRenderTarget; md.storageMode = MTLStorageModePrivate;
    id<MTLTexture> ms = [dev newTextureWithDescriptor:md];
    NSArray *names = @[ @"render x3 (load) then blit to buffer", @"render then sample it in a pass on another target, then load+draw",
                        @"render via texture A, then load+draw via texture B (same surface)", @"render, then MSAA resolve into it, then load+draw",
                        @"self-bind (feedback loop, undefined in Metal: info only)", @"dontcare pass after render (keeps pixels)",
                        @"clear pass with no draws after render", @"render, compute-less blit copy aux->target, load+draw",
                        @"render, aux pass: draw, sample an sRGB VIEW of it (restart), draw", @"render, aux pass: draw, useResource(it), sample, draw",
                        @"render via A, aux pass: draw, sample texture B (same surface), draw", @"render, aux pass reads it in the VERTEX stage, then load+draw it",
                        @"render, blit a region of it to aux (backdrop copy), load+draw sampling aux" ];
    NSArray<Body> *bodies = @[
        ^(id<MTLCommandBuffer> cb, id<MTLTexture> t, id<MTLTexture> t2, id<MTLTexture> aux, id<MTLBuffer> buf) {
            id<MTLRenderCommandEncoder> en = pass(cb, t, MTLLoadActionClear, 0.1f); colq(en, 0.2f, 0.4f, 0.6f, -0.9f, -0.9f, 0.3f, 0.1f); [en endEncoding];
            en = pass(cb, t, MTLLoadActionLoad, 0); colq(en, 0.7f, 0.1f, 0.3f, -0.2f, -0.6f, 0.8f, 0.9f); [en endEncoding];
            en = pass(cb, t, MTLLoadActionLoad, 0); texq(en, aux, 0.5f, -0.6f, -0.3f, 0.6f, 0.4f); [en endEncoding];
            id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
            [b copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake((NSUInteger)W, (NSUInteger)H, 1)
                      toBuffer:buf destinationOffset:0 destinationBytesPerRow:(NSUInteger)W * 4 destinationBytesPerImage:(NSUInteger)W * H * 4]; [b endEncoding]; },
        ^(id<MTLCommandBuffer> cb, id<MTLTexture> t, id<MTLTexture> t2, id<MTLTexture> aux, id<MTLBuffer> buf) {
            id<MTLRenderCommandEncoder> en = pass(cb, t, MTLLoadActionClear, 0.6f); colq(en, 0.1f, 0.8f, 0.2f, -0.4f, -0.8f, 0.9f, 0.2f); [en endEncoding];
            en = pass(cb, aux, MTLLoadActionLoad, 0); texq(en, t, 1.0f, -1, -1, 1, 1); [en endEncoding];
            en = pass(cb, t, MTLLoadActionLoad, 0); texq(en, aux, 0.7f, -0.9f, 0.0f, 0.2f, 0.95f); [en endEncoding]; },
        ^(id<MTLCommandBuffer> cb, id<MTLTexture> t, id<MTLTexture> t2, id<MTLTexture> aux, id<MTLBuffer> buf) {
            id<MTLRenderCommandEncoder> en = pass(cb, t, MTLLoadActionClear, 0.2f); colq(en, 0.9f, 0.9f, 0.1f, -0.7f, -0.2f, 0.4f, 0.8f); [en endEncoding];
            en = pass(cb, t2, MTLLoadActionLoad, 0); colq(en, 0.3f, 0.2f, 0.9f, 0.0f, -0.9f, 0.9f, 0.3f); [en endEncoding];
            en = pass(cb, t, MTLLoadActionLoad, 0); colq(en, 0.5f, 0.5f, 0.5f, -0.1f, -0.1f, 0.1f, 0.1f); [en endEncoding]; },
        ^(id<MTLCommandBuffer> cb, id<MTLTexture> t, id<MTLTexture> t2, id<MTLTexture> aux, id<MTLBuffer> buf) {
            id<MTLRenderCommandEncoder> en = pass(cb, t, MTLLoadActionClear, 0.8f); colq(en, 0.2f, 0.2f, 0.2f, -0.9f, -0.9f, 0.9f, 0.9f); [en endEncoding];
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.colorAttachments[0].texture = ms; rp.colorAttachments[0].resolveTexture = t; rp.colorAttachments[0].loadAction = MTLLoadActionClear;
            rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0.3, 1); rp.colorAttachments[0].storeAction = MTLStoreActionMultisampleResolve;
            en = [cb renderCommandEncoderWithDescriptor:rp]; float c[4] = { 1, 0.5f, 0, 1 }; [en setRenderPipelineState:pCol4];
            [en setFragmentBytes:c length:16 atIndex:0]; quad(en, -0.3f, -0.3f, 0.6f, 0.5f); [en endEncoding];
            en = pass(cb, t, MTLLoadActionLoad, 0); colq(en, 0.0f, 1.0f, 1.0f, 0.5f, 0.5f, 0.9f, 0.9f); [en endEncoding]; },
        ^(id<MTLCommandBuffer> cb, id<MTLTexture> t, id<MTLTexture> t2, id<MTLTexture> aux, id<MTLBuffer> buf) {
            id<MTLRenderCommandEncoder> en = pass(cb, t, MTLLoadActionClear, 0.4f); colq(en, 0.9f, 0.3f, 0.6f, -0.8f, -0.8f, 0.0f, 0.6f); [en endEncoding];
            en = pass(cb, t, MTLLoadActionLoad, 0); colq(en, 0.1f, 0.1f, 0.9f, 0.1f, -0.6f, 0.7f, 0.3f);
            texq(en, t, 0.6f, -0.5f, -0.5f, 0.5f, 0.5f); [en endEncoding]; },
        ^(id<MTLCommandBuffer> cb, id<MTLTexture> t, id<MTLTexture> t2, id<MTLTexture> aux, id<MTLBuffer> buf) {
            id<MTLRenderCommandEncoder> en = pass(cb, t, MTLLoadActionClear, 0.7f); colq(en, 0.3f, 0.9f, 0.3f, -0.6f, -0.6f, 0.6f, 0.6f); [en endEncoding];
            en = pass(cb, t, MTLLoadActionDontCare, 0); colq(en, 0.9f, 0.1f, 0.9f, 0.2f, 0.2f, 0.4f, 0.4f); [en endEncoding]; },
        ^(id<MTLCommandBuffer> cb, id<MTLTexture> t, id<MTLTexture> t2, id<MTLTexture> aux, id<MTLBuffer> buf) {
            id<MTLRenderCommandEncoder> en = pass(cb, t, MTLLoadActionClear, 0.7f); colq(en, 0.3f, 0.9f, 0.3f, -0.6f, -0.6f, 0.6f, 0.6f); [en endEncoding];
            en = pass(cb, t, MTLLoadActionClear, 0.15f); [en endEncoding];
            en = pass(cb, t, MTLLoadActionLoad, 0); colq(en, 0.8f, 0.8f, 0.1f, -0.2f, -0.2f, 0.3f, 0.3f); [en endEncoding]; },
        ^(id<MTLCommandBuffer> cb, id<MTLTexture> t, id<MTLTexture> t2, id<MTLTexture> aux, id<MTLBuffer> buf) {
            id<MTLRenderCommandEncoder> en = pass(cb, t, MTLLoadActionClear, 0.5f); colq(en, 0.6f, 0.1f, 0.6f, -0.9f, 0.1f, 0.9f, 0.9f); [en endEncoding];
            id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
            [b copyFromTexture:aux sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(100, 50, 0) sourceSize:MTLSizeMake(600, 400, 1)
                     toTexture:t destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(300, 700, 0)]; [b endEncoding];
            en = pass(cb, t, MTLLoadActionLoad, 0); colq(en, 0.1f, 0.6f, 0.9f, -0.3f, -0.95f, 0.95f, -0.5f); [en endEncoding]; },
        // the aux results land in t through a blit at the end, so the comparison sees them
        ^(id<MTLCommandBuffer> cb, id<MTLTexture> t, id<MTLTexture> t2, id<MTLTexture> aux, id<MTLBuffer> buf) {
            id<MTLRenderCommandEncoder> en = pass(cb, t, MTLLoadActionClear, 0.3f); colq(en, 0.8f, 0.2f, 0.4f, -0.7f, -0.7f, 0.5f, 0.5f); [en endEncoding];
            id<MTLTexture> v = [t newTextureViewWithPixelFormat:MTLPixelFormatBGRA8Unorm_sRGB];
            en = pass(cb, aux, MTLLoadActionLoad, 0); colq(en, 0.1f, 0.9f, 0.1f, 0.6f, 0.6f, 0.95f, 0.95f); texq(en, v, 1.0f, -1, -1, 0.5f, 0.5f);
            colq(en, 0.9f, 0.9f, 0.9f, -0.95f, 0.7f, -0.6f, 0.95f); [en endEncoding];
            id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder]; [b copyFromTexture:aux toTexture:t]; [b endEncoding]; },
        ^(id<MTLCommandBuffer> cb, id<MTLTexture> t, id<MTLTexture> t2, id<MTLTexture> aux, id<MTLBuffer> buf) {
            id<MTLRenderCommandEncoder> en = pass(cb, t, MTLLoadActionClear, 0.3f); colq(en, 0.3f, 0.2f, 0.8f, -0.2f, -0.9f, 0.9f, 0.4f); [en endEncoding];
            en = pass(cb, aux, MTLLoadActionLoad, 0); colq(en, 0.1f, 0.9f, 0.1f, 0.6f, 0.6f, 0.95f, 0.95f);
            [en useResource:t usage:MTLResourceUsageRead stages:MTLRenderStageFragment]; texq(en, t, 1.0f, -1, -1, 0.5f, 0.5f);
            colq(en, 0.9f, 0.9f, 0.9f, -0.95f, 0.7f, -0.6f, 0.95f); [en endEncoding];
            id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder]; [b copyFromTexture:aux toTexture:t]; [b endEncoding]; },
        ^(id<MTLCommandBuffer> cb, id<MTLTexture> t, id<MTLTexture> t2, id<MTLTexture> aux, id<MTLBuffer> buf) {
            id<MTLRenderCommandEncoder> en = pass(cb, t, MTLLoadActionClear, 0.6f); colq(en, 0.9f, 0.6f, 0.1f, -0.6f, -0.3f, 0.7f, 0.8f); [en endEncoding];
            en = pass(cb, aux, MTLLoadActionLoad, 0); colq(en, 0.1f, 0.9f, 0.1f, 0.6f, 0.6f, 0.95f, 0.95f); texq(en, t2, 1.0f, -1, -1, 0.5f, 0.5f);
            colq(en, 0.9f, 0.9f, 0.9f, -0.95f, 0.7f, -0.6f, 0.95f); [en endEncoding];
            id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder]; [b copyFromTexture:aux toTexture:t]; [b endEncoding]; },
        ^(id<MTLCommandBuffer> cb, id<MTLTexture> t, id<MTLTexture> t2, id<MTLTexture> aux, id<MTLBuffer> buf) {
            id<MTLRenderCommandEncoder> en = pass(cb, t, MTLLoadActionClear, 0.2f); colq(en, 0.2f, 0.8f, 0.7f, -0.9f, -0.9f, 0.9f, 0.9f); [en endEncoding];
            en = pass(cb, aux, MTLLoadActionLoad, 0); float r[4] = { -0.9f, -0.9f, -0.1f, -0.1f }; [en setRenderPipelineState:pVtx];
            [en setVertexBytes:r length:16 atIndex:0]; [en setVertexTexture:t atIndex:0]; [en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6]; [en endEncoding];
            id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder]; [b copyFromTexture:aux toTexture:t]; [b endEncoding];
            en = pass(cb, t, MTLLoadActionLoad, 0); colq(en, 0.6f, 0.1f, 0.1f, 0.2f, 0.2f, 0.4f, 0.4f); [en endEncoding]; },
        ^(id<MTLCommandBuffer> cb, id<MTLTexture> t, id<MTLTexture> t2, id<MTLTexture> aux, id<MTLBuffer> buf) {
            for (int r = 0; r < 3; r++) {   // three backdrop-filter rounds, like a Graphite frame
                id<MTLRenderCommandEncoder> en = pass(cb, t, r ? MTLLoadActionLoad : MTLLoadActionClear, 0.4f);
                colq(en, 0.2f + 0.3f * r, 0.7f - 0.2f * r, 0.4f, -0.9f + 0.4f * r, -0.8f, 0.1f + 0.4f * r, 0.6f); [en endEncoding];
                id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
                [b copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(200 + 300 * r, 150, 0) sourceSize:MTLSizeMake(900, 700, 1)
                         toTexture:aux destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)]; [b endEncoding];
                en = pass(cb, t, MTLLoadActionLoad, 0); texq(en, aux, 0.8f, -0.3f, -0.9f + 0.5f * r, 0.9f, -0.3f + 0.5f * r); [en endEncoding];
            } } ];
    int bad = 0;
    for (NSUInteger k = 0; k < bodies.count; k++) {
        long pd0 = 0, pd1 = 0;
        if (getenv("RSH_DUMP") && (int)k == atoi(getenv("RSH_CASE") ?: "4")) {   // dump the IOSurface result of one case
            uint8_t *g = runcase(1, bodies[k], &pd1); FILE *f = fopen(getenv("RSH_DUMP"), "wb"); fwrite(g, 1, (size_t)W * H * 4, f); fclose(f);
            printf("dumped case %lu (surface pages differ %ld)\n", (unsigned long)k, pd1); free(g); return 0; }
        uint8_t *ref = runcase(0, bodies[k], &pd0), *got = runcase(1, bodies[k], &pd1);
        long dt = 0, db = 0; const size_t n = (size_t)W * H * 4;
        for (size_t i = 0; i < n; i++) { if (abs(ref[i] - got[i]) > 2) dt++; if (k == 0 && abs(ref[n + i] - got[n + i]) > 2) db++; }
        const int ok = !dt && !db && !pd1;
        printf("%-66s texture %ld B differ, blit buffer %ld, surface pages %ld  %s\n", [names[k] UTF8String], dt, db, pd1, ok ? "ok" : "MISMATCH");
        bad += !ok && k != 4; free(ref); free(got);   // case 4: compare the build against the previous one (RSH_DUMP) instead
    }
    printf("%s\n", bad ? "FAIL" : "PASS"); return bad ? 1 : 0;
}}
