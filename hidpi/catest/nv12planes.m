// nv12planes: an NV12 IOSurface whose luma plane is written by the GPU (render pass) while its chroma plane was filled by the
// CPU. Sampling the chroma plane afterwards must give the CPU's bytes (a video decoder / compositor does exactly this).
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurface.h>
#import <IOKit/IOKitLib.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
static NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
"struct V { float4 p [[position]]; float2 uv; };\n"
"vertex V vq(uint i [[vertex_id]]) { float2 p[4] = { float2(0,0), float2(1,0), float2(0,1), float2(1,1) }; V o; o.p = float4(p[i]*2-1,0,1); o.uv = float2(p[i].x, 1-p[i].y); return o; }\n"
"fragment float4 fy(V in [[stage_in]]) { return float4(0.5, 0, 0, 1); }\n"
"fragment float4 fs(V in [[stage_in]], texture2d<float> ty [[texture(0)]], texture2d<float> tc [[texture(1)]]) { constexpr sampler s(filter::nearest); float2 c = tc.sample(s, in.uv).rg; return float4(c.x, c.y, ty.sample(s, in.uv).r, 1); }\n";
int main(int argc, char **argv) { @autoreleasepool {
    id<MTLDevice> dev;
    if (argc > 1) { if (!dlopen(argv[1], RTLD_NOW)) { printf("dlopen: %s\n", dlerror()); return 2; }
        io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"));
        dev = ((id (*)(id, SEL, mach_port_t))objc_msgSend)([objc_getClass("NVMTLDevice") alloc], sel_registerName("initWithAcceleratorPort:"), svc);
    } else dev = MTLCreateSystemDefaultDevice();
    id<MTLCommandQueue> q = [dev newCommandQueue]; NSError *e; id<MTLLibrary> lib = [dev newLibraryWithSource:src options:nil error:&e]; if (!lib) { printf("lib FAILED\n"); return 1; }
    int W = 640, H = 360, bad = 0, iters = 12;
    for (int it = 0; it < iters; it++) {
        IOSurfaceRef surf = IOSurfaceCreate((__bridge CFDictionaryRef)@{ (id)kIOSurfaceWidth: @(W), (id)kIOSurfaceHeight: @(H), (id)kIOSurfacePixelFormat: @(0x34323076u /*420v*/),
            (id)kIOSurfacePlaneInfo: @[ @{ (id)kIOSurfacePlaneWidth: @(W), (id)kIOSurfacePlaneHeight: @(H), (id)kIOSurfacePlaneBytesPerRow: @(W), (id)kIOSurfacePlaneBytesPerElement: @1 },
                                        @{ (id)kIOSurfacePlaneWidth: @(W/2), (id)kIOSurfacePlaneHeight: @(H/2), (id)kIOSurfacePlaneBytesPerRow: @(W), (id)kIOSurfacePlaneBytesPerElement: @2 } ] });
        if (!surf) { printf("surface FAILED\n"); return 1; }
        IOSurfaceLock(surf, 0, NULL);
        memset(IOSurfaceGetBaseAddressOfPlane(surf, 0), 0x80, (size_t)W * H);
        uint8_t *c = IOSurfaceGetBaseAddressOfPlane(surf, 1); for (int i = 0; i < W * H / 2; i += 2) { c[i] = 0x40; c[i+1] = 0xC0; }
        IOSurfaceUnlock(surf, 0, NULL);
        MTLTextureDescriptor *d0 = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm width:W height:H mipmapped:NO];
        d0.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead; d0.storageMode = MTLStorageModeManaged;
        MTLTextureDescriptor *d1 = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRG8Unorm width:W/2 height:H/2 mipmapped:NO];
        d1.usage = MTLTextureUsageShaderRead; d1.storageMode = MTLStorageModeManaged;
        id<MTLTexture> t0 = [dev newTextureWithDescriptor:d0 iosurface:surf plane:0], t1 = [dev newTextureWithDescriptor:d1 iosurface:surf plane:1];
        MTLTextureDescriptor *od = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:W height:H mipmapped:NO];
        od.usage = MTLTextureUsageRenderTarget; od.storageMode = MTLStorageModePrivate; id<MTLTexture> out = [dev newTextureWithDescriptor:od];
        MTLRenderPipelineDescriptor *p0 = [MTLRenderPipelineDescriptor new]; p0.vertexFunction = [lib newFunctionWithName:@"vq"]; p0.fragmentFunction = [lib newFunctionWithName:@"fy"]; p0.colorAttachments[0].pixelFormat = MTLPixelFormatR8Unorm;
        MTLRenderPipelineDescriptor *p1 = [MTLRenderPipelineDescriptor new]; p1.vertexFunction = [lib newFunctionWithName:@"vq"]; p1.fragmentFunction = [lib newFunctionWithName:@"fs"]; p1.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        id<MTLRenderPipelineState> s0 = [dev newRenderPipelineStateWithDescriptor:p0 error:&e], s1 = [dev newRenderPipelineStateWithDescriptor:p1 error:&e];
        // 1) GPU writes the luma plane (queued, not waited for)
        id<MTLCommandBuffer> cb = [q commandBuffer]; MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = t0; rp.colorAttachments[0].loadAction = MTLLoadActionDontCare; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp]; [re setRenderPipelineState:s0]; [re drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4]; [re endEncoding]; [cb commit];
        // 2) sample both planes into a BGRA target
        cb = [q commandBuffer]; rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = out; rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        re = [cb renderCommandEncoderWithDescriptor:rp]; [re setRenderPipelineState:s1]; [re setFragmentTexture:t0 atIndex:0]; [re setFragmentTexture:t1 atIndex:1]; [re drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4]; [re endEncoding];
        id<MTLBuffer> rb = [dev newBufferWithLength:(size_t)W * H * 4 options:MTLResourceStorageModeShared];
        id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder]; [bl copyFromTexture:out sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(W,H,1) toBuffer:rb destinationOffset:0 destinationBytesPerRow:(size_t)W*4 destinationBytesPerImage:(size_t)W*H*4]; [bl endEncoding];
        [cb commit]; [cb waitUntilCompleted];
        const uint8_t *px = rb.contents; size_t o = ((size_t)(H/2) * W + W/2) * 4;   // BGRA: b=luma, g=Cr(.y), r=Cb(.x)
        int cb_ = px[o+2], cr = px[o+1]; int ok = (abs(cb_ - 0x40) <= 2 && abs(cr - 0xC0) <= 2);
        if (!ok) { bad++; printf("iter %d: chroma sampled as Cb=%d Cr=%d (want 64/192)\n", it, cb_, cr); }
        CFRelease(surf);
    }
    printf("%s (%d/%d bad)\n", bad ? "FAIL" : "PASS", bad, iters); return bad;
}}
