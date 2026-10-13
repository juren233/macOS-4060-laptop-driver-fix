// vidup: surface-in of a video (NV12, two planes) IOSurface that the producer rewrites on the CPU every frame - what
// WindowServer sees for a video overlay. Per frame: lock, fill both planes with this frame's pattern, unlock (seed moves);
// then draw both plane textures (created once, like Core Animation keeps them) into a private target and copy the target
// to a buffer; check sampled pixels against the frame's pattern (a stale or half-copied plane fails).
// Reports CPU per frame (this process, user+sys) and wall per frame.
// usage: vidup [plugin] [frames] [W H]   -> PASS / FAIL
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <CoreVideo/CoreVideo.h>
#import <IOSurface/IOSurface.h>
#import <IOKit/IOKitLib.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <sys/resource.h>
static const char *src =
    "#include <metal_stdlib>\nusing namespace metal;\n"
    "struct V { float4 p [[position]]; };\n"
    "vertex V vs(uint i [[vertex_id]]) { float2 c[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) }; V o; o.p = float4(c[i], 0, 1); return o; }\n"
    // target pixel (x, y) = (Y at (x*sx, y*sy), Cb, Cr at the chroma texel of that luma texel, 1)
    "fragment float4 fs(V v [[stage_in]], texture2d<float> y [[texture(0)]], texture2d<float> c [[texture(1)]], constant float2 &s [[buffer(0)]]) {\n"
    "  uint2 p = uint2(v.p.xy * s); float l = y.read(p).r; float2 ch = c.read(p / 2).rg; return float4(l, ch.x, ch.y, 1); }\n";
static uint8_t ypat(int k, int x, int y) { return (uint8_t)(k * 7 + y * 3 + (x >> 4)); }
static uint8_t cbpat(int k, int x, int y) { return (uint8_t)(k * 13 + x + (y >> 3)); }
static uint8_t crpat(int k, int x, int y) { return (uint8_t)(255 - k * 5 - y); }
static double cpu_s(void) { struct rusage u; getrusage(RUSAGE_SELF, &u); return u.ru_utime.tv_sec + u.ru_stime.tv_sec + (u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6; }
int main(int argc, char **argv) { @autoreleasepool {
    int ai = 1; id<MTLDevice> dev;
    if (argc > 1 && strchr(argv[1], '/')) { if (!dlopen(argv[1], RTLD_NOW)) { printf("dlopen: %s\n", dlerror()); return 2; }
        io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"));
        dev = ((id (*)(id, SEL, mach_port_t))objc_msgSend)([objc_getClass("NVMTLDevice") alloc], sel_registerName("initWithAcceleratorPort:"), svc); ai = 2;
    } else dev = MTLCreateSystemDefaultDevice();
    const int N = argc > ai ? atoi(argv[ai]) : 300, W = argc > ai + 1 ? atoi(argv[ai + 1]) : 3840, H = argc > ai + 2 ? atoi(argv[ai + 2]) : 2160;
    CVPixelBufferRef pb = NULL;
    if (CVPixelBufferCreate(NULL, W, H, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            (__bridge CFDictionaryRef)@{ (id)kCVPixelBufferIOSurfacePropertiesKey: @{} }, &pb) || !pb) { printf("CVPixelBufferCreate failed\nFAIL\n"); return 1; }
    IOSurfaceRef s = CVPixelBufferGetIOSurface(pb);
    if (!s || IOSurfaceGetPlaneCount(s) != 2) { printf("no 2-plane IOSurface\nFAIL\n"); return 1; }
    id<MTLCommandQueue> q = [dev newCommandQueue]; NSError *e = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:@(src) options:nil error:&e]; if (!lib) { printf("lib: %s\nFAIL\n", e.description.UTF8String); return 1; }
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new]; pd.vertexFunction = [lib newFunctionWithName:@"vs"];
    pd.fragmentFunction = [lib newFunctionWithName:@"fs"]; pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    id<MTLRenderPipelineState> pso = [dev newRenderPipelineStateWithDescriptor:pd error:&e]; if (!pso) { printf("pso: %s\nFAIL\n", e.description.UTF8String); return 1; }
    MTLTextureDescriptor *ty = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm width:W height:H mipmapped:NO]; ty.usage = MTLTextureUsageShaderRead;
    MTLTextureDescriptor *tc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRG8Unorm width:W / 2 height:H / 2 mipmapped:NO]; tc.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> yt = [dev newTextureWithDescriptor:ty iosurface:s plane:0], ct = [dev newTextureWithDescriptor:tc iosurface:s plane:1];
    const int TW = 480, TH = 270;   // the target samples a grid of the planes (every 8th luma texel)
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:TW height:TH mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget; td.storageMode = MTLStorageModePrivate;
    id<MTLTexture> tgt = [dev newTextureWithDescriptor:td];
    id<MTLBuffer> out = [dev newBufferWithLength:TW * TH * 4 options:MTLResourceStorageModeShared];
    const float sc[2] = { (float)W / TW, (float)H / TH };
    int bad = 0; double cpu0 = 0, t0 = 0, fillCpu = 0;
    for (int k = 0; k < N; k++) { @autoreleasepool {
        if (k == 2) { cpu0 = cpu_s(); t0 = CFAbsoluteTimeGetCurrent(); fillCpu = 0; }   // first two frames: staged uploads + imports
        const double f0 = cpu_s();
        IOSurfaceLock(s, 0, NULL);
        uint8_t *yp = IOSurfaceGetBaseAddressOfPlane(s, 0), *cp = IOSurfaceGetBaseAddressOfPlane(s, 1);
        const size_t yr = IOSurfaceGetBytesPerRowOfPlane(s, 0), cr = IOSurfaceGetBytesPerRowOfPlane(s, 1);
        for (int y = 0; y < H; y++) { uint8_t *r = yp + (size_t)y * yr; for (int x = 0; x < W; x++) r[x] = ypat(k, x, y); }
        for (int y = 0; y < H / 2; y++) { uint8_t *r = cp + (size_t)y * cr; for (int x = 0; x < W / 2; x++) { r[2 * x] = cbpat(k, x, y); r[2 * x + 1] = crpat(k, x, y); } }
        IOSurfaceUnlock(s, 0, NULL);
        fillCpu += cpu_s() - f0;
        id<MTLCommandBuffer> cb = [q commandBuffer];
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = tgt; rp.colorAttachments[0].loadAction = MTLLoadActionDontCare; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> en = [cb renderCommandEncoderWithDescriptor:rp];
        [en setRenderPipelineState:pso]; [en setFragmentTexture:yt atIndex:0]; [en setFragmentTexture:ct atIndex:1]; [en setFragmentBytes:sc length:8 atIndex:0];
        [en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [en endEncoding];
        id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder];
        [bl copyFromTexture:tgt sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(TW, TH, 1)
                   toBuffer:out destinationOffset:0 destinationBytesPerRow:TW * 4 destinationBytesPerImage:TW * TH * 4]; [bl endEncoding];
        [cb commit]; [cb waitUntilCompleted];
        if (cb.status != MTLCommandBufferStatusCompleted) { printf("frame %d: status %ld\n", k, (long)cb.status); bad++; continue; }
        const uint8_t *o = out.contents; int fb = 0;
        for (int ty2 = 0; ty2 < TH; ty2 += 7) for (int tx = 0; tx < TW; tx += 11) {
            const int x = (int)((tx + 0.5f) * sc[0]), y = (int)((ty2 + 0.5f) * sc[1]);
            const uint8_t *g = o + ((size_t)ty2 * TW + tx) * 4;
            const uint8_t w[3] = { ypat(k, x, y), cbpat(k, x / 2, y / 2), crpat(k, x / 2, y / 2) };
            for (int c = 0; c < 3; c++) if (abs(g[c] - w[c]) > 1) { if (bad + fb < 10) printf("frame %d texel (%d,%d) ch %d: got %u want %u\n", k, x, y, c, g[c], w[c]); fb++; break; }
        }
        if (fb) bad++;
    } }
    const int M = N > 2 ? N - 2 : 1; const double cpu = cpu_s() - cpu0, wall = CFAbsoluteTimeGetCurrent() - t0;
    printf("%d frames %dx%d NV12: CPU %.2f ms/frame (of which the CPU fill %.2f), wall %.2f ms/frame\n%s\n", N, W, H,
           (cpu - fillCpu) * 1000 / M + fillCpu * 1000 / M, fillCpu * 1000 / M, wall * 1000 / M, bad ? "FAIL" : "PASS");
    CVPixelBufferRelease(pb);
    return bad ? 1 : 0;
} }
