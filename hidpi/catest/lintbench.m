// lintbench: GPU time of a Chrome-like composite (N alpha-blended, textured quads) into a window-sized render target:
// a plain private texture vs an IOSurface texture (>= NVMTL_SURF_SHARE_MINPX -> linear image over shared VRAM).
// Also checks that both targets end with the same pixels. usage: lintbench [plugin] [W H draws frames]
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurface.h>
#import <IOKit/IOKitLib.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
static NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
 "struct V { float4 p [[position]]; float2 uv; };\n"
 "struct Q { float4 r; float4 c; };\n"
 "vertex V vs(uint i [[vertex_id]], uint q [[instance_id]], constant Q *qs [[buffer(0)]]) {\n"
 "  float2 k = float2((i == 1 || i == 2 || i == 4) ? 1 : 0, (i == 2 || i == 4 || i == 5) ? 1 : 0); Q x = qs[q];\n"
 "  V o; o.p = float4(mix(x.r.xy, x.r.zw, k), 0, 1); o.uv = k; return o; }\n"
 "fragment float4 fs(V v [[stage_in]], texture2d<float> t [[texture(0)]], constant Q *qs [[buffer(0)]]) {\n"
 "  constexpr sampler s(filter::linear); return t.sample(s, v.uv) * float4(1, 1, 1, 0.85); }\n";
static double now(void) { return (double)clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e6; }
int main(int argc, char **argv) { @autoreleasepool {
    id<MTLDevice> dev; int ai = 1;
    if (argc > 1 && strchr(argv[1], '/')) { if (!dlopen(argv[1], RTLD_NOW)) { printf("dlopen: %s\n", dlerror()); return 2; }
        io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"));
        dev = ((id (*)(id, SEL, mach_port_t))objc_msgSend)([objc_getClass("NVMTLDevice") alloc], sel_registerName("initWithAcceleratorPort:"), svc); ai = 2;
    } else dev = MTLCreateSystemDefaultDevice();
    const int W = argc > ai ? atoi(argv[ai]) : 3584, H = argc > ai + 1 ? atoi(argv[ai + 1]) : 1840;
    const int N = argc > ai + 2 ? atoi(argv[ai + 2]) : 120, F = argc > ai + 3 ? atoi(argv[ai + 3]) : 30;
    const int MS = getenv("LB_MSAA") ? atoi(getenv("LB_MSAA")) : 1;  // 4: draw into a 4x MSAA texture and resolve into the target
    id<MTLCommandQueue> q = [dev newCommandQueue]; NSError *e = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:src options:nil error:&e]; if (!lib) { printf("lib: %s\n", e.description.UTF8String); return 1; }
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new]; pd.vertexFunction = [lib newFunctionWithName:@"vs"]; pd.fragmentFunction = [lib newFunctionWithName:@"fs"];
    MTLRenderPipelineColorAttachmentDescriptor *ca = pd.colorAttachments[0]; ca.pixelFormat = MTLPixelFormatBGRA8Unorm; ca.blendingEnabled = YES;
    ca.sourceRGBBlendFactor = MTLBlendFactorSourceAlpha; ca.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    ca.sourceAlphaBlendFactor = MTLBlendFactorOne; ca.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha; pd.rasterSampleCount = (NSUInteger)MS;
    id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:pd error:&e]; if (!ps) { printf("pso: %s\n", e.description.UTF8String); return 1; }
    // a 512x512 "tile" with a gradient, like a rastered web tile
    MTLTextureDescriptor *tdt = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:512 height:512 mipmapped:NO];
    tdt.usage = MTLTextureUsageShaderRead; id<MTLTexture> tile = [dev newTextureWithDescriptor:tdt];
    uint32_t *px = malloc(512 * 512 * 4); for (int y = 0; y < 512; y++) for (int x = 0; x < 512; x++) px[y * 512 + x] = 0xff000000u | (uint32_t)(x / 2) << 16 | (uint32_t)(y / 2) << 8 | (uint32_t)((x ^ y) & 255);
    [tile replaceRegion:MTLRegionMake2D(0, 0, 512, 512) mipmapLevel:0 withBytes:px bytesPerRow:2048]; free(px);
    // N quads: each a 512x512-pixel tile placed on a grid with overlap (like a page of tiles plus overlays)
    float *qs = calloc((size_t)N, 32); srand(7);
    for (int i = 0; i < N; i++) { float x0 = (float)(rand() % (W - 512)), y0 = (float)(rand() % (H - 512)), sw = 512.f + (float)(rand() % 600), sh = 512.f + (float)(rand() % 400);
        qs[i * 8 + 0] = x0 / W * 2 - 1; qs[i * 8 + 1] = y0 / H * 2 - 1; qs[i * 8 + 2] = fminf(x0 + sw, (float)W) / W * 2 - 1; qs[i * 8 + 3] = fminf(y0 + sh, (float)H) / H * 2 - 1; }
    id<MTLBuffer> qb = [dev newBufferWithBytes:qs length:(size_t)N * 32 options:MTLResourceStorageModeShared];
    uint8_t *img[2] = { 0, 0 }; double med[2] = { 0, 0 };
    for (int target = 0; target < 2; target++) {
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:W height:H mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        IOSurfaceRef s = target ? IOSurfaceCreate((__bridge CFDictionaryRef)@{ (id)kIOSurfaceWidth: @(W), (id)kIOSurfaceHeight: @(H),
            (id)kIOSurfaceBytesPerElement: @4, (id)kIOSurfacePixelFormat: @((uint32_t)'BGRA') }) : NULL;
        id<MTLTexture> t = target ? [dev newTextureWithDescriptor:td iosurface:s plane:0] : [dev newTextureWithDescriptor:td];
        id<MTLTexture> msT = nil;
        if (MS > 1) { MTLTextureDescriptor *md = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:W height:H mipmapped:NO];
            md.textureType = MTLTextureType2DMultisample; md.sampleCount = (NSUInteger)MS; md.usage = MTLTextureUsageRenderTarget; md.storageMode = MTLStorageModePrivate; msT = [dev newTextureWithDescriptor:md]; }
        double ms[256]; int nf = F < 256 ? F : 256;
        for (int f = -3; f < nf; f++) {
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.colorAttachments[0].texture = t; rp.colorAttachments[0].loadAction = f & 1 ? MTLLoadActionLoad : MTLLoadActionClear;
            rp.colorAttachments[0].clearColor = MTLClearColorMake(1, 1, 1, 1); rp.colorAttachments[0].storeAction = MTLStoreActionStore;
            if (msT) { rp.colorAttachments[0].texture = msT; rp.colorAttachments[0].resolveTexture = t; rp.colorAttachments[0].loadAction = MTLLoadActionClear;
                rp.colorAttachments[0].storeAction = MTLStoreActionMultisampleResolve; }
            id<MTLCommandBuffer> cb = [q commandBuffer];
            const int P = getenv("LB_PASSES") ? atoi(getenv("LB_PASSES")) : 1;
            for (int pi = 0; pi < P; pi++) {
                if (pi) rp.colorAttachments[0].loadAction = MTLLoadActionLoad;
                id<MTLRenderCommandEncoder> en = [cb renderCommandEncoderWithDescriptor:rp];
                [en setRenderPipelineState:ps]; [en setVertexBuffer:qb offset:0 atIndex:0]; [en setFragmentTexture:tile atIndex:0];
                for (int i = pi * N / P; i < (pi + 1) * N / P; i++) [en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6 instanceCount:1 baseInstance:(NSUInteger)i];
                [en endEncoding];
            }
            const double t0 = now(); [cb commit]; [cb waitUntilCompleted]; const double t1 = now();
            if (f >= 0) ms[f] = t1 - t0;
        }
        for (int i = 0; i < nf; i++) for (int j = i + 1; j < nf; j++) if (ms[j] < ms[i]) { double x = ms[i]; ms[i] = ms[j]; ms[j] = x; }
        med[target] = ms[nf / 2];
        printf("%-34s %dx%d %d draws: median %.2f ms  (min %.2f, max %.2f)\n", target ? "IOSurface target (shared VRAM)" : "private texture target",
               W, H, N, ms[nf / 2], ms[0], ms[nf - 1]);
        img[target] = malloc((size_t)W * H * 4); [t getBytes:img[target] bytesPerRow:(NSUInteger)W * 4 fromRegion:MTLRegionMake2D(0, 0, (NSUInteger)W, (NSUInteger)H) mipmapLevel:0];
        if (s) { // the CPU view of the surface must hold the same frame (what WindowServer / other readers see)
            IOSurfaceLock(s, kIOSurfaceLockReadOnly, NULL); const uint8_t *b = IOSurfaceGetBaseAddress(s); const size_t row = IOSurfaceGetBytesPerRow(s); long d = 0;
            for (int y = 0; y < H; y += 7) for (int x = 0; x < W * 4; x += 13) if (abs(b[(size_t)y * row + x] - img[1][(size_t)y * W * 4 + x]) > 2) d++;
            IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL); printf("  surface pages vs texture readback: %ld sampled bytes differ %s\n", d, d ? "MISMATCH" : "ok");
            CFRelease(s); }
    }
    long diff = 0; for (size_t i = 0; i < (size_t)W * H * 4; i++) if (abs(img[0][i] - img[1][i]) > 2) diff++;
    printf("private vs IOSurface pixels: %ld bytes differ %s;  IOSurface/private time ratio %.1fx\n", diff, diff ? "MISMATCH" : "ok", med[1] / med[0]);
    return diff ? 1 : 0;
}}
