// surfimp: surface import cache test (run under plugshim). Chrome-like: every frame the IOSurface is looked up again from a mach port
// and wrapped in NEW textures. Checks (1) a texture written then another texture over a fresh lookup reads the same pixels (GPU copy to
// a buffer) and the CPU sees them after a lock, (2) 150 distinct surfaces cycled (idle-limit eviction), (3) a surface released and a new
// one created after the 1 s idle sweep reads its own contents; reports newTextureWithDescriptor:iosurface: time.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurface.h>
#import <mach/mach_time.h>
static IOSurfaceRef mk(int w, int h) {
    return IOSurfaceCreate((__bridge CFDictionaryRef)@{ (id)kIOSurfaceWidth: @(w), (id)kIOSurfaceHeight: @(h), (id)kIOSurfaceBytesPerElement: @4,
        (id)kIOSurfaceBytesPerRow: @(w * 4), (id)kIOSurfacePixelFormat: @((uint32_t)'BGRA') });
}
static IOSurfaceRef relook(IOSurfaceRef s) { mach_port_t p = IOSurfaceCreateMachPort(s); IOSurfaceRef r = IOSurfaceLookupFromMachPort(p); mach_port_deallocate(mach_task_self(), p); return r; }
int main(void) { @autoreleasepool {
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice(); id<MTLCommandQueue> q = [dev newCommandQueue];
    mach_timebase_info_data_t tbi; mach_timebase_info(&tbi); const double tb = (double)tbi.numer / tbi.denom;
    __block double texNs = 0; __block long texN = 0; __block int bad = 0;
    id<MTLTexture> (^tex)(IOSurfaceRef, int, int) = ^(IOSurfaceRef s, int w, int h) {
        MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:w height:h mipmapped:NO];
        d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead; d.storageMode = MTLStorageModeShared;
        const uint64_t t0 = mach_absolute_time(); id<MTLTexture> t = [dev newTextureWithDescriptor:d iosurface:s plane:0];
        texNs += (mach_absolute_time() - t0) * tb; texN++; return t; };
    id<MTLBuffer> out = [dev newBufferWithLength:16 options:MTLResourceStorageModeShared];
    // write colour c into s via a fresh lookup, read it back via another fresh lookup (GPU) and via the CPU
    BOOL (^roundtrip)(IOSurfaceRef, int, int, uint32_t, const char *) = ^BOOL(IOSurfaceRef s, int w, int h, uint32_t c, const char *what) { c &= 0xffffff;
        @autoreleasepool {
            IOSurfaceRef a = relook(s); id<MTLTexture> tw = tex(a, w, h); CFRelease(a);
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.colorAttachments[0].texture = tw; rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
            rp.colorAttachments[0].clearColor = MTLClearColorMake((c >> 16 & 255) / 255.0, (c >> 8 & 255) / 255.0, (c & 255) / 255.0, 1);
            id<MTLCommandBuffer> cb = [q commandBuffer]; [[cb renderCommandEncoderWithDescriptor:rp] endEncoding]; [cb commit]; [cb waitUntilCompleted];
            tw = nil;
            IOSurfaceRef b = relook(s); id<MTLTexture> tr = tex(b, w, h); CFRelease(b);
            cb = [q commandBuffer]; id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder];
            [bl copyFromTexture:tr sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(w - 1, h / 2, 0) sourceSize:MTLSizeMake(1, 1, 1)
                       toBuffer:out destinationOffset:0 destinationBytesPerRow:4 destinationBytesPerImage:4];
            [bl endEncoding]; [cb commit]; [cb waitUntilCompleted];
            const uint32_t g = *(uint32_t *)out.contents & 0xffffff;
            IOSurfaceLock(s, kIOSurfaceLockReadOnly, NULL);
            const uint32_t p = ((uint32_t *)IOSurfaceGetBaseAddress(s))[(h / 2) * (IOSurfaceGetBytesPerRow(s) / 4) + w - 1] & 0xffffff;
            IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL);
            if (g != c || p != c) { if (bad++ < 10) printf("%s: surface %u wrote %06x, GPU read %06x, CPU read %06x\n", what, IOSurfaceGetID(s), c, g, p); return NO; }
            return YES;
        }
    };
    // 1: Chrome's danmaku layer - same surfaces, new lookups + textures every frame
    IOSurfaceRef ring[3]; for (int i = 0; i < 3; i++) ring[i] = mk(1856, 1024);
    for (int f = 0; f < 300; f++) roundtrip(ring[f % 3], 1856, 1024, 0x102030u + (uint32_t)f * 0x010307u, "same surfaces");
    const double avg1 = texNs / texN / 1e6; texNs = 0; texN = 0;
    // 2: many distinct surfaces (idle limit 64 / eviction)
    for (int i = 0; i < 150; i++) { IOSurfaceRef s = mk(512, 512); roundtrip(s, 512, 512, 0x400000u + (uint32_t)i, "distinct surfaces"); CFRelease(s); }
    // 3: release everything, wait for the 1 s sweep, new surfaces of the same size must show their own contents
    for (int i = 0; i < 3; i++) CFRelease(ring[i]);
    [NSThread sleepForTimeInterval:1.6];
    for (int i = 0; i < 40; i++) { IOSurfaceRef s = mk(1856, 1024); roundtrip(s, 1856, 1024, 0x00a000u + (uint32_t)i, "after sweep"); CFRelease(s); }
    printf("newTextureWithDescriptor:iosurface: avg %.3f ms (same surfaces), %.3f ms (new surfaces)\n", avg1, texNs / texN / 1e6);
    printf("%s\n", bad ? "FAIL" : "PASS");
    return bad ? 1 : 0;
} }
