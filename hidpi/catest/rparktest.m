// rparktest: render-shadow park (plugin reuses a dead surface texture's tiled render shadow for the next surface of the same
// size and format). Like Chrome's masked danmaku layer, every frame makes a NEW IOSurface, fills it on the CPU with a colour
// that frame owns, wraps it in a texture and renders into it, then drops it - so each frame's shadow is the previous frame's.
// Frames alternate: LOAD pass (the shadow must be primed from the surface: the right half must keep the CPU colour, not the
// previous frame's pixels), CLEAR pass, DONTCARE-free load+2 passes; sizes and pixel formats rotate so mismatched shadows must
// not be handed out. Every frame's surface is read back on the CPU and checked at 6 points.
// usage: rparktest [plugin] [frames] [pause ms every 100 frames: lets parked shadows age out mid-run]   -> PASS / FAIL
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurface.h>
#import <IOKit/IOKitLib.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
static const char *src =
    "#include <metal_stdlib>\nusing namespace metal;\n"
    "struct V { float4 p [[position]]; };\n"
    "vertex V vs(uint i [[vertex_id]], constant float4 &r [[buffer(0)]]) { float2 c[6] = { float2(r.x, r.y), float2(r.z, r.y), float2(r.x, r.w),"
    " float2(r.z, r.y), float2(r.z, r.w), float2(r.x, r.w) }; V o; o.p = float4(c[i], 0, 1); return o; }\n"
    "fragment float4 fcol(V v [[stage_in]], constant float4 &c [[buffer(0)]]) { return c; }\n";
static id<MTLDevice> dev; static id<MTLCommandQueue> q; static id<MTLRenderPipelineState> pso[2];
static void quad(id<MTLRenderCommandEncoder> en, int f, const float c[4], float x0, float y0, float x1, float y1) {
    float r[4] = { x0, y0, x1, y1 }; [en setRenderPipelineState:pso[f]]; [en setVertexBytes:r length:16 atIndex:0];
    [en setFragmentBytes:c length:16 atIndex:0]; [en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6]; }
static uint8_t u8(float v) { return (uint8_t)(v * 255.0f + 0.5f); }
int main(int argc, char **argv) { @autoreleasepool {
    int ai = 1;
    if (argc > 1 && strchr(argv[1], '/')) { if (!dlopen(argv[1], RTLD_NOW)) { printf("dlopen: %s\n", dlerror()); return 2; }
        io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"));
        dev = ((id (*)(id, SEL, mach_port_t))objc_msgSend)([objc_getClass("NVMTLDevice") alloc], sel_registerName("initWithAcceleratorPort:"), svc); ai = 2;
    } else dev = MTLCreateSystemDefaultDevice();
    const int N = argc > ai ? atoi(argv[ai]) : 300, pauseMs = argc > ai + 1 ? atoi(argv[ai + 1]) : 0;
    q = [dev newCommandQueue]; NSError *e = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:@(src) options:nil error:&e]; if (!lib) { printf("lib: %s\nFAIL\n", e.description.UTF8String); return 1; }
    MTLPixelFormat pf[2] = { MTLPixelFormatBGRA8Unorm, MTLPixelFormatRGBA8Unorm };
    for (int f = 0; f < 2; f++) { MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new]; pd.vertexFunction = [lib newFunctionWithName:@"vs"];
        pd.fragmentFunction = [lib newFunctionWithName:@"fcol"]; pd.colorAttachments[0].pixelFormat = pf[f];
        pso[f] = [dev newRenderPipelineStateWithDescriptor:pd error:&e]; if (!pso[f]) { printf("pso: %s\nFAIL\n", e.description.UTF8String); return 1; } }
    const int sz[3][2] = { { 1856, 1024 }, { 1856, 1024 }, { 640, 360 } };
    int bad = 0; double t0 = CFAbsoluteTimeGetCurrent();
    for (int i = 0; i < N; i++) { @autoreleasepool {
        if (pauseMs && i && i % 100 == 0) usleep((useconds_t)pauseMs * 1000);
        const int W = sz[i % 3][0], H = sz[i % 3][1], f = (i / 3) % 2 && (i % 5 == 0), mode = i % 3;   // 0 load, 1 clear, 2 load + second pass
        const uint32_t fourcc = f ? 'RGBA' : 'BGRA';
        IOSurfaceRef s = IOSurfaceCreate((__bridge CFDictionaryRef)@{ (id)kIOSurfaceWidth: @(W), (id)kIOSurfaceHeight: @(H),
            (id)kIOSurfaceBytesPerElement: @4, (id)kIOSurfacePixelFormat: @(fourcc) });
        // this frame's CPU colour (B,G,R,A order in memory for BGRA; R,G,B,A for RGBA)
        const uint8_t cpu[4] = { (uint8_t)(17 + i * 37), (uint8_t)(200 - i * 11), (uint8_t)(90 + i * 53), 255 };
        IOSurfaceLock(s, 0, NULL); { uint8_t *b = IOSurfaceGetBaseAddress(s); const size_t row = IOSurfaceGetBytesPerRow(s);
            for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) memcpy(b + (size_t)y * row + (size_t)x * 4, cpu, 4); }
        IOSurfaceUnlock(s, 0, NULL);
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pf[f] width:W height:H mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        id<MTLTexture> t = [dev newTextureWithDescriptor:td iosurface:s plane:0];
        const float dc[4] = { (i % 7) / 7.0f, 0.25f + (i % 3) / 6.0f, 1.0f - (i % 5) / 5.0f, 1 }, cc[4] = { 0.1f + (i % 4) / 5.0f, 0.6f, (i % 9) / 9.0f, 1 };
        const float dc2[4] = { 0.9f, (i % 6) / 6.0f, 0.3f, 1 };
        id<MTLCommandBuffer> cb = [q commandBuffer];
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = t; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        rp.colorAttachments[0].loadAction = mode == 1 ? MTLLoadActionClear : MTLLoadActionLoad;
        rp.colorAttachments[0].clearColor = MTLClearColorMake(cc[0], cc[1], cc[2], 1);
        id<MTLRenderCommandEncoder> en = [cb renderCommandEncoderWithDescriptor:rp];
        quad(en, f, dc, -1, -1, 0, 1); [en endEncoding];   // left half
        if (mode == 2) { rp.colorAttachments[0].loadAction = MTLLoadActionLoad; en = [cb renderCommandEncoderWithDescriptor:rp];
            quad(en, f, dc2, -1, -1, 1, 0); [en endEncoding]; }   // bottom half (NDC y<0 = bottom rows)
        [cb commit]; [cb waitUntilCompleted];
        if (cb.status != MTLCommandBufferStatusCompleted) { printf("frame %d: command buffer status %ld\n", i, (long)cb.status); bad++; }
        // expected colour in memory order at a point
        uint8_t want[4];
        IOSurfaceLock(s, kIOSurfaceLockReadOnly, NULL); const uint8_t *b = IOSurfaceGetBaseAddress(s); const size_t row = IOSurfaceGetBytesPerRow(s);
        const int px[6][2] = { { W / 4, H / 4 }, { 3 * W / 4, H / 4 }, { W / 4, 3 * H / 4 }, { 3 * W / 4, 3 * H / 4 }, { W - 1, 0 }, { W - 1, H - 1 } };
        for (int k = 0; k < 6; k++) {
            const int x = px[k][0], y = px[k][1];
            const float *c = NULL;
            if (mode == 2 && y >= H / 2) c = dc2; else if (x < W / 2) c = dc; else if (mode == 1) c = cc;
            if (c) { const uint8_t r = u8(c[0]), g = u8(c[1]), bl = u8(c[2]);
                     if (f) { want[0] = r; want[1] = g; want[2] = bl; } else { want[0] = bl; want[1] = g; want[2] = r; } want[3] = 255; }
            else memcpy(want, cpu, 4);
            const uint8_t *got = b + (size_t)y * row + (size_t)x * 4; int d = 0;
            for (int ch = 0; ch < 4; ch++) d = MAX(d, abs(got[ch] - want[ch]));
            if (d > 2) { if (bad < 12) printf("frame %d (%dx%d %s mode %d) point %d (%d,%d): got %u,%u,%u,%u want %u,%u,%u,%u\n", i, W, H, f ? "RGBA" : "BGRA",
                mode, k, x, y, got[0], got[1], got[2], got[3], want[0], want[1], want[2], want[3]); bad++; }
        }
        IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL);
        t = nil; CFRelease(s);
    } }
    printf("%d frames in %.2f s (%.2f ms/frame)\n%s\n", N, CFAbsoluteTimeGetCurrent() - t0, (CFAbsoluteTimeGetCurrent() - t0) * 1000 / N, bad ? "FAIL" : "PASS");
    return bad ? 1 : 0;
} }
