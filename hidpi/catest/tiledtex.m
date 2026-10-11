// tiledtex: the path Core Animation uses for small shared-memory layer contents -- a texture made over a buffer with
// newTiledTextureWithDescriptor:offset:bytesPerRow:, where the buffer is written AFTER the texture exists.
// With a row pitch the GPU cannot alias (not a multiple of 32 B) the driver falls back to a copy; this checks
// whether later writes to the buffer still reach the texture.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/message.h>
int main(void) { @autoreleasepool {
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice(); id<MTLCommandQueue> q = [dev newCommandQueue];
    const int W = 44, H = 16; int fails = 0;
    for (int pass = 0; pass < 2; pass++) {
        const NSUInteger bpr = pass ? 192 : 176, off = pass ? 3120 : 0;   // 176: pitch not 32-aligned; 3120: offset not 32-aligned
        id<MTLBuffer> buf = [dev newBufferWithLength:off + bpr * H options:MTLResourceStorageModeShared];
        memset(buf.contents, 0x40, buf.length);                               // old contents (a recycled buffer)
        MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:W height:H mipmapped:NO];
        d.storageMode = MTLStorageModeShared; d.usage = MTLTextureUsageShaderRead;
        SEL s = NSSelectorFromString(@"newTiledTextureWithDescriptor:offset:bytesPerRow:");
        id<MTLTexture> t = [(id)buf respondsToSelector:s] ? ((id (*)(id, SEL, id, NSUInteger, NSUInteger))objc_msgSend)(buf, s, d, off, bpr) : nil;
        if (!t) { printf("pass %d: no tiled texture\n", pass); continue; }
        for (int step = 0; step < 3; step++) {
            const uint8_t v = (uint8_t)(0x80 + step * 0x30);
            for (int y = 0; y < H; y++) memset((uint8_t *)buf.contents + off + y * bpr, v, W * 4);   // new contents, written after
            // Sample it on the GPU: blit the texture to a fresh one and read that back.
            MTLTextureDescriptor *od = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:W height:H mipmapped:NO];
            od.storageMode = MTLStorageModeShared;
            id<MTLTexture> o = [dev newTextureWithDescriptor:od];
            id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
            [b copyFromTexture:t toTexture:o]; [b endEncoding]; [cb commit]; [cb waitUntilCompleted];
            uint8_t p[4]; [o getBytes:p bytesPerRow:W * 4 fromRegion:MTLRegionMake2D(W / 2, H / 2, 1, 1) mipmapLevel:0];
            printf("pass %d (pitch %lu off %lu) step %d: wrote 0x%02x, GPU sees 0x%02x %s\n", pass, (unsigned long)bpr, (unsigned long)off, step, v, p[0], p[0] == v ? "ok" : "STALE");
            if (p[0] != v) fails++;
        }
    }
    printf("stale reads: %d\n", fails);
    return fails != 0;
}}
