// surftex: GPU writes an IOSurface through one MTLTexture, then a SECOND MTLTexture made on the same IOSurface is read.
// That second texture must show what the GPU wrote (WindowServer wraps its cache surfaces in fresh textures all the time).
// Prints "stale reads: N" (0 = good).
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurface.h>
static IOSurfaceRef mksurf(int w, int h) {
    return IOSurfaceCreate((__bridge CFDictionaryRef)@{ (id)kIOSurfaceWidth: @(w), (id)kIOSurfaceHeight: @(h), (id)kIOSurfaceBytesPerElement: @4,
        (id)kIOSurfaceBytesPerRow: @(w * 4), (id)kIOSurfacePixelFormat: @((uint32_t)'BGRA') }); }
int main(int argc, char **argv) { @autoreleasepool {
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice(); id<MTLCommandQueue> q = [dev newCommandQueue];
    const int W = argc > 2 ? atoi(argv[1]) : 64, H = argc > 2 ? atoi(argv[2]) : 64; int stale = 0;
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:W height:H mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead; td.storageMode = MTLStorageModeShared;
    id<MTLTexture> rb = [dev newTextureWithDescriptor:td];
    { IOSurfaceRef s = mksurf(1, 1); uint32_t a = IOSurfaceGetSeed(s); IOSurfaceSetValue(s, CFSTR("x"), kCFBooleanTrue); uint32_t b = IOSurfaceGetSeed(s);
      IOSurfaceLock(s, kIOSurfaceLockReadOnly, NULL); IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL); uint32_t c = IOSurfaceGetSeed(s);
      printf("seed: new %u, after SetValue %u, after read-only lock %u\n", a, b, c); CFRelease(s); }
    for (int mode = 0; mode < 7; mode++) {
        // mode 0: clear-pass write, wait, new texture   1: load-pass draw-less write via blit, wait   2: like 0 without wait
        // 3: like 1 without wait   4: write and read in ONE command buffer via two textures   5: like 0, CPU reads surface after
        // 6: like 2 but the writing texture is released before the reading one is made
        IOSurfaceRef s = mksurf(W, H);
        IOSurfaceLock(s, 0, NULL); memset(IOSurfaceGetBaseAddress(s), 0x11, W * H * 4); IOSurfaceUnlock(s, 0, NULL);
        const uint8_t want[4] = { (uint8_t)(0x30 + mode), 0x80, 0xC0, 0xFF };
        __strong id<MTLTexture> t1 = [dev newTextureWithDescriptor:td iosurface:s plane:0];
        id<MTLCommandBuffer> cb = [q commandBuffer];
        if (mode == 1 || mode == 3) {
            id<MTLTexture> src = [dev newTextureWithDescriptor:td]; uint8_t *px = malloc((size_t)W * H * 4); for (int i = 0; i < W * H; i++) memcpy(px + i * 4, want, 4);
            [src replaceRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0 withBytes:px bytesPerRow:W * 4]; free(px);
            id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder]; [b copyFromTexture:src toTexture:t1]; [b endEncoding];
        } else {
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor]; rp.colorAttachments[0].texture = t1;
            rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
            rp.colorAttachments[0].clearColor = MTLClearColorMake(want[2] / 255.0, want[1] / 255.0, want[0] / 255.0, 1);
            [[cb renderCommandEncoderWithDescriptor:rp] endEncoding];
        }
        id<MTLCommandBuffer> cb2 = cb;
        if (mode != 4) { [cb commit]; if (mode != 2 && mode != 3 && mode != 6) [cb waitUntilCompleted]; cb2 = [q commandBuffer]; }
        if (mode == 6) t1 = nil;
        if (mode == 5) { IOSurfaceLock(s, kIOSurfaceLockReadOnly, NULL); const uint8_t *p = IOSurfaceGetBaseAddress(s);
            printf("  mode 5: CPU sees %02x %02x %02x %02x after the GPU write\n", p[0], p[1], p[2], p[3]); IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL); }
        id<MTLTexture> t2 = [dev newTextureWithDescriptor:td iosurface:s plane:0];
        id<MTLBlitCommandEncoder> b = [cb2 blitCommandEncoder]; [b copyFromTexture:t2 toTexture:rb]; [b endEncoding];
        [cb2 commit]; [cb2 waitUntilCompleted];
        uint8_t got[4]; [rb getBytes:got bytesPerRow:W * 4 fromRegion:MTLRegionMake2D(5, 5, 1, 1) mipmapLevel:0];
        const int ok = !memcmp(got, want, 4); stale += !ok;
        printf("mode %d: second texture reads %02x %02x %02x %02x, want %02x %02x %02x %02x %s\n", mode, got[0], got[1], got[2], got[3],
               want[0], want[1], want[2], want[3], ok ? "OK" : "STALE");
        CFRelease(s);
    }
    printf("stale reads: %d\n", stale);
    return 0;
}}
