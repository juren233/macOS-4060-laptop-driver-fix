// gfx7: NV12 video frames written by the CPU into recycled IOSurfaces (as a decoder does), sampled as two plane textures
// (R8 luma + RG8 chroma), several frames in flight. The sampled chroma must match what the CPU wrote (a green frame = chroma 0).
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurface.h>
#import <CoreVideo/CoreVideo.h>
#import <IOKit/IOKitLib.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
static NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
"struct V { float4 p [[position]]; };\n"
"vertex V vq(uint i [[vertex_id]]) { float2 p[4] = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1) }; V o; o.p = float4(p[i], 0, 1); return o; }\n"
"fragment float4 fs(V in [[stage_in]], texture2d<float> ty [[texture(0)]], texture2d<float> tc [[texture(1)]]) { constexpr sampler s(filter::nearest, coord::pixel);\n"
"  float2 uv = in.p.xy; return float4(ty.sample(s, uv).r, tc.sample(s, uv * 0.5).r, tc.sample(s, uv * 0.5).g, 1); }\n";
int main(int argc, char **argv) { @autoreleasepool {
    int W = 640, H = 360, NB = 4, FR = 120, inflight = argc > 1 ? atoi(argv[1]) : 3;
    id<MTLDevice> dev;
    if (argc > 2) { if (!dlopen(argv[2], RTLD_NOW)) { printf("dlopen: %s\n", dlerror()); return 2; }
        io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"));
        dev = ((id (*)(id, SEL, mach_port_t))objc_msgSend)([objc_getClass("NVMTLDevice") alloc], sel_registerName("initWithAcceleratorPort:"), svc);
    } else dev = MTLCreateSystemDefaultDevice();
    id<MTLCommandQueue> q = [dev newCommandQueue]; NSError *e; id<MTLLibrary> lib = [dev newLibraryWithSource:src options:nil error:&e];
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new]; d.vertexFunction = [lib newFunctionWithName:@"vq"]; d.fragmentFunction = [lib newFunctionWithName:@"fs"]; d.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:d error:&e]; if (!ps) { printf("pipeline FAILED\n"); return 1; }
    CVPixelBufferRef pb[4]; IOSurfaceRef sf[4];
    for (int i = 0; i < NB; i++) { CVPixelBufferCreate(NULL, W, H, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, (__bridge CFDictionaryRef)@{ (id)kCVPixelBufferIOSurfacePropertiesKey: @{}, (id)kCVPixelBufferMetalCompatibilityKey: @YES }, &pb[i]); sf[i] = CVPixelBufferGetIOSurface(pb[i]); }
    NSMutableArray *outs = [NSMutableArray array], *want = [NSMutableArray array]; int bad = 0, checked = 0, zeroc = 0; id<MTLCommandBuffer> pend[16]; int np = 0;
    for (int f = 0; f < FR; f++) {
        int b = f % NB; uint8_t yv = 40 + (f * 7) % 180, uv = 60 + (f * 5) % 150, vv = 200 - (f * 3) % 120;
        IOSurfaceLock(sf[b], 0, NULL);   // the decoder: luma plane, then chroma plane, one lock cycle
        uint8_t *yp = IOSurfaceGetBaseAddressOfPlane(sf[b], 0); size_t yr = IOSurfaceGetBytesPerRowOfPlane(sf[b], 0); for (int y = 0; y < H; y++) memset(yp + (size_t)y * yr, yv, W);
        uint8_t *cp = IOSurfaceGetBaseAddressOfPlane(sf[b], 1); size_t cr = IOSurfaceGetBytesPerRowOfPlane(sf[b], 1); for (int y = 0; y < H / 2; y++) { uint8_t *r = cp + (size_t)y * cr; for (int x = 0; x < W / 2; x++) { r[2 * x] = uv; r[2 * x + 1] = vv; } }
        IOSurfaceUnlock(sf[b], 0, NULL);
        MTLTextureDescriptor *t0 = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm width:W height:H mipmapped:NO]; t0.usage = MTLTextureUsageShaderRead; t0.storageMode = MTLStorageModeManaged;
        MTLTextureDescriptor *t1 = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRG8Unorm width:W / 2 height:H / 2 mipmapped:NO]; t1.usage = MTLTextureUsageShaderRead; t1.storageMode = MTLStorageModeManaged;
        id<MTLTexture> ty = [dev newTextureWithDescriptor:t0 iosurface:sf[b] plane:0], tc = [dev newTextureWithDescriptor:t1 iosurface:sf[b] plane:1];
        MTLTextureDescriptor *od = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:32 height:32 mipmapped:NO]; od.usage = MTLTextureUsageRenderTarget; od.storageMode = MTLStorageModeShared;
        id<MTLTexture> out = [dev newTextureWithDescriptor:od]; [outs addObject:out]; [want addObject:@[@(yv), @(uv), @(vv)]];
        id<MTLCommandBuffer> cb = [q commandBuffer]; MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = out; rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp]; [re setRenderPipelineState:ps]; [re setFragmentTexture:ty atIndex:0]; [re setFragmentTexture:tc atIndex:1];
        [re drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4]; [re endEncoding]; [cb commit]; pend[np++] = cb;
        if (np >= inflight || f == FR - 1) { for (int i = 0; i < np; i++) [pend[i] waitUntilCompleted]; np = 0; }
    }
    for (int f = 0; f < FR; f++) { uint8_t px[4]; [outs[f] getBytes:px bytesPerRow:128 fromRegion:MTLRegionMake2D(16,16,1,1) mipmapLevel:0]; NSArray *w = want[f]; checked++;
        int ok = abs(px[0] - [w[0] intValue]) <= 2 && abs(px[1] - [w[1] intValue]) <= 2 && abs(px[2] - [w[2] intValue]) <= 2; if (!ok) { bad++; if (px[1] == 0 && px[2] == 0) zeroc++; if (bad <= 4) printf("   frame %d: got Y%d U%d V%d want Y%d U%d V%d\n", f, px[0], px[1], px[2], [w[0] intValue], [w[1] intValue], [w[2] intValue]); } }
    printf("NV12 %dx%d, %d frames, %d in flight: %d/%d frames wrong (%d with chroma 0)  %s\n", W, H, FR, inflight, bad, checked, zeroc, bad ? "FAIL" : "PASS"); return bad != 0;
}}
