// gfx2: partial redraws (Load action) into a persistent target, as a compositor with damage rects does. A CPU model of
// the target is kept; every few frames the GPU result is read back and compared. Targets: private texture or
// IOSurface-backed (small = private image path, large = shared linear VRAM path).
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
"fragment float4 fc(V in [[stage_in]], constant float4 &c [[buffer(0)]]) { return c; }\n";
static uint32_t rnd(uint32_t *s) { *s = *s * 1664525u + 1013904223u; return *s >> 8; }
static int run(const char *nm, int W, int H, MTLPixelFormat pf, int useSurf, int frames, int syncEvery) {
    IOSurfaceRef surf = NULL;
    id<MTLTexture> t;
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pf width:W height:H mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    if (useSurf) {
        surf = IOSurfaceCreate((__bridge CFDictionaryRef)@{ (id)kIOSurfaceWidth: @(W), (id)kIOSurfaceHeight: @(H), (id)kIOSurfaceBytesPerElement: @4, (id)kIOSurfacePixelFormat: @(pf == MTLPixelFormatBGRA8Unorm ? 'BGRA' : 'RGBA') });
        td.storageMode = MTLStorageModeManaged; t = [dev newTextureWithDescriptor:td iosurface:surf plane:0];
    } else { td.storageMode = MTLStorageModePrivate; t = [dev newTextureWithDescriptor:td]; }
    if (!t) { printf("%s: texture FAILED\n", nm); return 1; }
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = [lib newFunctionWithName:@"vq"]; d.fragmentFunction = [lib newFunctionWithName:@"fc"]; d.colorAttachments[0].pixelFormat = pf;
    NSError *e; id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:d error:&e];
    uint32_t *model = malloc((size_t)W * H * 4); for (size_t i = 0; i < (size_t)W * H; i++) model[i] = 0xFF000000u; uint32_t s = 12345; int bad = 0, checks = 0; long worst = 0;
    id<MTLBuffer> rb = [dev newBufferWithLength:(size_t)W * H * 4 options:MTLResourceStorageModeShared];
    for (int f = 0; f < frames; f++) {
        id<MTLCommandBuffer> cb = [q commandBuffer];
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = t; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        if (f == 0) { rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1); }
        else rp.colorAttachments[0].loadAction = MTLLoadActionLoad;
        id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp]; [re setRenderPipelineState:ps];
        int n = 1 + rnd(&s) % 4;
        for (int k = 0; k < n; k++) {
            int w = 8 + rnd(&s) % (W / 3), h = 8 + rnd(&s) % (H / 3), x = rnd(&s) % (W - w), y = rnd(&s) % (H - h);
            uint8_t r = rnd(&s), g = rnd(&s), b = rnd(&s);
            float geom[4] = { (float)x / W, (float)y / H, (float)w / W, (float)h / H }, col[4] = { r / 255.f, g / 255.f, b / 255.f, 1 };
            if (getenv("GFX_SCISSOR")) { float full[4] = { 0, 0, 1, 1 }; MTLScissorRect sr = { (NSUInteger)x, (NSUInteger)y, (NSUInteger)w, (NSUInteger)h }; [re setScissorRect:sr];
                [re setVertexBytes:full length:16 atIndex:0]; [re setFragmentBytes:col length:16 atIndex:0]; [re drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4]; }
            else { [re setVertexBytes:geom length:16 atIndex:0]; [re setFragmentBytes:col length:16 atIndex:0];
            [re drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4]; }
            uint32_t px = pf == MTLPixelFormatBGRA8Unorm ? (0xFF000000u | (uint32_t)r << 16 | (uint32_t)g << 8 | b) : (0xFF000000u | (uint32_t)b << 16 | (uint32_t)g << 8 | r);
            for (int yy = y; yy < y + h; yy++) for (int xx = x; xx < x + w; xx++) model[(size_t)yy * W + xx] = px;
        }
        [re endEncoding];
        if (syncEvery && (f % syncEvery == syncEvery - 1)) {
            id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder];
            [bl copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(W,H,1) toBuffer:rb destinationOffset:0 destinationBytesPerRow:(size_t)W * 4 destinationBytesPerImage:(size_t)W * H * 4];
            [bl endEncoding]; [cb commit]; [cb waitUntilCompleted];
            const uint32_t *got = rb.contents; long diff = 0;
            long zeros = 0; size_t first = (size_t)-1; for (size_t i = 0; i < (size_t)W * H; i++) if (got[i] != model[i]) { diff++; if (first == (size_t)-1) first = i; if (got[i] == 0xFF000000u || got[i] == 0) zeros++; }
            if (diff && getenv("GFX_V")) printf("   frame %d: %ld diff, %ld of them black/zero; first at (%zu,%zu) got %08x want %08x\n", f, diff, zeros, first % W, first / W, got[first], model[first]);
            checks++; if (diff) { bad++; if (diff > worst) worst = diff; }
        } else [cb commit];
    }
    printf("%-34s %dx%d %d frames: %d/%d checks mismatched%s\n", nm, W, H, frames, bad, checks, bad ? "  <== WRONG" : "");
    if (bad) printf("      worst: %ld pixels differ from the CPU model\n", worst);
    free(model); if (surf) CFRelease(surf); return bad != 0;
}
int main(int argc, char **argv) { @autoreleasepool {
    int se = argc > 1 ? atoi(argv[1]) : 0;
    if (argc > 2) { if (!dlopen(argv[2], RTLD_NOW)) { printf("dlopen: %s\n", dlerror()); return 2; }
        io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"));
        dev = ((id (*)(id, SEL, mach_port_t))objc_msgSend)([objc_getClass("NVMTLDevice") alloc], sel_registerName("initWithAcceleratorPort:"), svc);
    } else dev = MTLCreateSystemDefaultDevice();
    q = [dev newCommandQueue]; NSError *e;
    lib = [dev newLibraryWithSource:src options:nil error:&e]; if (!lib) { printf("lib FAILED\n"); return 1; }
    int bad = 0;
    bad += run("private tex BGRA", 512, 384, MTLPixelFormatBGRA8Unorm, 0, 60, 6);
    bad += run("IOSurface small (private image)", 512, 384, MTLPixelFormatBGRA8Unorm, 1, 60, se ?: 6);
    bad += run("IOSurface large (shared linear)", 2048, 1800, MTLPixelFormatBGRA8Unorm, 1, 40, 5);
    bad += run("IOSurface large RGBA", 2048, 1800, MTLPixelFormatRGBA8Unorm, 1, 40, 5);
    printf("%s\n", bad ? "FAIL" : "PASS"); return bad;
}}
