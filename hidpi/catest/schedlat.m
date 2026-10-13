// schedlat: Chrome-like frame cadence for waitUntilScheduled latency. Per frame: buffer 1 draws `draws` full-screen quads into a big
// IOSurface texture (with a row pitch the plugin cannot alias in VRAM -> published by a readback on the execution worker), commit;
// buffer 2 draws once into a small IOSurface "backbuffer", commit, waitUntilScheduled on it (what Dawn's WaitForCommandsToBeScheduled
// does before Chrome hands the surface to CoreAnimation). Prints the wait's mean / p95 / max and frames over budget.
// usage: schedlat <plugin> <vulkan-icd> [frames] [draws] [period-ms] [pitch-pad]
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurface.h>
#import <IOKit/IOKitLib.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
static const char *kSrc =
    "#include <metal_stdlib>\nusing namespace metal;\nstruct V { float4 p [[position]]; };\n"
    "vertex V vq(uint i [[vertex_id]]) { float2 p[4] = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1) }; V o; o.p = float4(p[i], 0, 1); return o; }\n"
    "fragment float4 fc(V in [[stage_in]], constant uint &k [[buffer(0)]]) { return float4((k & 255) / 255.0, fract(in.p.x / 97.0), 0.25, 0.5); }\n";
static id<MTLTexture> surftex(id<MTLDevice> dev, int w, int h, int pitch) {
    IOSurfaceRef sf = IOSurfaceCreate((__bridge CFDictionaryRef)@{ (id)kIOSurfaceWidth: @(w), (id)kIOSurfaceHeight: @(h),
        (id)kIOSurfaceBytesPerElement: @4, (id)kIOSurfaceBytesPerRow: @(pitch), (id)kIOSurfacePixelFormat: @((uint32_t)'BGRA') });
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:w height:h mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead; td.storageMode = MTLStorageModeShared;
    id<MTLTexture> t = [dev newTextureWithDescriptor:td iosurface:sf plane:0]; CFRelease(sf); return t;
}
static int cmpd(const void *a, const void *b) { double x = *(const double *)a, y = *(const double *)b; return (x > y) - (x < y); }
int main(int argc, char **argv) { @autoreleasepool {
    if (argc < 3) { printf("usage: schedlat <plugin> <vulkan-icd> [frames] [draws] [period-ms] [pitch-pad]\n"); return 2; }
    const int F = argc > 3 ? atoi(argv[3]) : 600, D = argc > 4 ? atoi(argv[4]) : 40, pad = argc > 6 ? atoi(argv[6]) : 8;
    const double P = argc > 5 ? atof(argv[5]) : 6.06;
    if (!dlopen(argv[1], RTLD_NOW)) { printf("dlopen: %s\n", dlerror()); return 2; }
    setenv("NVMTL_ICD_LIB", argv[2], 1);
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"));
    id<MTLDevice> dev = ((id (*)(id, SEL, mach_port_t))objc_msgSend)([objc_getClass("NVMTLDevice") alloc], sel_registerName("initWithAcceleratorPort:"), svc);
    NSError *e = nil; id<MTLLibrary> lib = [dev newLibraryWithSource:@(kSrc) options:nil error:&e];
    MTLRenderPipelineDescriptor *rd = [MTLRenderPipelineDescriptor new];
    rd.vertexFunction = [lib newFunctionWithName:@"vq"]; rd.fragmentFunction = [lib newFunctionWithName:@"fc"];
    rd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm; rd.colorAttachments[0].blendingEnabled = YES;
    rd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha; rd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:rd error:&e];
    if (!ps) { printf("pipeline: %s\nFAIL\n", e.description.UTF8String); return 1; }
    id<MTLCommandQueue> q = [dev newCommandQueue];
    NSMutableArray *big = [NSMutableArray new], *small = [NSMutableArray new];
    for (int i = 0; i < 3; i++) { [big addObject:surftex(dev, 1856, 1024, 1856 * 4 + pad)]; [small addObject:surftex(dev, 512, 256, 512 * 4)]; }
    double *w = calloc(F, sizeof *w); int over = 0;
    const double t0 = CFAbsoluteTimeGetCurrent();
    for (int f = 0; f < F; f++) { @autoreleasepool {
        const double due = t0 + f * P / 1000.0; const double now = CFAbsoluteTimeGetCurrent();
        if (due > now) usleep((useconds_t)((due - now) * 1e6));
        const double fs = CFAbsoluteTimeGetCurrent();
        id<MTLCommandBuffer> c1 = [q commandBuffer];
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = big[f % 3]; rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> re = [c1 renderCommandEncoderWithDescriptor:rp]; [re setRenderPipelineState:ps];
        for (uint32_t k = 0; k < (uint32_t)D; k++) { [re setFragmentBytes:&k length:4 atIndex:0]; [re drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4]; }
        [re endEncoding]; [c1 commit];
        id<MTLCommandBuffer> c2 = [q commandBuffer];
        rp.colorAttachments[0].texture = small[f % 3];
        re = [c2 renderCommandEncoderWithDescriptor:rp]; [re setRenderPipelineState:ps];
        uint32_t k = (uint32_t)f; [re setFragmentBytes:&k length:4 atIndex:0]; [re drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
        [re endEncoding]; [c2 commit];
        const double s0 = CFAbsoluteTimeGetCurrent(); [c2 waitUntilScheduled]; w[f] = (CFAbsoluteTimeGetCurrent() - s0) * 1000;
        if (CFAbsoluteTimeGetCurrent() - fs > P / 1000.0) over++;
        if (f == F - 1) [c2 waitUntilCompleted];
    } }
    double sum = 0; for (int i = 0; i < F; i++) sum += w[i];
    qsort(w, F, sizeof *w, cmpd);
    printf("schedlat %d frames, %d draws into 1856x1024 (pitch +%d), period %.2f ms: waitUntilScheduled mean %.2f ms p50 %.2f p95 %.2f max %.2f; frames over period %d\n",
           F, D, pad, P, sum / F, w[F / 2], w[F * 95 / 100], w[F - 1], over);
    return 0;
} }
