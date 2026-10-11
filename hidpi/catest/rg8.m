// rg8: two-channel / one-channel textures filled by replaceRegion and by a buffer->texture blit, then sampled.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOKit/IOKitLib.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
static NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
"struct V { float4 p [[position]]; float2 uv; };\n"
"vertex V vq(uint i [[vertex_id]]) { float2 p[4] = { float2(0,0), float2(1,0), float2(0,1), float2(1,1) }; V o; o.p = float4(p[i]*2-1,0,1); o.uv = float2(p[i].x, 1-p[i].y); return o; }\n"
"fragment float4 fs(V in [[stage_in]], texture2d<float> t [[texture(0)]]) { constexpr sampler s(filter::nearest); return t.sample(s, in.uv); }\n";
int main(int argc, char **argv) { @autoreleasepool {
    id<MTLDevice> dev;
    if (argc > 1) { if (!dlopen(argv[1], RTLD_NOW)) { printf("dlopen: %s\n", dlerror()); return 2; }
        io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"));
        dev = ((id (*)(id, SEL, mach_port_t))objc_msgSend)([objc_getClass("NVMTLDevice") alloc], sel_registerName("initWithAcceleratorPort:"), svc);
    } else dev = MTLCreateSystemDefaultDevice();
    id<MTLCommandQueue> q = [dev newCommandQueue]; NSError *e; id<MTLLibrary> lib = [dev newLibraryWithSource:src options:nil error:&e];
    struct { const char *n; MTLPixelFormat f; int bpp; } fm[] = { {"R8", MTLPixelFormatR8Unorm, 1}, {"RG8", MTLPixelFormatRG8Unorm, 2}, {"RGBA8", MTLPixelFormatRGBA8Unorm, 4} };
    int bad = 0;
    for (int fi = 0; fi < 3; fi++) for (int mode = 0; mode < 3; mode++) for (int sm = 0; sm < 2; sm++) {
        int W = 320, H = 180, bpp = fm[fi].bpp; size_t bpr = (size_t)W * bpp;
        uint8_t *data = malloc(bpr * H); for (size_t i = 0; i < bpr * H; i++) data[i] = 0x40 + (i % bpp) * 0x40;   // channel k = 0x40 + 0x40*k
        MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:fm[fi].f width:W height:H mipmapped:NO];
        d.usage = MTLTextureUsageShaderRead; d.storageMode = sm ? MTLStorageModeManaged : MTLStorageModePrivate;
        if (mode == 0 && !sm) d.storageMode = MTLStorageModeManaged;
        id<MTLTexture> t = [dev newTextureWithDescriptor:d];
        MTLTextureDescriptor *od = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:W height:H mipmapped:NO]; od.usage = MTLTextureUsageRenderTarget; od.storageMode = MTLStorageModePrivate;
        id<MTLTexture> out = [dev newTextureWithDescriptor:od]; id<MTLCommandBuffer> cb = [q commandBuffer];
        if (mode == 0) [t replaceRegion:MTLRegionMake2D(0,0,W,H) mipmapLevel:0 withBytes:data bytesPerRow:bpr];
        else { id<MTLBuffer> b = mode == 1 ? [dev newBufferWithBytes:data length:bpr*H options:MTLResourceStorageModeShared] : [dev newBufferWithBytes:data length:bpr*H options:MTLResourceStorageModeManaged];
            if (mode == 2) [b didModifyRange:NSMakeRange(0, bpr*H)];
            id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder]; [bl copyFromBuffer:b sourceOffset:0 sourceBytesPerRow:bpr sourceBytesPerImage:bpr*H sourceSize:MTLSizeMake(W,H,1) toTexture:t destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)]; [bl endEncoding]; }
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new]; pd.vertexFunction = [lib newFunctionWithName:@"vq"]; pd.fragmentFunction = [lib newFunctionWithName:@"fs"]; pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
        id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:pd error:&e];
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor]; rp.colorAttachments[0].texture = out; rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp]; [re setRenderPipelineState:ps]; [re setFragmentTexture:t atIndex:0]; [re drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4]; [re endEncoding];
        id<MTLBuffer> rb = [dev newBufferWithLength:W*H*4 options:MTLResourceStorageModeShared];
        id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder]; [bl copyFromTexture:out sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(W,H,1) toBuffer:rb destinationOffset:0 destinationBytesPerRow:W*4 destinationBytesPerImage:W*H*4]; [bl endEncoding];
        [cb commit]; [cb waitUntilCompleted];
        const uint8_t *px = rb.contents + ((size_t)(H/2) * W + W/2) * 4; int ok = 1;
        for (int k = 0; k < bpp && k < 4; k++) if (abs(px[k] - (0x40 + 0x40 * k)) > 2) ok = 0;
        if (!ok) { bad++; printf("%s mode=%s storage=%s: sampled %02x %02x %02x %02x (want 40 80 c0 00/ff)\n", fm[fi].n, mode==0?"replaceRegion":mode==1?"blit-shared":"blit-managed", sm?"managed":"private", px[0],px[1],px[2],px[3]); }
        free(data);
    }
    printf("%s (%d bad)\n", bad ? "FAIL" : "PASS", bad); return bad;
}}
