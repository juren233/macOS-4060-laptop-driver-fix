#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOKit/IOKitLib.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
// ONE-element sampler/texture arrays reached through a struct of pointers and sampled in a non-inlined helper - what ANGLE
// emits for three.js shadow maps (`uniform sampler2D directionalShadowMap[1]` + `getShadow(shadowMap, ...)`). The translator
// bound `array<sampler, 1>` as a plain sampler, the struct store of the parameter became null, and newLibrary failed with
// "sampler operand is a pointer whose exact sampler state was not recovered" (Chrome: WebGL context lost, GPU process restart).
// The draw must use the bound sampler: nearest gives texel 0, linear blends texels 0 and 1.
static NSString *src = @
"#include <metal_stdlib>\n"
"using namespace metal;\n"
"struct VOut { float4 pos [[position]]; };\n"
"vertex VOut vs(uint vid [[vertex_id]]) {\n"
"  float2 q[4] = { float2(0,0), float2(1,0), float2(0,1), float2(1,1) };\n"
"  VOut o; o.pos = float4(q[vid]*2.0-1.0, 0, 1); return o; }\n"
"template <typename T> struct TEnv { thread T *texture; thread sampler *smp; };\n"
"struct TEnvs { TEnv<texture2d<float>> t[1]; };\n"
"static float4 __attribute__((noinline)) shade(TEnv<texture2d<float>> env, float2 uv, float bias) {\n"
"  if (uv.x + bias > 2.0) return float4(0, 0, 1, 1);\n"
"  float4 a = env.texture->sample(*env.smp, uv);\n"
"  float4 b = env.texture->sample(*env.smp, uv + float2(0, 0.001));\n"
"  return (a + b) * 0.5; }\n"
"static void __attribute__((noinline)) body(thread float4 &o, thread TEnvs &e, float bias) {\n"
"  o = shade(e.t[0], float2(0.45, 0.5), bias); }\n"
"fragment float4 fs(VOut in [[stage_in]], constant float &bias [[buffer(0)]],\n"
"                   array<texture2d<float>, 1> tex [[texture(0)]], array<sampler, 1> smp [[sampler(0)]]) {\n"
"  float4 o; TEnvs e; e.t[0].texture = &tex[0]; e.t[0].smp = &smp[0];\n"
"  body(o, e, bias); return o; }\n";
int main(int argc, char **argv) { @autoreleasepool {
    id<MTLDevice> dev;
    if (argc > 1) { if (!dlopen(argv[1], RTLD_NOW)) { printf("dlopen: %s\n", dlerror()); return 2; }
        io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"));
        dev = ((id (*)(id, SEL, mach_port_t))objc_msgSend)([objc_getClass("NVMTLDevice") alloc], sel_registerName("initWithAcceleratorPort:"), svc);
    } else dev = MTLCreateSystemDefaultDevice();
    NSError *e = nil; id<MTLLibrary> lib = [dev newLibraryWithSource:src options:nil error:&e];
    if (!lib) { printf("library FAILED: %s\nFAIL\n", e.localizedDescription.UTF8String); return 1; }
    id<MTLCommandQueue> q = [dev newCommandQueue];
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:2 height:1 mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead; id<MTLTexture> tex = [dev newTextureWithDescriptor:td];
    uint8_t px[8] = { 100, 0, 0, 255, 200, 0, 0, 255 };
    [tex replaceRegion:MTLRegionMake2D(0,0,2,1) mipmapLevel:0 withBytes:px bytesPerRow:8];
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = [lib newFunctionWithName:@"vs"]; d.fragmentFunction = [lib newFunctionWithName:@"fs"];
    d.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:d error:&e];
    if (!ps) { printf("pipeline FAILED: %s\nFAIL\n", e.localizedDescription.UTF8String); return 1; }
    int ok = 0;
    for (int linear = 0; linear < 2; linear++) {
        MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
        sd.minFilter = sd.magFilter = linear ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
        id<MTLSamplerState> smp = [dev newSamplerStateWithDescriptor:sd];
        MTLTextureDescriptor *rd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:16 height:16 mipmapped:NO];
        rd.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead; rd.storageMode = MTLStorageModePrivate;
        id<MTLTexture> rt = [dev newTextureWithDescriptor:rd];
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = rt; rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLBuffer> out = [dev newBufferWithLength:16 * 16 * 4 options:MTLResourceStorageModeShared];
        id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
        float bias = 0; [re setRenderPipelineState:ps]; [re setFragmentBytes:&bias length:4 atIndex:0];
        [re setFragmentTexture:tex atIndex:0]; [re setFragmentSamplerState:smp atIndex:0];
        [re drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4]; [re endEncoding];
        id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
        [b copyFromTexture:rt sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(16,16,1) toBuffer:out destinationOffset:0 destinationBytesPerRow:64 destinationBytesPerImage:1024];
        [b endEncoding]; [cb commit]; [cb waitUntilCompleted];
        const uint8_t *c = (const uint8_t *)out.contents + 8*64 + 32;
        // u = 0.45 on a 2-texel row (centres 0.25, 0.75): nearest -> texel 0 = 100, linear -> 0.6*100 + 0.4*200 = 140
        int want = linear ? 140 : 100, got = c[0];
        int good = abs(got - want) <= 2 && c[2] == 0;
        printf("%s sampler: R=%3d (want %3d) B=%u %s\n", linear ? "linear " : "nearest", got, want, c[2], good ? "OK" : "WRONG");
        ok += good;
    }
    printf("%s\n", ok == 2 ? "PASS" : "FAIL"); return ok == 2 ? 0 : 1;
}}
