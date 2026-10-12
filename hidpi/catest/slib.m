#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOKit/IOKitLib.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
// slib <metallib> [plugin-dir/NVMTLDriver] [list]: build a pipeline for every function of a system metallib (SkyLight's compositor shaders
// by default) on the given plugin build, and print which ones fail. A failing pipeline is what crashes WindowServer (nil in CopyPipelineState).
int main(int argc, char **argv) { @autoreleasepool {
    const char *lp = argc > 1 ? argv[1] : "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/SkyLightShaders.air64.metallib";
    id<MTLDevice> dev;
    if (argc > 2 && argv[2][0] != '-') { if (!dlopen(argv[2], RTLD_NOW)) { printf("dlopen: %s\n", dlerror()); return 2; }
        io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"));
        dev = ((id (*)(id, SEL, mach_port_t))objc_msgSend)([objc_getClass("NVMTLDevice") alloc], sel_registerName("initWithAcceleratorPort:"), svc);
    } else dev = MTLCreateSystemDefaultDevice();
    int list = argc > 3;
    NSError *e = nil; id<MTLLibrary> lib = [dev newLibraryWithURL:[NSURL fileURLWithPath:@(lp)] error:&e];
    if (!lib) { printf("library FAILED: %s\n", e.localizedDescription.UTF8String); return 1; }
    NSArray *names = [lib.functionNames sortedArrayUsingSelector:@selector(compare:)];
    int ok = 0, bad = 0;
    for (NSString *n in names) {
        id<MTLFunction> f = [lib newFunctionWithName:n];
        if (!f) { printf("NOFUNC %s\n", n.UTF8String); bad++; continue; }
        const char *t = f.functionType == MTLFunctionTypeVertex ? "vertex" : f.functionType == MTLFunctionTypeFragment ? "fragment" : "kernel";
        if (list) { printf("%s %s\n", t, n.UTF8String); continue; }
        NSError *pe = nil; id pso = nil;
        if (f.functionType == MTLFunctionTypeKernel) pso = [dev newComputePipelineStateWithFunction:f error:&pe];
        else if (f.functionType == MTLFunctionTypeVertex) {
            MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new]; d.vertexFunction = f; d.rasterizationEnabled = NO;
            pso = [dev newRenderPipelineStateWithDescriptor:d error:&pe];
        } else {
            // fragment: pair with each vertex function until one links (interface must match); report if none does
            int built = 0; NSString *last = @"";
            for (NSString *vn in names) {
                id<MTLFunction> vf = [lib newFunctionWithName:vn]; if (vf.functionType != MTLFunctionTypeVertex) continue;
                MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new]; d.vertexFunction = vf; d.fragmentFunction = f;
                for (int c = 0; c < 4; c++) d.colorAttachments[c].pixelFormat = MTLPixelFormatBGRA8Unorm;
                NSError *e2 = nil; id p = [dev newRenderPipelineStateWithDescriptor:d error:&e2];
                if (p) { built = 1; break; } else last = e2.localizedDescription;
            }
            if (built) ok++; else { bad++; printf("FAIL fragment %s (no vertex pairing builds): %s\n", n.UTF8String, [last UTF8String]); }
            continue;
        }
        if (pso) ok++; else { bad++; printf("FAIL %s %s: %s\n", t, n.UTF8String, pe.localizedDescription.UTF8String); }
    }
    printf("functions %lu, built ok %d, failed %d\n", (unsigned long)names.count, ok, bad);
    return bad != 0;
} }
