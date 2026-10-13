// newsurf: Chrome render-pass-overlay pattern - every frame a NEW 1856x1024 BGRA IOSurface, a texture on it, a clear+draw into it,
// commit, then texture + surface released. Reports per-step time (newTextureWithDescriptor:iosurface:, encode+commit, wait, release).
// usage: [PRETOUCH=1: CPU-touch every page first, timed in IOSurfaceCreate] newsurf [frames] [w] [h]   (installed plugin; under plugshim for a staged build)
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurface.h>
#import <mach/mach_time.h>
int main(int argc, char **argv) { @autoreleasepool {
    const int N = argc > 1 ? atoi(argv[1]) : 300, W = argc > 2 ? atoi(argv[2]) : 1856, H = argc > 3 ? atoi(argv[3]) : 1024;
    mach_timebase_info_data_t tbi; mach_timebase_info(&tbi); const double tb = (double)tbi.numer / tbi.denom / 1e6;
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice(); id<MTLCommandQueue> q = [dev newCommandQueue];
    double tCreate = 0, tTex = 0, tEnc = 0, tWait = 0, tRel = 0, tTexMax = 0; id<MTLCommandBuffer> prev = nil;
    for (int i = 0; i < N; i++) { @autoreleasepool {
        uint64_t a = mach_absolute_time();
        IOSurfaceRef s = IOSurfaceCreate((__bridge CFDictionaryRef)@{ (id)kIOSurfaceWidth: @(W), (id)kIOSurfaceHeight: @(H), (id)kIOSurfaceBytesPerElement: @4,
            (id)kIOSurfacePixelFormat: @((uint32_t)'BGRA') });
        if (getenv("PRETOUCH")) { IOSurfaceLock(s, 0, NULL); volatile char *m = IOSurfaceGetBaseAddress(s); for (size_t o = 0; o < IOSurfaceGetAllocSize(s); o += 4096) m[o] = 0; IOSurfaceUnlock(s, 0, NULL); }
        uint64_t b = mach_absolute_time();
        MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:W height:H mipmapped:NO];
        d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead; d.storageMode = MTLStorageModeShared;
        id<MTLTexture> t = [dev newTextureWithDescriptor:d iosurface:s plane:0];
        uint64_t c = mach_absolute_time();
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = t; rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        rp.colorAttachments[0].clearColor = MTLClearColorMake((i & 255) / 255.0, 0.5, 0.25, 1);
        id<MTLCommandBuffer> cb = [q commandBuffer]; [[cb renderCommandEncoderWithDescriptor:rp] endEncoding]; [cb commit];
        uint64_t e = mach_absolute_time();
        [prev waitUntilCompleted]; prev = cb;
        uint64_t f = mach_absolute_time();
        t = nil; CFRelease(s);
        uint64_t g = mach_absolute_time();
        tCreate += (b - a) * tb; tTex += (c - b) * tb; tEnc += (e - c) * tb; tWait += (f - e) * tb; tRel += (g - f) * tb;
        if ((c - b) * tb > tTexMax) tTexMax = (c - b) * tb;
    } }
    [prev waitUntilCompleted];
    printf("%d frames %dx%d: IOSurfaceCreate %.3f ms, newTexture(iosurface) %.3f ms (max %.2f), encode+commit %.3f ms, wait prev %.3f ms, release %.3f ms (per frame)\n",
           N, W, H, tCreate / N, tTex / N, tTexMax, tEnc / N, tWait / N, tRel / N);
    return 0;
} }
