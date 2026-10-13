// chainstress: ordering stress for the plugin's submission engine (eager submit-ahead).
// Each thread owns two queues A and B and commits a long chain WITHOUT waiting: every A buffer increments a counter in a private
// buffer (each increment reads the previous one, so any reordering or double submit changes the result); every 5th also signals a
// shared event that B waits for before incrementing its own counter from A's value; every 7th also draws into an IOSurface-backed
// texture (surface-out work on the execution worker); every 11th is waited with waitUntilScheduled from the committing thread.
// At the end each thread checks A == number of A buffers and B's last copy of A == the value A had at that signal.
// usage: chainstress <plugin> <vulkan-icd> [threads] [buffers per thread]
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurface.h>
#import <IOKit/IOKitLib.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <stdatomic.h>
static const char *kSrc =
    "#include <metal_stdlib>\nusing namespace metal;\n"
    "kernel void inc(device uint *a [[buffer(0)]]) { a[0] = a[0] + 1; }\n"
    "kernel void take(device uint *a [[buffer(0)]], device uint *b [[buffer(1)]]) { b[0] = b[0] + 1; b[1] = a[0]; }\n"
    "struct V { float4 p [[position]]; };\n"
    "vertex V vq(uint i [[vertex_id]]) { float2 p[4] = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1) }; V o; o.p = float4(p[i], 0, 1); return o; }\n"
    "fragment float4 fc(V in [[stage_in]], constant uint &k [[buffer(0)]]) { return float4((k & 255) / 255.0, 0.5, 0.25, 1); }\n";
int main(int argc, char **argv) { @autoreleasepool {
    if (argc < 3) { printf("usage: chainstress <plugin> <vulkan-icd> [threads] [buffers]\n"); return 2; }
    const int T = argc > 3 ? atoi(argv[3]) : 4, N = argc > 4 ? atoi(argv[4]) / 5 * 5 : 600;
    if (!dlopen(argv[1], RTLD_NOW)) { printf("dlopen: %s\n", dlerror()); return 2; }
    setenv("NVMTL_ICD_LIB", argv[2], 1);
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"));
    id<MTLDevice> dev = ((id (*)(id, SEL, mach_port_t))objc_msgSend)([objc_getClass("NVMTLDevice") alloc], sel_registerName("initWithAcceleratorPort:"), svc);
    NSError *e = nil; id<MTLLibrary> lib = [dev newLibraryWithSource:@(kSrc) options:nil error:&e];
    if (!lib) { printf("library: %s\nFAIL\n", e.description.UTF8String); return 1; }
    id<MTLComputePipelineState> inc = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"inc"] error:&e];
    id<MTLComputePipelineState> take = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"take"] error:&e];
    MTLRenderPipelineDescriptor *rd = [MTLRenderPipelineDescriptor new];
    rd.vertexFunction = [lib newFunctionWithName:@"vq"]; rd.fragmentFunction = [lib newFunctionWithName:@"fc"];
    rd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    id<MTLRenderPipelineState> draw = [dev newRenderPipelineStateWithDescriptor:rd error:&e];
    if (!inc || !take || !draw) { printf("pipelines: %s\nFAIL\n", e.description.UTF8String); return 1; }
    __block _Atomic int bad = 0; __block _Atomic long sched_us = 0, sched_n = 0;
    const CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
    dispatch_group_t g = dispatch_group_create();
    for (int t = 0; t < T; t++) dispatch_group_async(g, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ @autoreleasepool {
        id<MTLCommandQueue> qa = [dev newCommandQueue], qb = [dev newCommandQueue];
        id<MTLBuffer> a = [dev newBufferWithLength:256 options:MTLResourceStorageModePrivate];
        id<MTLBuffer> b = [dev newBufferWithLength:256 options:MTLResourceStorageModePrivate];
        id<MTLBuffer> out = [dev newBufferWithLength:256 options:MTLResourceStorageModeShared];
        id<MTLSharedEvent> ev = [dev newSharedEvent];
        NSMutableArray *surfTex = [NSMutableArray new];
        for (int s = 0; s < 3; s++) {
            IOSurfaceRef sf = IOSurfaceCreate((__bridge CFDictionaryRef)@{ (id)kIOSurfaceWidth: @(256), (id)kIOSurfaceHeight: @(128),
                (id)kIOSurfaceBytesPerElement: @4, (id)kIOSurfacePixelFormat: @((uint32_t)'BGRA') });
            MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:256 height:128 mipmapped:NO];
            td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead; td.storageMode = MTLStorageModeShared;
            [surfTex addObject:[dev newTextureWithDescriptor:td iosurface:sf plane:0]]; CFRelease(sf);
        }
        { id<MTLCommandBuffer> cb = [qa commandBuffer]; id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder];
          [bl fillBuffer:a range:NSMakeRange(0, 256) value:0]; [bl fillBuffer:b range:NSMakeRange(0, 256) value:0]; [bl endEncoding];
          [cb commit]; [cb waitUntilCompleted]; }
        int nb = 0; uint32_t lastSignal = 0; id<MTLCommandBuffer> lastA = nil, lastB = nil;
        for (int i = 1; i <= N; i++) { @autoreleasepool {
            id<MTLCommandBuffer> cb = [qa commandBuffer];
            id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
            [ce setComputePipelineState:inc]; [ce setBuffer:a offset:0 atIndex:0];
            [ce dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)]; [ce endEncoding];
            if (i % 7 == 0) {
                MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
                rp.colorAttachments[0].texture = surfTex[i % 3]; rp.colorAttachments[0].loadAction = MTLLoadActionClear;
                rp.colorAttachments[0].storeAction = MTLStoreActionStore;
                id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
                uint32_t k = (uint32_t)i; [re setRenderPipelineState:draw]; [re setFragmentBytes:&k length:4 atIndex:0];
                [re drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4]; [re endEncoding];
            }
            if (i % 5 == 0) {
                [cb encodeSignalEvent:ev value:(uint64_t)i];
                // more work after the signal: the buffer is split into parts around it
                id<MTLComputeCommandEncoder> c2 = [cb computeCommandEncoder];
                [c2 setComputePipelineState:inc]; [c2 setBuffer:a offset:0 atIndex:0];
                [c2 dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)]; [c2 endEncoding];
            }
            [cb commit]; lastA = cb;
            if (i % 11 == 0) {
                const CFAbsoluteTime s0 = CFAbsoluteTimeGetCurrent(); [cb waitUntilScheduled];
                atomic_fetch_add(&sched_us, (long)((CFAbsoluteTimeGetCurrent() - s0) * 1e6)); atomic_fetch_add(&sched_n, 1);
                if (cb.status < MTLCommandBufferStatusScheduled) { atomic_fetch_add(&bad, 1); printf("thread %d buffer %d: status %ld after waitUntilScheduled\n", t, i, (long)cb.status); }
            }
            if (i % 5 == 0) {
                // A's value at signal i = i + (number of extra increments in buffers 5,10,...,i) = i + i/5 - 1 + 1 (this buffer's extra one comes after the signal)
                lastSignal = (uint32_t)(i + i / 5 - 1);
                id<MTLCommandBuffer> cbb = [qb commandBuffer];
                [cbb encodeWaitForEvent:ev value:(uint64_t)i];
                id<MTLComputeCommandEncoder> te = [cbb computeCommandEncoder];
                [te setComputePipelineState:take]; [te setBuffer:a offset:0 atIndex:0]; [te setBuffer:b offset:0 atIndex:1];
                [te dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)]; [te endEncoding];
                // copy b now: b[1] must be A's value at the signal - unless A's extra increment raced ahead (allowed: >= lastSignal)
                id<MTLBlitCommandEncoder> bl = [cbb blitCommandEncoder];
                [bl copyFromBuffer:b sourceOffset:0 toBuffer:out destinationOffset:16 * (nb % 8) size:8]; [bl endEncoding];
                [cbb commit]; lastB = cbb; nb++;
            }
        } }
        [lastA waitUntilCompleted]; [lastB waitUntilCompleted];
        if (lastA.status != MTLCommandBufferStatusCompleted || lastB.status != MTLCommandBufferStatusCompleted) { atomic_fetch_add(&bad, 1); printf("thread %d: final status A %ld B %ld\n", t, (long)lastA.status, (long)lastB.status); }
        id<MTLCommandBuffer> cb = [qa commandBuffer]; id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder];
        [bl copyFromBuffer:a sourceOffset:0 toBuffer:out destinationOffset:200 size:4]; [bl endEncoding]; [cb commit]; [cb waitUntilCompleted];
        const uint32_t *o = out.contents;
        const uint32_t wantA = (uint32_t)(N + N / 5);
        const uint32_t *lb = o + 4 * ((nb - 1) % 8);
        if (o[50] != wantA) { atomic_fetch_add(&bad, 1); printf("thread %d: A = %u, want %u\n", t, o[50], wantA); }
        if (lb[0] != (uint32_t)nb) { atomic_fetch_add(&bad, 1); printf("thread %d: B count = %u, want %d\n", t, lb[0], nb); }
        if (lb[1] < lastSignal || lb[1] > lastSignal + 1) { atomic_fetch_add(&bad, 1); printf("thread %d: B saw A = %u, want %u (or +1)\n", t, lb[1], lastSignal); }
    } });
    dispatch_group_wait(g, DISPATCH_TIME_FOREVER);
    const double secs = CFAbsoluteTimeGetCurrent() - t0;
    printf("%d threads x %d buffers (+%d waits on events) in %.2f s; waitUntilScheduled avg %.0f us over %ld\n", T, N, T * (N / 5), secs,
           sched_n ? (double)sched_us / sched_n : 0.0, (long)sched_n);
    printf("%s\n", bad ? "FAIL" : "PASS");
    return bad ? 1 : 0;
} }
