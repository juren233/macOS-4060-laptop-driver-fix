// upbench: what Chrome's GPU process does per composited 4K video frame - a pooled NV12 IOSurface whose contents changed,
// wrapped in NEW MTLTextures (plane 0 R8, plane 1 RG8) and read by the GPU. Reports CPU (main-thread) ms per frame.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <CoreVideo/CoreVideo.h>
#import <IOSurface/IOSurface.h>
#include <mach/mach_time.h>
static double now_ms(void) { static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb); return mach_absolute_time() * (double)tb.numer / tb.denom / 1e6; }
int main(int argc, char **argv) { @autoreleasepool {
    const int W = argc > 1 ? atoi(argv[1]) : 3840, H = argc > 2 ? atoi(argv[2]) : 2160, N = argc > 3 ? atoi(argv[3]) : 240, POOL = 8;
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice(); id<MTLCommandQueue> q = [dev newCommandQueue];
    IOSurfaceRef surf[POOL];
    for (int i = 0; i < POOL; i++) { CVPixelBufferRef pb = NULL;
        NSDictionary *a = @{ (id)kCVPixelBufferIOSurfacePropertiesKey: @{} };
        if (CVPixelBufferCreate(NULL, W, H, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, (__bridge CFDictionaryRef)a, &pb)) { printf("CVPixelBufferCreate failed\n"); return 1; }
        surf[i] = CVPixelBufferGetIOSurface(pb); CFRetain(surf[i]); CVPixelBufferRelease(pb); }
    MTLTextureDescriptor *dy = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm width:W height:H mipmapped:NO];
    MTLTextureDescriptor *dc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRG8Unorm width:W/2 height:H/2 mipmapped:NO];
    dy.usage = dc.usage = MTLTextureUsageShaderRead;
    MTLTextureDescriptor *py = [dy copy], *pc = [dc copy]; py.storageMode = pc.storageMode = MTLStorageModePrivate;
    id<MTLTexture> ty = [dev newTextureWithDescriptor:py], tc = [dev newTextureWithDescriptor:pc];
    const int verify = getenv("VERIFY") != NULL; int mism = 0; id<MTLBuffer> rb = [dev newBufferWithLength:(NSUInteger)W*H*3/2 options:MTLResourceStorageModeShared];
    double cpu = 0, worst = 0, t0 = now_ms(); id<MTLCommandBuffer> last = nil;
    for (int f = 0; f < N; f++) { @autoreleasepool {
        IOSurfaceRef s = surf[f % POOL];
        // the decoder rewrote the frame: touch both planes (one row each) so the seed moves - the upload copies it all anyway
        IOSurfaceLock(s, 0, NULL);
        if (verify) for (int pl = 0; pl < 2; pl++) { uint8_t *p = IOSurfaceGetBaseAddressOfPlane(s, pl); size_t row = IOSurfaceGetBytesPerRowOfPlane(s, pl), h = IOSurfaceGetHeightOfPlane(s, pl), w = IOSurfaceGetWidthOfPlane(s, pl) * (pl ? 2 : 1);
            for (size_t yy = 0; yy < h; yy++) for (size_t xx = 0; xx < w; xx++) p[yy * row + xx] = (uint8_t)(xx * 7 + yy * 13 + f * 31 + pl * 101); }
        else { memset(IOSurfaceGetBaseAddressOfPlane(s, 0), f & 255, W); memset(IOSurfaceGetBaseAddressOfPlane(s, 1), f & 255, W); }
        IOSurfaceUnlock(s, 0, NULL);
        const double a = now_ms();
        id<MTLTexture> y = [dev newTextureWithDescriptor:dy iosurface:s plane:0], c = [dev newTextureWithDescriptor:dc iosurface:s plane:1];
        id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
        [b copyFromTexture:y toTexture:ty]; [b copyFromTexture:c toTexture:tc];
        if (verify) { [b copyFromTexture:ty sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(W,H,1) toBuffer:rb destinationOffset:0 destinationBytesPerRow:W destinationBytesPerImage:(NSUInteger)W*H];
                      [b copyFromTexture:tc sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(W/2,H/2,1) toBuffer:rb destinationOffset:(NSUInteger)W*H destinationBytesPerRow:W destinationBytesPerImage:(NSUInteger)W*H/2]; }
        [b endEncoding]; [cb commit];
        if (verify) { [cb waitUntilCompleted]; const uint8_t *o = rb.contents; size_t bad = 0;
            for (int pl = 0; pl < 2; pl++) { size_t h = pl ? H/2 : H, w = W; const uint8_t *base = o + (pl ? (size_t)W*H : 0);
                for (size_t yy = 0; yy < h; yy++) for (size_t xx = 0; xx < w; xx++) bad += base[yy*w+xx] != (uint8_t)(xx * 7 + yy * 13 + f * 31 + pl * 101); }
            if (bad) { printf("MISMATCH frame %d: %zu bytes\n", f, bad); mism++; } }
        const double d = now_ms() - a; cpu += d; if (f >= 8 && d > worst) worst = d;
        [last waitUntilCompleted]; last = cb;   // keep at most two frames in flight, like a compositor
    } }
    [last waitUntilCompleted];
    if (verify) printf("VERIFY %s: %d of %d frames mismatched\n", mism ? "FAIL" : "PASS", mism, N);
    printf("RESULT %dx%d %d frames: CPU %.2f ms/frame (worst %.2f), wall %.2f ms/frame\n", W, H, N, cpu / N, worst, (now_ms() - t0) / N);
} return 0; }
