// surfasync: CPU-written IOSurfaces sampled again and again through private-image textures (the surface-in path that
// WindowServer runs for every small layer / video frame). Checks that each GPU read sees the CPU's latest pages, with the
// asynchronous upload (NVMTL_SURFIN_ASYNC) and the GPU reading imported surface pages on repeat uploads.
//   surfasync [plugin-binary]   - with a path, that NVMTLDriver build is loaded into this process instead of the installed one
// Prints "stale reads: N" last (0 = good). "newer" reads (a pipelined read that already saw a LATER CPU write) are fine:
// Apple GPUs read IOSurface memory when the command runs, too.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurface.h>
#import <IOKit/IOKitLib.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

static id<MTLDevice> mkdev(const char *plugin) {
    if (!plugin) return MTLCreateSystemDefaultDevice();
    if (!dlopen(plugin, RTLD_NOW)) { printf("dlopen %s: %s\n", plugin, dlerror()); exit(2); }
    Class c = objc_getClass("NVMTLDevice");
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"));
    if (!c || !svc) { printf("no NVMTLDevice class / accelerator\n"); exit(2); }
    id d = ((id (*)(id, SEL, mach_port_t))objc_msgSend)([c alloc], sel_registerName("initWithAcceleratorPort:"), svc);
    return d;
}
static IOSurfaceRef mksurf(int w, int h, uint32_t fmt, int bpe) {
    return IOSurfaceCreate((__bridge CFDictionaryRef)@{ (id)kIOSurfaceWidth: @(w), (id)kIOSurfaceHeight: @(h),
        (id)kIOSurfaceBytesPerElement: @(bpe), (id)kIOSurfacePixelFormat: @(fmt) }); }
static IOSurfaceRef mknv12(int w, int h) {
    return IOSurfaceCreate((__bridge CFDictionaryRef)@{ (id)kIOSurfaceWidth: @(w), (id)kIOSurfaceHeight: @(h),
        (id)kIOSurfacePixelFormat: @((uint32_t)'420v'),
        (id)kIOSurfacePlaneInfo: @[ @{ (id)kIOSurfacePlaneWidth: @(w), (id)kIOSurfacePlaneHeight: @(h), (id)kIOSurfacePlaneBytesPerElement: @1 },
                                    @{ (id)kIOSurfacePlaneWidth: @(w / 2), (id)kIOSurfacePlaneHeight: @(h / 2), (id)kIOSurfacePlaneBytesPerElement: @2 } ] }); }
// Pixel value of generation g at (x, y): every pixel differs, so a shifted/partial upload shows up too.
static inline uint8_t pv(int g, int x, int y, int c) { return (uint8_t)(g * 37 + x * 7 + y * 13 + c * 61); }
static void fill(IOSurfaceRef s, int plane, int g) {
    IOSurfaceLock(s, 0, NULL);
    const int w = (int)IOSurfaceGetWidthOfPlane(s, plane), h = (int)IOSurfaceGetHeightOfPlane(s, plane), bpe = (int)IOSurfaceGetBytesPerElementOfPlane(s, plane);
    const size_t row = IOSurfaceGetBytesPerRowOfPlane(s, plane); uint8_t *b = IOSurfaceGetBaseAddressOfPlane(s, plane);
    for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) for (int c = 0; c < bpe; c++) b[y * row + x * bpe + c] = pv(g, x, y, c);
    IOSurfaceUnlock(s, 0, NULL);
}
// Which generation (from..to) a read-back image matches everywhere; -1 = none (stale or torn).
static int which(const uint8_t *p, size_t row, int w, int h, int bpe, int from, int to) {
    for (int g = to; g >= from; g--) {
        int ok = 1;
        for (int y = 0; y < h && ok; y += (y < 2 || y > h - 3) ? 1 : 7) for (int x = 0; x < w && ok; x += (x < 2 || x > w - 3) ? 1 : 5)
            for (int c = 0; c < bpe; c++) if (p[y * row + x * bpe + c] != pv(g, x, y, c)) { ok = 0; break; }
        if (ok) return g;
    }
    return -1;
}
int main(int argc, char **argv) { @autoreleasepool {
    id<MTLDevice> dev = mkdev(argc > 1 ? argv[1] : NULL); id<MTLCommandQueue> q = [dev newCommandQueue];
    printf("device %s\n", dev.name.UTF8String);
    int stale = 0, newer = 0, reads = 0, torn = 0;
    const struct { int w, h; } sz[] = { { 64, 64 }, { 288, 32 }, { 1000, 700 }, { 3584, 256 }, { 1920, 1080 } };
    for (unsigned si = 0; si < sizeof sz / sizeof sz[0]; si++) {
        const int W = sz[si].w, H = sz[si].h, N = 12;
        IOSurfaceRef s = mksurf(W, H, 'BGRA', 4);
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:W height:H mipmapped:NO];
        td.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget; td.storageMode = MTLStorageModeShared;
        id<MTLTexture> keep = [dev newTextureWithDescriptor:td iosurface:s plane:0];
        const size_t row = (size_t)W * 4;
        // A: one texture, write -> read -> wait, again and again (2nd upload on reads the imported pages)
        // C: same, but a fresh texture over the surface each time
        for (int mode = 0; mode < 2; mode++) {
            int bad = 0;
            for (int g = 0; g < N; g++) {
                fill(s, 0, g + mode * 100);
                id<MTLTexture> t = mode ? [dev newTextureWithDescriptor:td iosurface:s plane:0] : keep;
                id<MTLBuffer> out = [dev newBufferWithLength:row * H options:MTLResourceStorageModeShared];
                id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
                [b copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(W, H, 1)
                          toBuffer:out destinationOffset:0 destinationBytesPerRow:row destinationBytesPerImage:row * H];
                [b endEncoding]; [cb commit]; [cb waitUntilCompleted];
                const int got = which(out.contents, row, W, H, 4, g + mode * 100, g + mode * 100); reads++;
                if (got < 0) { bad++; stale++; if (bad < 3) printf("  %dx%d %s gen %d: STALE (first px %02x, want %02x)\n", W, H, mode ? "fresh-texture" : "same-texture", g,
                                                        ((uint8_t *)out.contents)[0], pv(g + mode * 100, 0, 0, 0)); }
            }
            printf("%dx%d %s: %d/%d current\n", W, H, mode ? "fresh texture each time" : "same texture", N - bad, N);
        }
        // B: pipelined - write g, commit a read without waiting, write g+1, ... then check every read
        {
            NSMutableArray *outs = [NSMutableArray array], *cbs = [NSMutableArray array]; int bad = 0, nw = 0;
            for (int g = 0; g < N; g++) {
                fill(s, 0, 200 + g);
                id<MTLBuffer> out = [dev newBufferWithLength:row * H options:MTLResourceStorageModeShared]; [outs addObject:out];
                id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
                [b copyFromTexture:keep sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(W, H, 1)
                          toBuffer:out destinationOffset:0 destinationBytesPerRow:row destinationBytesPerImage:row * H];
                [b endEncoding]; [cb commit]; [cbs addObject:cb];
            }
            for (id<MTLCommandBuffer> cb in cbs) [cb waitUntilCompleted];
            for (int g = 0; g < N; g++) {
                const int got = which([outs[g] contents], row, W, H, 4, 200 + g, 200 + N - 1); reads++;
                if (got < 0) { bad++;
                    const int old = which([outs[g] contents], row, W, H, 4, 0, 200 + g - 1);
                    if (old >= 0) { stale++; printf("  %dx%d pipelined read %d: OLDER generation %d\n", W, H, g, old - 200); }
                    else { torn++; if (getenv("SA_VERBOSE")) printf("  %dx%d pipelined read %d: torn (mix of generations)\n", W, H, g); }
                } else if (got > 200 + g) { nw++; newer++; }
            }
            printf("%dx%d pipelined: %d/%d current or newer (%d newer, %d not a single generation)\n", W, H, N - bad, N, nw, bad);
        }
        CFRelease(s);
    }
    // D: a video frame (NV12, two planes - always a private image), same texture pair, write -> read -> wait
    {
        const int W = 1920, H = 1080, N = 8; int bad = 0;
        IOSurfaceRef s = mknv12(W, H);
        MTLTextureDescriptor *ty = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm width:W height:H mipmapped:NO];
        MTLTextureDescriptor *tc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRG8Unorm width:W / 2 height:H / 2 mipmapped:NO];
        ty.usage = tc.usage = MTLTextureUsageShaderRead;
        id<MTLTexture> y = [dev newTextureWithDescriptor:ty iosurface:s plane:0], c = [dev newTextureWithDescriptor:tc iosurface:s plane:1];
        for (int g = 0; g < N; g++) {
            fill(s, 0, 300 + g); fill(s, 1, 400 + g);
            id<MTLBuffer> oy = [dev newBufferWithLength:(size_t)W * H options:0], oc = [dev newBufferWithLength:(size_t)W * H / 2 options:0];
            id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
            [b copyFromTexture:y sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(W, H, 1)
                      toBuffer:oy destinationOffset:0 destinationBytesPerRow:W destinationBytesPerImage:(size_t)W * H];
            [b copyFromTexture:c sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(W / 2, H / 2, 1)
                      toBuffer:oc destinationOffset:0 destinationBytesPerRow:W destinationBytesPerImage:(size_t)W * H / 2];
            [b endEncoding]; [cb commit]; [cb waitUntilCompleted]; reads += 2;
            if (which(oy.contents, W, W, H, 1, 300 + g, 300 + g) < 0) { bad++; stale++; }
            if (which(oc.contents, W, W / 2, H / 2, 2, 400 + g, 400 + g) < 0) { bad++; stale++; }
        }
        printf("NV12 %dx%d luma+chroma: %d/%d current\n", W, H, 2 * N - bad, 2 * N);
        CFRelease(s);
    }
    printf("reads %d, newer %d, torn %d (pipelined reads that overlapped the next CPU write)\nstale reads: %d\n", reads, newer, torn, stale);
    return 0;
}}
