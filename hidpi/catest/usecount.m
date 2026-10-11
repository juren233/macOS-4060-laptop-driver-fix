// IOSurfaceIsInUse must be true while committed GPU work still reads/writes a surface-backed texture, false after completion
// (Chromium / CVPixelBufferPool recycle surfaces by it). Prints PASS / FAIL.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurface.h>
#import <IOKit/IOKitLib.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
int main(int argc, char **argv) { @autoreleasepool {
    id<MTLDevice> dev;
    if (argc > 1) { if (!dlopen(argv[1], RTLD_NOW)) { printf("dlopen: %s\n", dlerror()); return 2; }
        io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"));
        dev = ((id (*)(id, SEL, mach_port_t))objc_msgSend)([objc_getClass("NVMTLDevice") alloc], sel_registerName("initWithAcceleratorPort:"), svc);
    } else dev = MTLCreateSystemDefaultDevice();
    id<MTLCommandQueue> q = [dev newCommandQueue]; int ok = 0, n = 0;
    const int sizes[][2] = { { 256, 256 }, { 3840, 2160 } };  // private image and shared-VRAM sized
    for (int k = 0; k < 2; k++) {
        const int W = sizes[k][0], H = sizes[k][1];
        IOSurfaceRef s = IOSurfaceCreate((__bridge CFDictionaryRef)@{ (id)kIOSurfaceWidth: @(W), (id)kIOSurfaceHeight: @(H), (id)kIOSurfaceBytesPerElement: @4, (id)kIOSurfacePixelFormat: @((uint32_t)'BGRA') });
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:W height:H mipmapped:NO];
        td.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
        id<MTLTexture> t = [dev newTextureWithDescriptor:td iosurface:s plane:0];
        id<MTLBuffer> big = [dev newBufferWithLength:(size_t)W * H * 4 options:MTLResourceStorageModePrivate];
        const BOOL before = IOSurfaceIsInUse(s);
        id<MTLCommandBuffer> cb = [q commandBuffer];
        for (int r = 0; r < 20; r++) {  // render + copies so the work is still running right after commit
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.colorAttachments[0].texture = t; rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
            [[cb renderCommandEncoderWithDescriptor:rp] endEncoding];
            id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
            [b copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(W,H,1) toBuffer:big destinationOffset:0 destinationBytesPerRow:W*4 destinationBytesPerImage:(size_t)W*H*4];
            [b endEncoding];
        }
        [cb commit];
        const BOOL during = IOSurfaceIsInUse(s);
        [cb waitUntilCompleted];
        usleep(20000);
        const BOOL after = IOSurfaceIsInUse(s);
        t = nil; cb = nil;
        const BOOL pass = !before && during && !after;
        printf("%dx%d: in use before %d, right after commit %d, after completion %d -> %s\n", W, H, before, during, after, pass ? "OK" : "WRONG");
        ok += pass; n++; CFRelease(s);
    }
    printf("%s\n", ok == n ? "PASS" : "FAIL"); return ok == n ? 0 : 1;
}}
