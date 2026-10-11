// mapstress: many threads create/release host-visible (mapped) buffers at once - every one is an RM map through a pooled
// connection. Counts buffers that came back nil. usage: mapstress <plugin> <vulkan-icd-dylib> [threads] [iters]
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOKit/IOKitLib.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <stdatomic.h>
int main(int argc, char **argv) { @autoreleasepool {
    if (argc < 3) { printf("usage\n"); return 2; }
    int T = argc > 3 ? atoi(argv[3]) : 8, N = argc > 4 ? atoi(argv[4]) : 150;
    if (!dlopen(argv[1], RTLD_NOW)) { printf("dlopen: %s\n", dlerror()); return 2; }
    setenv("NVMTL_ICD_LIB", argv[2], 1);
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"));
    id<MTLDevice> dev = ((id (*)(id, SEL, mach_port_t))objc_msgSend)([objc_getClass("NVMTLDevice") alloc], sel_registerName("initWithAcceleratorPort:"), svc);
    __block _Atomic int nilCount = 0, total = 0; dispatch_group_t g = dispatch_group_create();
    for (int t = 0; t < T; t++) dispatch_group_async(g, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        id keep[4] = { nil, nil, nil, nil }; unsigned s = 1234u * (t + 1);
        for (int i = 0; i < N; i++) { s = s * 1664525u + 1013904223u; size_t len = (1u << 20) + ((s >> 8) % (11u << 20)); len &= ~4095ul;
            id<MTLBuffer> b = [dev newBufferWithLength:len options:MTLResourceStorageModeShared]; atomic_fetch_add(&total, 1);
            if (!b) atomic_fetch_add(&nilCount, 1); else { ((uint8_t *)b.contents)[0] = 1; ((uint8_t *)b.contents)[len - 1] = 2; }
            keep[i & 3] = b; }
        for (int k = 0; k < 4; k++) keep[k] = nil; });
    dispatch_group_wait(g, DISPATCH_TIME_FOREVER);
    printf("%d threads x %d buffers: %d of %d came back nil  %s\n", T, N, nilCount, total, nilCount ? "FAIL" : "PASS"); return nilCount != 0; } }
