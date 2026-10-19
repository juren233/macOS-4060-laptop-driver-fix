// plugshim: DYLD_INSERT_LIBRARIES=plugshim.dylib NVMTL_TEST_PLUGIN=/path/NVMTLDriver <test> - makes [SHIM_ICD=<libvulkan_nouveau>]
// MTLCreateSystemDefaultDevice() in a catest binary return a device of the given plugin build (not the installed one).
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOKit/IOKitLib.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
// MTLCreateSystemDefaultDevice returns +1 and ARC callers release it: return retained too, or every call inside the plugin (static
// samplers create their states through it) drops one reference and the device is freed under VideoToolbox's two-pass scaler.
__attribute__((ns_returns_retained)) static id<MTLDevice> shim_create(void) {
    static id<MTLDevice> dev; static dispatch_once_t once;
    dispatch_once(&once, ^{
        // SHIM_PLUGIN too: a release plugin scrubs NVMTL_* from the environment, so a child the test spawns (gfx4's producer)
        // would lose NVMTL_TEST_PLUGIN and fall back to the installed build
        const char *p = getenv("NVMTL_TEST_PLUGIN"); if (!p) p = getenv("SHIM_PLUGIN");
        if (!p || !dlopen(p, RTLD_NOW)) { fprintf(stderr, "plugshim: dlopen %s: %s\n", p ? p : "(unset)", dlerror()); exit(3); }
        io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"));
        dev = ((id (*)(id, SEL, mach_port_t))objc_msgSend)([objc_getClass("NVMTLDevice") alloc], sel_registerName("initWithAcceleratorPort:"), svc);
        fprintf(stderr, "plugshim: device from %s\n", p);
    });
    return dev;
}
// Apple's GL-on-Metal renderer (AppleMetalOpenGLRenderer) finds its device through MTLCopyAllDevices, not the default device.
static void *shim_copy_all(void) { return (void *)CFBridgingRetain(@[shim_create()]); }   // MTLCopyAllDevices returns +1
__attribute__((used)) static struct { const void *rep, *orig; } interposers[] __attribute__((section("__DATA,__interpose"))) = {
    { (const void *)shim_create, (const void *)MTLCreateSystemDefaultDevice },
    { (const void *)shim_copy_all, (const void *)MTLCopyAllDevices } };
// SHIM_ICD=/path/libvulkan_nouveau.dylib: the plugin's dlopen of the installed Vulkan driver loads this file instead
// (a release plugin ignores NVMTL_ICD_LIB, so this is the only way to pair a test build with a test driver)
#include <string.h>
static void *shim_dlopen(const char *path, int mode) {
    const char *alt = getenv("SHIM_ICD");
    if (path && alt && !strcmp(path, "/Library/GPUBundles/nvmtl/libvulkan_nouveau.dylib")) path = alt;
    return dlopen(path, mode);
}
__attribute__((used)) static struct { const void *rep, *orig; } interposers_dl[] __attribute__((section("__DATA,__interpose"))) = {
    { (const void *)shim_dlopen, (const void *)dlopen } };
