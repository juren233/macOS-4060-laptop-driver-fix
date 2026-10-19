// secreg <case>: 2.3.7 security bounds (upstream 5d8f92d / 4151e0d / 1321113) through the plugin, one case per process (a pre-2.3.7
// build may crash on some). Prints "<case> PASS|FAIL <why>".
//  wrap2d    replaceRegion with origin.x = 2^32 must be refused; narrowed to 32 bits it read as 0 and overwrote texel (0,0)
//  get2d     getBytes with origin.x = 2^32 must be refused; narrowed it returned texel (0,0) into the caller's buffer
//  tbwrite   texture-buffer replaceRegion at origin.x = 2^64 - 2, width 4: origin + width wraps to 2 and passed the bounds test
//  tbread    the same region through getBytes
//  vkwrite   replaceRegion of a 2D texture at x = 2^32 - 2, w = 4 (fits 32 bits, x + w wraps): nvmtl_vk_image_write_region
//  argoff    argument encoder setBuffer offset past the buffer's length must leave the argument buffer field untouched
//  ok        an in-bounds replaceRegion/getBytes round trip still works (sanity)
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <string.h>
static int res(const char *c, int ok, const char *why) { printf("%s %s %s\n", c, ok ? "PASS" : "FAIL", why); return ok ? 0 : 1; }
int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 2) { fprintf(stderr, "usage: secreg wrap2d|get2d|tbwrite|tbread|vkwrite|argoff|ok\n"); return 2; }
        const char *c = argv[1];
        id<MTLDevice> d = MTLCreateSystemDefaultDevice();
        if (!d) return res(c, 0, "no device");
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:64 height:64 mipmapped:NO];
        td.storageMode = MTLStorageModeShared; td.usage = MTLTextureUsageShaderRead;
        uint32_t fill[64 * 64]; for (int i = 0; i < 64 * 64; i++) fill[i] = 0x11111111u;
        uint32_t bad[16]; for (int i = 0; i < 16; i++) bad[i] = 0xFFFFFFFFu;
        if (!strcmp(c, "ok") || !strcmp(c, "wrap2d") || !strcmp(c, "get2d") || !strcmp(c, "vkwrite")) {
            id<MTLTexture> t = [d newTextureWithDescriptor:td];
            if (!t) return res(c, 0, "no texture");
            [t replaceRegion:MTLRegionMake2D(0, 0, 64, 64) mipmapLevel:0 withBytes:fill bytesPerRow:64 * 4];
            uint32_t back[64 * 64];
            if (!strcmp(c, "ok")) {
                [t replaceRegion:MTLRegionMake2D(5, 7, 2, 2) mipmapLevel:0 withBytes:bad bytesPerRow:8];
                memset(back, 0, sizeof back);
                [t getBytes:back bytesPerRow:64 * 4 fromRegion:MTLRegionMake2D(0, 0, 64, 64) mipmapLevel:0];
                return res(c, back[7 * 64 + 5] == 0xFFFFFFFFu && back[8 * 64 + 6] == 0xFFFFFFFFu && back[0] == 0x11111111u, "in-bounds write/read");
            }
            if (!strcmp(c, "wrap2d") || !strcmp(c, "vkwrite")) {
                MTLRegion r = !strcmp(c, "wrap2d") ? MTLRegionMake2D(1ull << 32, 0, 4, 1) : MTLRegionMake2D(0xFFFFFFFEull, 0, 4, 1);
                @try { [t replaceRegion:r mipmapLevel:0 withBytes:bad bytesPerRow:16]; } @catch (NSException *e) { }
                memset(back, 0, sizeof back);
                [t getBytes:back bytesPerRow:64 * 4 fromRegion:MTLRegionMake2D(0, 0, 64, 64) mipmapLevel:0];
                int clean = 1; for (int i = 0; i < 64 * 64; i++) if (back[i] != 0x11111111u) { clean = 0; break; }
                return res(c, clean, clean ? "texture unchanged" : "the out-of-range region was written into the texture");
            }
            // get2d: the caller's buffer must stay as it was
            uint32_t out[4]; for (int i = 0; i < 4; i++) out[i] = 0xA5A5A5A5u;
            @try { [t getBytes:out bytesPerRow:16 fromRegion:MTLRegionMake2D(1ull << 32, 0, 4, 1) mipmapLevel:0]; } @catch (NSException *e) { }
            return res(c, out[0] == 0xA5A5A5A5u, out[0] == 0x11111111u ? "texel (0,0) came back for origin 2^32" : "caller buffer untouched");
        }
        if (!strcmp(c, "tbwrite") || !strcmp(c, "tbread")) {
            id<MTLBuffer> b = [d newBufferWithLength:4096 options:MTLResourceStorageModeShared];
            memset(b.contents, 0x22, 4096);
            MTLTextureDescriptor *bd = [MTLTextureDescriptor textureBufferDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:256
                                                                                   resourceOptions:MTLResourceStorageModeShared usage:MTLTextureUsageShaderRead];
            id<MTLTexture> t = [b newTextureWithDescriptor:bd offset:0 bytesPerRow:1024];
            if (!t) return res(c, 0, "no texture-buffer view");
            MTLRegion r = MTLRegionMake1D(UINT64_MAX - 1, 4);
            uint32_t out[4]; for (int i = 0; i < 4; i++) out[i] = 0xA5A5A5A5u;
            @try {
                if (!strcmp(c, "tbwrite")) [t replaceRegion:r mipmapLevel:0 slice:0 withBytes:bad bytesPerRow:16 bytesPerImage:16];
                else [t getBytes:out bytesPerRow:16 bytesPerImage:16 fromRegion:r mipmapLevel:0 slice:0];
            } @catch (NSException *e) { }
            const uint8_t *p = b.contents; int clean = 1; for (int i = 0; i < 4096; i++) if (p[i] != 0x22) { clean = 0; break; }
            return res(c, clean && out[0] == 0xA5A5A5A5u, clean && out[0] == 0xA5A5A5A5u ? "refused, nothing copied" : "the wrapped region was copied");
        }
        if (!strcmp(c, "argoff")) {
            NSError *e = nil;
            id<MTLLibrary> lib = [d newLibraryWithSource:
                @"#include <metal_stdlib>\nusing namespace metal;\nstruct A { device uint *p [[id(0)]]; };\n"
                 "kernel void k(device A &a [[buffer(0)]], device uint *o [[buffer(1)]]) { o[0] = a.p[0]; }\n" options:nil error:&e];
            id<MTLFunction> f = [lib newFunctionWithName:@"k"];
            if (!f) return res(c, 0, "kernel did not compile");
            id<MTLArgumentEncoder> enc = [f newArgumentEncoderWithBufferIndex:0];
            id<MTLBuffer> ab = [d newBufferWithLength:enc.encodedLength options:MTLResourceStorageModeShared];
            memset(ab.contents, 0x5A, ab.length);
            id<MTLBuffer> small = [d newBufferWithLength:256 options:MTLResourceStorageModeShared];
            [enc setArgumentBuffer:ab offset:0];
            @try { [enc setBuffer:small offset:1ull << 40 atIndex:0]; } @catch (NSException *x) { }
            const uint8_t *p = ab.contents; int clean = 1; for (NSUInteger i = 0; i < ab.length; i++) if (p[i] != 0x5A) { clean = 0; break; }
            return res(c, clean, clean ? "field untouched" : "an address 1 TB past a 256-byte buffer was encoded");
        }
        return res(c, 0, "unknown case");
    }
}
