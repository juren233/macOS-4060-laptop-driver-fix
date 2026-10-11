// Fragment shader calling get_num_samples() (what ANGLE emits for WebGL sample masks), compiled from MSL source,
// rendered at 1x and 4x MSAA; the colour carries the sample count. Expect R = 1 and 4.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOKit/IOKitLib.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
static NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
 "struct V { float4 p [[position]]; };\n"
 "vertex V vs(uint i [[vertex_id]]) { float2 q[3] = { float2(-1,-1), float2(3,-1), float2(-1,3) }; V o; o.p = float4(q[i], 0, 1); return o; }\n"
 "fragment float4 fs(V in [[stage_in]]) { return float4(float(get_num_samples()) / 255.0, 0.5, 0, 1); }\n";
int main(int argc, char **argv) { @autoreleasepool {
    id<MTLDevice> dev;
    if (argc > 1) { if (!dlopen(argv[1], RTLD_NOW)) { printf("dlopen: %s\n", dlerror()); return 2; }
        io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"));
        dev = ((id (*)(id, SEL, mach_port_t))objc_msgSend)([objc_getClass("NVMTLDevice") alloc], sel_registerName("initWithAcceleratorPort:"), svc);
    } else dev = MTLCreateSystemDefaultDevice();
    NSError *e = nil; id<MTLLibrary> lib = [dev newLibraryWithSource:src options:nil error:&e];
    if (!lib) { printf("library FAILED: %s\n", e.localizedDescription.UTF8String); return 1; }
    id<MTLCommandQueue> q = [dev newCommandQueue]; int ok = 0;
    for (int n = 1; n <= 4; n *= 4) {
        MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
        d.vertexFunction = [lib newFunctionWithName:@"vs"]; d.fragmentFunction = [lib newFunctionWithName:@"fs"];
        d.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm; d.rasterSampleCount = n;
        id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:d error:&e];
        if (!ps) { printf("%dx pipeline FAILED: %s\n", n, e.localizedDescription.UTF8String); continue; }
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:16 height:16 mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead; td.storageMode = MTLStorageModePrivate;
        id<MTLTexture> res = [dev newTextureWithDescriptor:td], ms = nil;
        if (n > 1) { td.textureType = MTLTextureType2DMultisample; td.sampleCount = n; ms = [dev newTextureWithDescriptor:td]; }
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = ms ?: res; rp.colorAttachments[0].resolveTexture = ms ? res : nil;
        rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].storeAction = ms ? MTLStoreActionMultisampleResolve : MTLStoreActionStore;
        id<MTLBuffer> out = [dev newBufferWithLength:16 * 16 * 4 options:MTLResourceStorageModeShared];
        id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
        [re setRenderPipelineState:ps]; [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [re endEncoding];
        id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
        [b copyFromTexture:res sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(16,16,1) toBuffer:out destinationOffset:0 destinationBytesPerRow:64 destinationBytesPerImage:1024];
        [b endEncoding]; [cb commit]; [cb waitUntilCompleted];
        const uint8_t *p = out.contents; printf("%dx MSAA: get_num_samples() = %u (G=%u) %s\n", n, p[8*64+32], p[8*64+33], p[8*64+32] == n ? "OK" : "WRONG");
        ok += p[8*64+32] == n;
    }
    printf("%s\n", ok == 2 ? "PASS" : "FAIL"); return ok == 2 ? 0 : 1;
}}
