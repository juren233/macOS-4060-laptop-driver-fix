// mixstress: several threads at once compile a fresh shader, build a pipeline, make textures/buffers, draw, commit and read back
// (what Chrome's GPU process does from its main thread, raster threads and command-buffer completion threads).
// usage: mixstress <plugin> <vulkan-icd> [threads] [iters]
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOKit/IOKitLib.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <stdatomic.h>
int main(int argc, char **argv) { @autoreleasepool {
    int T = argc > 3 ? atoi(argv[3]) : 6, N = argc > 4 ? atoi(argv[4]) : 40;
    if (!dlopen(argv[1], RTLD_NOW)) { printf("dlopen: %s\n", dlerror()); return 2; }
    setenv("NVMTL_ICD_LIB", argv[2], 1);
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"));
    id<MTLDevice> dev = ((id (*)(id, SEL, mach_port_t))objc_msgSend)([objc_getClass("NVMTLDevice") alloc], sel_registerName("initWithAcceleratorPort:"), svc);
    __block _Atomic int bad = 0, total = 0; dispatch_group_t g = dispatch_group_create();
    for (int t = 0; t < T; t++) dispatch_group_async(g, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        id<MTLCommandQueue> q = [dev newCommandQueue];
        for (int i = 0; i < N; i++) { @autoreleasepool {
            atomic_fetch_add(&total, 1);
            NSString *src = [NSString stringWithFormat:@"#include <metal_stdlib>\nusing namespace metal;\nstruct V { float4 p [[position]]; };\n"
                "vertex V vq(uint i [[vertex_id]]) { float2 p[4] = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1) }; V o; o.p = float4(p[i], 0, 1); return o; }\n"
                "fragment float4 fc(V in [[stage_in]]) { return float4(%d / 255.0, %d / 255.0, 0.25, 1); }\n", (t * 37 + i * 7) & 255, (i * 13 + t) & 255];
            NSError *e = nil; id<MTLLibrary> lib = [dev newLibraryWithSource:src options:nil error:&e]; if (!lib) { atomic_fetch_add(&bad, 1); continue; }
            MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new]; d.vertexFunction = [lib newFunctionWithName:@"vq"]; d.fragmentFunction = [lib newFunctionWithName:@"fc"]; d.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
            id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:d error:&e]; if (!ps) { atomic_fetch_add(&bad, 1); continue; }
            int W = 256 + (i % 5) * 128, H = 256 + (t % 3) * 128;
            MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:W height:H mipmapped:NO]; td.usage = MTLTextureUsageRenderTarget; td.storageMode = MTLStorageModePrivate;
            id<MTLTexture> tex = [dev newTextureWithDescriptor:td]; id<MTLBuffer> rb = [dev newBufferWithLength:(size_t)W * H * 4 options:MTLResourceStorageModeShared];
            if (!tex || !rb) { atomic_fetch_add(&bad, 1); continue; }
            id<MTLCommandBuffer> cb = [q commandBuffer]; MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.colorAttachments[0].texture = tex; rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
            id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp]; [re setRenderPipelineState:ps]; [re drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4]; [re endEncoding];
            id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder]; [bl copyFromTexture:tex sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(W,H,1) toBuffer:rb destinationOffset:0 destinationBytesPerRow:(size_t)W * 4 destinationBytesPerImage:(size_t)W * H * 4]; [bl endEncoding];
            [cb commit]; [cb waitUntilCompleted];
            const uint8_t *p = rb.contents; int want_r = (t * 37 + i * 7) & 255; if (cb.error || abs((int)p[2] - want_r) > 1) atomic_fetch_add(&bad, 1); } } });
    dispatch_group_wait(g, DISPATCH_TIME_FOREVER);
    printf("%d threads x %d iterations: %d of %d wrong or failed  %s\n", T, N, bad, total, bad ? "FAIL" : "PASS"); return bad != 0; } }
