// gfx: Skia/Dawn-style draw features rendered to tiny targets and checked against the expected pixels.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
static id<MTLDevice> dev; static id<MTLCommandQueue> q; static id<MTLLibrary> lib; static int fails;
static NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
"struct V { float4 p [[position]]; float4 c; };\n"
"struct Q { float4 color; float4 geom; float4 zz; };\n"
// full-target quad as two triangles (strip order 0,1,2,3), colour/z from a constant struct
"vertex V vq(uint i [[vertex_id]], constant Q &u [[buffer(0)]]) { float2 p[4] = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1) };\n"
"  V o; o.p = float4(p[i] * u.geom.xy + u.geom.zw, u.zz.x, 1); o.c = u.color; return o; }\n"
"fragment float4 fc(V in [[stage_in]]) { return in.c; }\n"
// instanced: instance_id picks colour and x offset
"vertex V vi(uint i [[vertex_id]], uint inst [[instance_id]]) { float2 p[4] = { float2(0,-1), float2(0.5,-1), float2(0,1), float2(0.5,1) };\n"
"  V o; o.p = float4(p[i] + float2(-1 + 0.5 * inst, 0), 0, 1); o.c = float4(inst == 0, inst == 1, inst == 2, 1); return o; }\n"
// dual-source blend: colour in 0, coverage in 1
"struct D { float4 c [[color(0), index(0)]]; float4 m [[color(0), index(1)]]; };\n"
"fragment D fd(V in [[stage_in]]) { D o; o.c = float4(1, 0, 0, 1); o.m = float4(0.5, 0.5, 0.5, 0.5); return o; }\n"
// coverage atlas: write a constant to R and rely on additive blend
"fragment float4 fr(V in [[stage_in]]) { return float4(0.25, 0, 0, 0.25); }\n";
static void px(MTLTextureDescriptor *td, id<MTLTexture> t, uint8_t *out, size_t bpp) {
    id<MTLBuffer> b = [dev newBufferWithLength:64 * 64 * bpp options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder];
    [bl copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(64,64,1) toBuffer:b destinationOffset:0 destinationBytesPerRow:64 * bpp destinationBytesPerImage:64 * 64 * bpp];
    [bl endEncoding]; [cb commit]; [cb waitUntilCompleted]; memcpy(out, b.contents, 64 * 64 * bpp);
}
static void check(const char *name, const uint8_t *p, int x, int y, int r, int g, int bl, int tol) {
    const uint8_t *s = p + (y * 64 + x) * 4;
    int ok = abs(s[0] - r) <= tol && abs(s[1] - g) <= tol && abs(s[2] - bl) <= tol;
    if (!ok) { fails++; printf("  FAIL %s @(%d,%d): got %d,%d,%d want %d,%d,%d\n", name, x, y, s[0], s[1], s[2], r, g, bl); }
}
typedef struct { float c[4]; float g[4]; float z[4]; } QU;
static QU QUm(float r, float g, float b, float z, float sx, float sy, float ox, float oy) { QU u = { { r, g, b, 1 }, { sx, sy, ox, oy }, { z, 0, 0, 0 } }; return u; }
static id<MTLTexture> mk(MTLPixelFormat f, MTLTextureUsage u, int samples) {
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:f width:64 height:64 mipmapped:NO];
    td.usage = u; td.storageMode = MTLStorageModePrivate;
    if (samples > 1) { td.textureType = MTLTextureType2DMultisample; td.sampleCount = samples; }
    return [dev newTextureWithDescriptor:td];
}
static void draw(id<MTLRenderCommandEncoder> re, QU u) {
    [re setVertexBytes:&u length:sizeof u atIndex:0]; [re drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
}
// ---- T1: depth test GreaterEqual with two-triangle quads over several depth formats
static void depthTest(MTLPixelFormat df, const char *nm, int stencil) {
    if (df == MTLPixelFormatDepth24Unorm_Stencil8 && ![dev isDepth24Stencil8PixelFormatSupported]) { printf("depth %s: not supported by device\n", nm); return; }
    int f0 = fails;
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = [lib newFunctionWithName:@"vq"]; d.fragmentFunction = [lib newFunctionWithName:@"fc"];
    d.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm; d.depthAttachmentPixelFormat = df;
    if (stencil) d.stencilAttachmentPixelFormat = df;
    NSError *e; id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:d error:&e]; if (!ps) { printf("depth %s: pipeline FAILED %s\n", nm, e.description.UTF8String); fails++; return; }
    MTLDepthStencilDescriptor *dd = [MTLDepthStencilDescriptor new]; dd.depthCompareFunction = MTLCompareFunctionGreaterEqual; dd.depthWriteEnabled = YES;
    id<MTLDepthStencilState> ds = [dev newDepthStencilStateWithDescriptor:dd];
    id<MTLTexture> c = mk(MTLPixelFormatRGBA8Unorm, MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead, 1), z = mk(df, MTLTextureUsageRenderTarget, 1);
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = c; rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
    rp.depthAttachment.texture = z; rp.depthAttachment.loadAction = MTLLoadActionClear; rp.depthAttachment.clearDepth = 0; rp.depthAttachment.storeAction = MTLStoreActionDontCare;
    if (stencil) { rp.stencilAttachment.texture = z; rp.stencilAttachment.loadAction = MTLLoadActionClear; rp.stencilAttachment.storeAction = MTLStoreActionDontCare; }
    id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
    [re setRenderPipelineState:ps]; [re setDepthStencilState:ds];
    draw(re, QUm(1, 0, 0, 0.25, 1, 1, 0, 0));      // red, far
    draw(re, QUm(0, 1, 0, 0.5, 0.5, 0.5, 0, 0));    // green, nearer, centre
    draw(re, QUm(0, 0, 1, 0.1, 1, 1, 0, 0));        // blue, farther than red -> must fail
    draw(re, QUm(1, 1, 0, 0.5, 0.25, 1, 0.75, 0));  // yellow equal-depth to green on the right edge, passes (GreaterEqual) and is not on red? it IS over red
    [re endEncoding]; [cb commit]; [cb waitUntilCompleted];
    uint8_t p[64 * 64 * 4]; px(nil, c, p, 4);
    check(nm, p, 2, 2, 255, 0, 0, 2); check(nm, p, 2, 61, 255, 0, 0, 2); check(nm, p, 61, 2, 255, 255, 0, 2);   // red corners (tri 1 & tri 2)
    check(nm, p, 32, 32, 0, 255, 0, 2); check(nm, p, 20, 44, 0, 255, 0, 2); check(nm, p, 44, 20, 0, 255, 0, 2);
    check(nm, p, 58, 30, 255, 255, 0, 2); check(nm, p, 58, 10, 255, 255, 0, 2); check(nm, p, 58, 55, 255, 255, 0, 2);
    printf("depth %-22s %s\n", nm, fails == f0 ? "OK" : "FAIL");
}
// ---- T2: instancing
static void instTest(void) {
    int f0 = fails;
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = [lib newFunctionWithName:@"vi"]; d.fragmentFunction = [lib newFunctionWithName:@"fc"]; d.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    NSError *e; id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:d error:&e]; if (!ps) { printf("inst: pipeline FAILED %s\n", e.description.UTF8String); fails++; return; }
    id<MTLTexture> c = mk(MTLPixelFormatRGBA8Unorm, MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead, 1);
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = c; rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
    [re setRenderPipelineState:ps];
    [re drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4 instanceCount:3 baseInstance:0];
    [re endEncoding]; [cb commit]; [cb waitUntilCompleted];
    uint8_t p[64 * 64 * 4]; px(nil, c, p, 4);
    check("inst0", p, 8, 32, 255, 0, 0, 2); check("inst1", p, 24, 32, 0, 255, 0, 2); check("inst2", p, 40, 32, 0, 0, 255, 2); check("inst-none", p, 56, 32, 0, 0, 0, 2);
    printf("instancing                  %s\n", fails == f0 ? "OK" : "FAIL");
}
// ---- T3: dual-source blend (Skia coverage / LCD)
static void dualTest(void) {
    int f0 = fails;
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = [lib newFunctionWithName:@"vq"]; d.fragmentFunction = [lib newFunctionWithName:@"fd"];
    MTLRenderPipelineColorAttachmentDescriptor *a = d.colorAttachments[0]; a.pixelFormat = MTLPixelFormatRGBA8Unorm; a.blendingEnabled = YES;
    a.sourceRGBBlendFactor = MTLBlendFactorSource1Color; a.destinationRGBBlendFactor = MTLBlendFactorOneMinusSource1Color; a.rgbBlendOperation = MTLBlendOperationAdd;
    a.sourceAlphaBlendFactor = MTLBlendFactorSource1Alpha; a.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSource1Alpha; a.alphaBlendOperation = MTLBlendOperationAdd;
    NSError *e; id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:d error:&e]; if (!ps) { printf("dual: pipeline FAILED %s\n", e.description.UTF8String); fails++; return; }
    id<MTLTexture> c = mk(MTLPixelFormatRGBA8Unorm, MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead, 1);
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = c; rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 1, 1); rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
    [re setRenderPipelineState:ps]; draw(re, QUm(0, 0, 0, 0, 1, 1, 0, 0)); [re endEncoding]; [cb commit]; [cb waitUntilCompleted];
    uint8_t p[64 * 64 * 4]; px(nil, c, p, 4);
    check("dual", p, 5, 5, 128, 0, 128, 3); check("dual", p, 58, 58, 128, 0, 128, 3);   // 1*0.5 + 0*(1-.5)=.5 red ; blue .5
    printf("dual-source blend           %s\n", fails == f0 ? "OK" : "FAIL");
}
// ---- T4: stencil winding fill (stencil-and-cover): increment-wrap front / decrement-wrap back, then cover where != 0
static void stencilTest(MTLPixelFormat df, const char *nm) {
    if (df == MTLPixelFormatDepth24Unorm_Stencil8 && ![dev isDepth24Stencil8PixelFormatSupported]) return;
    int f0 = fails;
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = [lib newFunctionWithName:@"vq"]; d.fragmentFunction = [lib newFunctionWithName:@"fc"];
    d.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm; d.depthAttachmentPixelFormat = df; d.stencilAttachmentPixelFormat = df;
    NSError *e; id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:d error:&e]; if (!ps) { printf("stencil %s: pipeline FAILED\n", nm); fails++; return; }
    MTLRenderPipelineDescriptor *d2 = [d copy]; d2.colorAttachments[0].writeMask = MTLColorWriteMaskNone;
    id<MTLRenderPipelineState> psNoColor = [dev newRenderPipelineStateWithDescriptor:d2 error:&e];
    MTLDepthStencilDescriptor *w = [MTLDepthStencilDescriptor new];
    w.frontFaceStencil = [MTLStencilDescriptor new]; w.frontFaceStencil.stencilCompareFunction = MTLCompareFunctionAlways; w.frontFaceStencil.depthStencilPassOperation = MTLStencilOperationIncrementWrap;
    w.backFaceStencil = [MTLStencilDescriptor new]; w.backFaceStencil.stencilCompareFunction = MTLCompareFunctionAlways; w.backFaceStencil.depthStencilPassOperation = MTLStencilOperationDecrementWrap;
    id<MTLDepthStencilState> sw = [dev newDepthStencilStateWithDescriptor:w];
    MTLDepthStencilDescriptor *cv = [MTLDepthStencilDescriptor new];
    cv.frontFaceStencil = [MTLStencilDescriptor new]; cv.frontFaceStencil.stencilCompareFunction = MTLCompareFunctionNotEqual; cv.frontFaceStencil.depthStencilPassOperation = MTLStencilOperationZero; cv.frontFaceStencil.stencilFailureOperation = MTLStencilOperationZero;
    cv.backFaceStencil = cv.frontFaceStencil;
    id<MTLDepthStencilState> sc = [dev newDepthStencilStateWithDescriptor:cv];
    id<MTLTexture> c = mk(MTLPixelFormatRGBA8Unorm, MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead, 1), z = mk(df, MTLTextureUsageRenderTarget, 1);
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = c; rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].storeAction = MTLStoreActionStore; rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
    rp.depthAttachment.texture = z; rp.depthAttachment.loadAction = MTLLoadActionClear; rp.depthAttachment.clearDepth = 1; rp.depthAttachment.storeAction = MTLStoreActionDontCare;
    rp.stencilAttachment.texture = z; rp.stencilAttachment.loadAction = MTLLoadActionClear; rp.stencilAttachment.clearStencil = 0; rp.stencilAttachment.storeAction = MTLStoreActionDontCare;
    id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
    // path = left half quad drawn once (winding +1) and its upper-right quarter drawn again (winding +2 there); stencil pass, then cover whole target
    [re setRenderPipelineState:psNoColor]; [re setDepthStencilState:sw];
    draw(re, QUm(0, 0, 0, 0.5, 0.5, 1, -0.5, 0));    // x in [-1,0]
    draw(re, QUm(0, 0, 0, 0.5, 0.25, 0.5, -0.75, 0.5)); // inside, x in [-1,-0.5], y in [0,1]
    [re setRenderPipelineState:ps]; [re setDepthStencilState:sc];
    draw(re, QUm(1, 1, 1, 0.5, 1, 1, 0, 0));
    [re endEncoding]; [cb commit]; [cb waitUntilCompleted];
    uint8_t p[64 * 64 * 4]; px(nil, c, p, 4);
    check(nm, p, 10, 32, 255, 255, 255, 2); check(nm, p, 25, 50, 255, 255, 255, 2); check(nm, p, 25, 10, 255, 255, 255, 2);
    check(nm, p, 40, 32, 0, 0, 0, 2); check(nm, p, 58, 10, 0, 0, 0, 2); check(nm, p, 58, 58, 0, 0, 0, 2);
    printf("stencil fill %-14s %s\n", nm, fails == f0 ? "OK" : "FAIL");
}
// ---- T5: R16Float coverage atlas, additive blend
static void atlasTest(MTLPixelFormat f, const char *nm, int ch) {
    int f0 = fails;
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = [lib newFunctionWithName:@"vq"]; d.fragmentFunction = [lib newFunctionWithName:@"fr"];
    MTLRenderPipelineColorAttachmentDescriptor *a = d.colorAttachments[0]; a.pixelFormat = f; a.blendingEnabled = YES;
    a.sourceRGBBlendFactor = MTLBlendFactorOne; a.destinationRGBBlendFactor = MTLBlendFactorOne; a.rgbBlendOperation = MTLBlendOperationAdd;
    a.sourceAlphaBlendFactor = MTLBlendFactorOne; a.destinationAlphaBlendFactor = MTLBlendFactorOne;
    NSError *e; id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:d error:&e]; if (!ps) { printf("atlas %s: pipeline FAILED %s\n", nm, e.description.UTF8String); fails++; return; }
    id<MTLTexture> c = mk(f, MTLTextureUsageRenderTarget, 1);
    (void)ch; (void)c;
    printf("atlas %-18s pipeline OK (readback skipped)\n", nm); (void)f0;
}
int main(int argc, char **argv) { @autoreleasepool {
    dev = MTLCreateSystemDefaultDevice(); q = [dev newCommandQueue]; NSError *e;
    lib = [dev newLibraryWithSource:src options:nil error:&e]; if (!lib) { printf("library FAILED %s\n", e.description.UTF8String); return 1; }
    printf("device: %s\n", dev.name.UTF8String);
    depthTest(MTLPixelFormatDepth32Float, "Depth32Float", 0);
    depthTest(MTLPixelFormatDepth32Float_Stencil8, "Depth32Float_Stencil8", 1);
    depthTest(MTLPixelFormatDepth24Unorm_Stencil8, "Depth24Unorm_Stencil8", 1);
    depthTest(MTLPixelFormatDepth16Unorm, "Depth16Unorm", 0);
    instTest(); dualTest();
    stencilTest(MTLPixelFormatDepth32Float_Stencil8, "D32S8"); stencilTest(MTLPixelFormatDepth24Unorm_Stencil8, "D24S8");
    printf("%s (%d failed checks)\n", fails ? "FAIL" : "PASS", fails); return fails != 0;
}}
