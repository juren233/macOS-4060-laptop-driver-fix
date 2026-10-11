// gfx3: a compositor-style buffer queue. N IOSurfaces rotate; each frame a NEW texture is made on the next surface, the
// previous surface is sampled to copy its contents, then a few damage rects are drawn. A CPU model checks every few frames.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurface.h>
#import <IOKit/IOKitLib.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
static id<MTLDevice> dev; static id<MTLCommandQueue> q; static id<MTLLibrary> lib;
static NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
"struct V { float4 p [[position]]; };\n"
"vertex V vq(uint i [[vertex_id]], constant float4 &g [[buffer(0)]]) { float2 p[4] = { float2(0,0), float2(1,0), float2(0,1), float2(1,1) };\n"
"  V o; o.p = float4((g.xy + p[i] * g.zw) * 2 - 1, 0, 1); o.p.y = -o.p.y; return o; }\n"
"fragment float4 fc(V in [[stage_in]], constant float4 &c [[buffer(0)]]) { return c; }\n"
"fragment float4 fs(V in [[stage_in]], texture2d<float> t [[texture(0)]]) { constexpr sampler s(filter::nearest, coord::pixel); return t.sample(s, in.p.xy); }\n";
static uint32_t rnd(uint32_t *s) { *s = *s * 1664525u + 1013904223u; return *s >> 8; }
static id<MTLTexture> tex(IOSurfaceRef surf, int W, int H, MTLTextureUsage u) {
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:W height:H mipmapped:NO];
    td.usage = u; td.storageMode = MTLStorageModeManaged; return [dev newTextureWithDescriptor:td iosurface:surf plane:0];
}
static int run(const char *nm, int W, int H, int nbuf, int frames, int syncEvery) {
    IOSurfaceRef sf[4]; uint32_t *model[4];
    for (int i = 0; i < nbuf; i++) {
        sf[i] = IOSurfaceCreate((__bridge CFDictionaryRef)@{ (id)kIOSurfaceWidth: @(W), (id)kIOSurfaceHeight: @(H), (id)kIOSurfaceBytesPerElement: @4, (id)kIOSurfacePixelFormat: @'BGRA' });
        model[i] = malloc((size_t)W * H * 4); for (size_t k = 0; k < (size_t)W * H; k++) model[i][k] = 0xFF000000u;
    }
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new]; d.vertexFunction = [lib newFunctionWithName:@"vq"]; d.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    d.fragmentFunction = [lib newFunctionWithName:@"fc"]; NSError *e; id<MTLRenderPipelineState> pc = [dev newRenderPipelineStateWithDescriptor:d error:&e];
    d.fragmentFunction = [lib newFunctionWithName:@"fs"]; id<MTLRenderPipelineState> pcopy = [dev newRenderPipelineStateWithDescriptor:d error:&e];
    id<MTLBuffer> rb = [dev newBufferWithLength:(size_t)W * H * 4 options:MTLResourceStorageModeShared];
    uint32_t s = 777; int bad = 0, checks = 0, badcpu = 0; long worst = 0;
    for (int f = 0; f < frames; f++) {
        int b = f % nbuf, pv = (f + nbuf - 1) % nbuf;
        id<MTLTexture> cur = tex(sf[b], W, H, MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead);
        id<MTLTexture> prev = f ? tex(sf[pv], W, H, MTLTextureUsageShaderRead) : nil;
        id<MTLCommandBuffer> cb = [q commandBuffer];
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = cur; rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1); rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        const char *bm = getenv("GFX_BLIT");   // 1 = whole-texture blit copy, 2 = two half blits (regions with offsets)
        if (bm && prev) { memcpy(model[b], model[pv], (size_t)W * H * 4); id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder];
            if (*bm == '2') { int hh = H / 2; [bl copyFromTexture:prev sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(W,hh,1) toTexture:cur destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
                [bl copyFromTexture:prev sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,hh,0) sourceSize:MTLSizeMake(W,H-hh,1) toTexture:cur destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,hh,0)]; }
            else [bl copyFromTexture:prev toTexture:cur];
            [bl endEncoding]; rp.colorAttachments[0].loadAction = MTLLoadActionLoad; }
        id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
        if (prev && !bm) { [re setRenderPipelineState:pcopy]; float full[4] = { 0, 0, 1, 1 }; [re setVertexBytes:full length:16 atIndex:0]; [re setFragmentTexture:prev atIndex:0]; [re drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4]; memcpy(model[b], model[pv], (size_t)W * H * 4); }
        [re setRenderPipelineState:pc];
        int n = 1 + rnd(&s) % 3;
        for (int k = 0; k < n; k++) {
            int w = 16 + rnd(&s) % (W / 3), h = 16 + rnd(&s) % (H / 3), x = rnd(&s) % (W - w), y = rnd(&s) % (H - h); uint8_t r = rnd(&s), g = rnd(&s), bl = rnd(&s);
            float geom[4] = { (float)x / W, (float)y / H, (float)w / W, (float)h / H }, col[4] = { r / 255.f, g / 255.f, bl / 255.f, 1 };
            [re setVertexBytes:geom length:16 atIndex:0]; [re setFragmentBytes:col length:16 atIndex:0]; [re drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
            uint32_t px = 0xFF000000u | (uint32_t)r << 16 | (uint32_t)g << 8 | bl;
            for (int yy = y; yy < y + h; yy++) for (int xx = x; xx < x + w; xx++) model[b][(size_t)yy * W + xx] = px;
        }
        [re endEncoding]; [cb commit];
        if (syncEvery && f % syncEvery == syncEvery - 1) {
            [cb waitUntilCompleted];
            // read it back the way another consumer would: a fresh texture on the surface, blitted out
            id<MTLTexture> rd = tex(sf[b], W, H, MTLTextureUsageShaderRead);
            id<MTLCommandBuffer> c2 = [q commandBuffer]; id<MTLBlitCommandEncoder> bl = [c2 blitCommandEncoder];
            [bl copyFromTexture:rd sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(W,H,1) toBuffer:rb destinationOffset:0 destinationBytesPerRow:(size_t)W * 4 destinationBytesPerImage:(size_t)W * H * 4];
            [bl endEncoding]; [c2 commit]; [c2 waitUntilCompleted];
            const uint32_t *got = rb.contents; long diff = 0; for (size_t i = 0; i < (size_t)W * H; i++) if (got[i] != model[b][i]) diff++;
            checks++; if (diff) { bad++; if (diff > worst) worst = diff; }
            // and through the surface's CPU pages (what a software consumer or the display path sees)
            IOSurfaceLock(sf[b], kIOSurfaceLockReadOnly, NULL); const uint8_t *base = IOSurfaceGetBaseAddress(sf[b]); size_t row = IOSurfaceGetBytesPerRow(sf[b]); long dc = 0;
            for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) if (((const uint32_t *)(base + (size_t)y * row))[x] != model[b][(size_t)y * W + x]) dc++;
            IOSurfaceUnlock(sf[b], kIOSurfaceLockReadOnly, NULL); if (dc) badcpu++;
        }
    }
    printf("%-30s %dx%d x%d bufs, %d frames: GPU-view %d/%d bad%s ; CPU-pages %d/%d bad\n", nm, W, H, nbuf, frames, bad, checks, bad ? " <== WRONG" : "", badcpu, checks);
    return bad != 0;
}
int main(int argc, char **argv) { @autoreleasepool {
    int se = argc > 1 ? atoi(argv[1]) : 4;
    if (argc > 2) { if (!dlopen(argv[2], RTLD_NOW)) { printf("dlopen: %s\n", dlerror()); return 2; }
        io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"));
        dev = ((id (*)(id, SEL, mach_port_t))objc_msgSend)([objc_getClass("NVMTLDevice") alloc], sel_registerName("initWithAcceleratorPort:"), svc);
    } else dev = MTLCreateSystemDefaultDevice();
    q = [dev newCommandQueue]; NSError *e; lib = [dev newLibraryWithSource:src options:nil error:&e]; if (!lib) { printf("lib FAILED\n"); return 1; }
    int bad = 0;
    bad += run("small (private image)", 960, 540, 3, 36, se);
    bad += run("large (shared linear VRAM)", 2560, 1440, 3, 24, se);
    printf("%s\n", bad ? "FAIL" : "PASS"); return bad;
}}
