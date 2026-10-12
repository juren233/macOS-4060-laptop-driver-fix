#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOKit/IOKitLib.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
// Sampler/texture ARRAYS reached through a struct of pointers (what ANGLE emits for `sampler2D u_texture[16]`,
// e.g. xterm.js's WebGL glyph atlas pages). Each page k must pick texture k and sampler k: nearest for even k, linear for odd.
static NSString *src = @
"#include <metal_stdlib>\n"
"using namespace metal;\n"
"struct VOut { float4 pos [[position]]; float2 uv; int page [[flat]]; };\n"
"vertex VOut vs(uint vid [[vertex_id]], constant int &page [[buffer(0)]]) {\n"
"  float2 q[4] = { float2(0,0), float2(1,0), float2(0,1), float2(1,1) };\n"
"  VOut o; o.pos = float4(q[vid]*2.0-1.0, 0, 1); o.uv = q[vid]; o.page = page; return o; }\n"
"template <typename T> struct TEnv { thread T *texture; thread sampler *smp; };\n"
"struct TEnvs { TEnv<texture2d<float>> t[16]; };\n"
"struct FIn { float2 uv; int page; };\n"
"struct FOut { float4 c; };\n"
"static void __attribute__((noinline)) body(thread FOut &o, thread FIn &i, thread TEnvs &e) {\n"
"  o.c = float4(0, 0, 1, 1);\n"
"  if (i.page == 0) o.c = e.t[0].texture->sample(*e.t[0].smp, float2(0.45, 0.5));\n"
"  else if (i.page == 1) o.c = e.t[1].texture->sample(*e.t[1].smp, float2(0.45, 0.5));\n"
"  else if (i.page == 2) o.c = e.t[2].texture->sample(*e.t[2].smp, float2(0.45, 0.5));\n"
"  else if (i.page == 3) o.c = e.t[3].texture->sample(*e.t[3].smp, float2(0.45, 0.5));\n"
"  else if (i.page == 4) o.c = e.t[4].texture->sample(*e.t[4].smp, float2(0.45, 0.5));\n"
"  else if (i.page == 5) o.c = e.t[5].texture->sample(*e.t[5].smp, float2(0.45, 0.5));\n"
"  else if (i.page == 6) o.c = e.t[6].texture->sample(*e.t[6].smp, float2(0.45, 0.5));\n"
"  else if (i.page == 7) o.c = e.t[7].texture->sample(*e.t[7].smp, float2(0.45, 0.5));\n"
"  else if (i.page == 8) o.c = e.t[8].texture->sample(*e.t[8].smp, float2(0.45, 0.5));\n"
"  else if (i.page == 9) o.c = e.t[9].texture->sample(*e.t[9].smp, float2(0.45, 0.5));\n"
"  else if (i.page == 10) o.c = e.t[10].texture->sample(*e.t[10].smp, float2(0.45, 0.5));\n"
"  else if (i.page == 11) o.c = e.t[11].texture->sample(*e.t[11].smp, float2(0.45, 0.5));\n"
"  else if (i.page == 12) o.c = e.t[12].texture->sample(*e.t[12].smp, float2(0.45, 0.5));\n"
"  else if (i.page == 13) o.c = e.t[13].texture->sample(*e.t[13].smp, float2(0.45, 0.5));\n"
"  else if (i.page == 14) o.c = e.t[14].texture->sample(*e.t[14].smp, float2(0.45, 0.5));\n"
"  else if (i.page == 15) o.c = e.t[15].texture->sample(*e.t[15].smp, float2(0.45, 0.5));\n"
"}\n"
"fragment float4 fs(VOut in [[stage_in]], array<texture2d<float>, 16> tex [[texture(0)]], array<sampler, 16> smp [[sampler(0)]]) {\n"
"  FOut o; FIn fi; fi.uv = in.uv; fi.page = in.page; TEnvs e;\n"
"  e.t[0].texture = &tex[0]; e.t[0].smp = &smp[0];\n"
"  e.t[1].texture = &tex[1]; e.t[1].smp = &smp[1];\n"
"  e.t[2].texture = &tex[2]; e.t[2].smp = &smp[2];\n"
"  e.t[3].texture = &tex[3]; e.t[3].smp = &smp[3];\n"
"  e.t[4].texture = &tex[4]; e.t[4].smp = &smp[4];\n"
"  e.t[5].texture = &tex[5]; e.t[5].smp = &smp[5];\n"
"  e.t[6].texture = &tex[6]; e.t[6].smp = &smp[6];\n"
"  e.t[7].texture = &tex[7]; e.t[7].smp = &smp[7];\n"
"  e.t[8].texture = &tex[8]; e.t[8].smp = &smp[8];\n"
"  e.t[9].texture = &tex[9]; e.t[9].smp = &smp[9];\n"
"  e.t[10].texture = &tex[10]; e.t[10].smp = &smp[10];\n"
"  e.t[11].texture = &tex[11]; e.t[11].smp = &smp[11];\n"
"  e.t[12].texture = &tex[12]; e.t[12].smp = &smp[12];\n"
"  e.t[13].texture = &tex[13]; e.t[13].smp = &smp[13];\n"
"  e.t[14].texture = &tex[14]; e.t[14].smp = &smp[14];\n"
"  e.t[15].texture = &tex[15]; e.t[15].smp = &smp[15];\n"
"  body(o, fi, e); return o.c; }\n";
int main(int argc, char **argv) { @autoreleasepool {
    id<MTLDevice> dev;
    if (argc > 1) { if (!dlopen(argv[1], RTLD_NOW)) { printf("dlopen: %s\n", dlerror()); return 2; }
        io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"));
        dev = ((id (*)(id, SEL, mach_port_t))objc_msgSend)([objc_getClass("NVMTLDevice") alloc], sel_registerName("initWithAcceleratorPort:"), svc);
    } else dev = MTLCreateSystemDefaultDevice();
    NSError *e = nil; id<MTLLibrary> lib = [dev newLibraryWithSource:src options:nil error:&e];
    if (!lib) { printf("library FAILED: %s\n", e.localizedDescription.UTF8String); return 1; }
    id<MTLCommandQueue> q = [dev newCommandQueue];
    id<MTLTexture> tex[16]; id<MTLSamplerState> smp[16];
    for (int k = 0; k < 16; k++) {
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:2 height:1 mipmapped:NO];
        td.usage = MTLTextureUsageShaderRead; tex[k] = [dev newTextureWithDescriptor:td];
        uint8_t px[8] = { (uint8_t)(k * 16), 0, 0, 255, (uint8_t)(k * 16 + 10), 0, 0, 255 };
        [tex[k] replaceRegion:MTLRegionMake2D(0,0,2,1) mipmapLevel:0 withBytes:px bytesPerRow:8];
        MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
        sd.minFilter = sd.magFilter = (k & 1) ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
        smp[k] = [dev newSamplerStateWithDescriptor:sd];
    }
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = [lib newFunctionWithName:@"vs"]; d.fragmentFunction = [lib newFunctionWithName:@"fs"];
    d.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:d error:&e];
    if (!ps) { printf("pipeline FAILED: %s\n", e.localizedDescription.UTF8String); return 1; }
    int ok = 0;
    for (int page = 0; page < 16; page++) {
        MTLTextureDescriptor *rd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:16 height:16 mipmapped:NO];
        rd.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead; rd.storageMode = MTLStorageModePrivate;
        id<MTLTexture> rt = [dev newTextureWithDescriptor:rd];
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = rt; rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLBuffer> out = [dev newBufferWithLength:16 * 16 * 4 options:MTLResourceStorageModeShared];
        id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
        [re setRenderPipelineState:ps]; int pg = page; [re setVertexBytes:&pg length:4 atIndex:0];
        for (int k = 0; k < 16; k++) { [re setFragmentTexture:tex[k] atIndex:k]; [re setFragmentSamplerState:smp[k] atIndex:k]; }
        [re drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4]; [re endEncoding];
        id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
        [b copyFromTexture:rt sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(16,16,1) toBuffer:out destinationOffset:0 destinationBytesPerRow:64 destinationBytesPerImage:1024];
        [b endEncoding]; [cb commit]; [cb waitUntilCompleted];
        const uint8_t *c = (const uint8_t *)out.contents + 8*64 + 32;
        int want = page * 16 + ((page & 1) ? 4 : 0), got = c[0];
        int good = abs(got - want) <= 1 && c[2] == 0;
        printf("page %2d: R=%3d (want %3d) B=%u %s\n", page, got, want, c[2], good ? "OK" : "WRONG");
        ok += good;
    }
    printf("%s\n", ok == 16 ? "PASS" : "FAIL"); return ok == 16 ? 0 : 1;
}}
