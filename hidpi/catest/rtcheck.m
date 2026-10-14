#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <CommonCrypto/CommonDigest.h>
// Render-target content checks (compare across plugin builds): MSAA colour + depth (D32F and D32S8) with overlapping depths,
// resolve, Load across passes, a depth-only shadow map sampled with sample_compare, depth copied to a buffer, stencil test.
static NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
"struct V { float4 pos [[position]]; float4 col; };\n"
"struct P { float4 xyzw; float4 col; };\n"
"vertex V vs(uint vid [[vertex_id]], constant P *p [[buffer(0)]]) { V o; o.pos = p[vid].xyzw; o.col = p[vid].col; return o; }\n"
"fragment float4 fs(V in [[stage_in]]) { return in.col; }\n"
"struct VQ { float4 pos [[position]]; float2 uv; };\n"
"vertex VQ vq(uint vid [[vertex_id]]) { float2 q[3] = { float2(-1,-1), float2(3,-1), float2(-1,3) }; VQ o; o.pos = float4(q[vid],0,1); o.uv = q[vid]*float2(0.5,-0.5)+0.5; return o; }\n"
"fragment float4 shadow(VQ in [[stage_in]], depth2d<float> d [[texture(0)]], sampler s [[sampler(0)]]) {\n"
"  float a = d.sample_compare(s, in.uv, 0.45); float b = d.sample_compare(s, in.uv, 0.7); float c = d.sample(s, in.uv);\n"
"  return float4(a, b, c, 1); }\n";
typedef struct { float xyzw[4]; float col[4]; } P;
static void sha(const char *name, const void *p, size_t n) { unsigned char h[32]; CC_SHA256(p, (CC_LONG)n, h); printf("%-34s", name); for (int i = 0; i < 6; i++) printf("%02x", h[i]); printf("\n"); }
int main(int argc, char **argv) { @autoreleasepool {
  id<MTLDevice> dev = MTLCreateSystemDefaultDevice(); NSError *e = nil;
  id<MTLLibrary> lib = [dev newLibraryWithSource:src options:nil error:&e]; if (!lib) { printf("lib %s\n", e.localizedDescription.UTF8String); return 1; }
  id<MTLCommandQueue> q = [dev newCommandQueue];
  const int W = 1301, H = 733;   // odd size: partial tiles / compression blocks at the edges
  // triangles: big back one, crossing ones (intersecting depths), a small near one
  P tri[] = {
    {{-1,-1,0.8,1},{0.9,0.1,0.1,1}}, {{3,-1,0.8,1},{0.9,0.1,0.1,1}}, {{-1,3,0.8,1},{0.9,0.1,0.1,1}},
    {{-0.9,-0.8,0.2,1},{0.1,0.8,0.2,1}}, {{0.9,-0.6,0.9,1},{0.1,0.8,0.2,1}}, {{0.1,0.9,0.5,1},{0.1,0.8,0.2,1}},
    {{-0.8,0.7,0.9,1},{0.2,0.3,0.9,1}}, {{0.8,0.8,0.1,1},{0.2,0.3,0.9,1}}, {{0.0,-0.9,0.5,1},{0.2,0.3,0.9,1}},
    {{-0.2,-0.2,0.05,1},{1,1,0,1}}, {{0.25,-0.15,0.05,1},{1,1,0,1}}, {{0.0,0.3,0.05,1},{1,1,0,1}} };
  MTLPixelFormat fmts[4] = { MTLPixelFormatDepth32Float, MTLPixelFormatDepth32Float_Stencil8, MTLPixelFormatDepth24Unorm_Stencil8, MTLPixelFormatDepth16Unorm };
  const char *fn[4] = { "D32F", "D32S8", "D24S8", "D16" };
  for (int pass = 0; pass < 2; pass++) for (int fi = 0; fi < 4; fi++) {
    MTLPixelFormat df = fmts[fi]; int dsfmt = fi == 1 || fi == 2;
    MTLTextureDescriptor *cd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:W height:H mipmapped:NO];
    cd.textureType = MTLTextureType2DMultisample; cd.sampleCount = 4; cd.usage = MTLTextureUsageRenderTarget; cd.storageMode = MTLStorageModePrivate;
    id<MTLTexture> msc = [dev newTextureWithDescriptor:cd];
    MTLTextureDescriptor *dd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:df width:W height:H mipmapped:NO];
    dd.textureType = MTLTextureType2DMultisample; dd.sampleCount = 4; dd.usage = MTLTextureUsageRenderTarget; dd.storageMode = MTLStorageModePrivate;
    id<MTLTexture> msd = [dev newTextureWithDescriptor:dd];
    MTLTextureDescriptor *rd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:W height:H mipmapped:NO];
    rd.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead; rd.storageMode = MTLStorageModePrivate;
    id<MTLTexture> res = [dev newTextureWithDescriptor:rd];
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new]; pd.vertexFunction = [lib newFunctionWithName:@"vs"]; pd.fragmentFunction = [lib newFunctionWithName:@"fs"];
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm; pd.depthAttachmentPixelFormat = df; if (dsfmt) pd.stencilAttachmentPixelFormat = df; pd.rasterSampleCount = 4;
    id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:pd error:&e]; if (!ps || !msd) { printf("%s: not supported (%s)\n", fn[fi], e.localizedDescription.UTF8String); continue; }
    MTLDepthStencilDescriptor *dsd = [MTLDepthStencilDescriptor new]; dsd.depthCompareFunction = MTLCompareFunctionLess; dsd.depthWriteEnabled = YES;
    if (dsfmt) { MTLStencilDescriptor *sd = [MTLStencilDescriptor new]; sd.stencilCompareFunction = MTLCompareFunctionAlways; sd.depthStencilPassOperation = MTLStencilOperationIncrementClamp;
      dsd.frontFaceStencil = sd; dsd.backFaceStencil = sd; }
    id<MTLDepthStencilState> dss = [dev newDepthStencilStateWithDescriptor:dsd];
    // stencil-tested pass: draw only where stencil >= 2 (overlap count)
    MTLDepthStencilDescriptor *dsd2 = [MTLDepthStencilDescriptor new]; dsd2.depthCompareFunction = MTLCompareFunctionAlways; dsd2.depthWriteEnabled = NO;
    if (dsfmt) { MTLStencilDescriptor *sd = [MTLStencilDescriptor new]; sd.stencilCompareFunction = MTLCompareFunctionLessEqual; sd.readMask = 0xff;
      dsd2.frontFaceStencil = sd; dsd2.backFaceStencil = sd; }
    id<MTLDepthStencilState> dss2 = [dev newDepthStencilStateWithDescriptor:dsd2];
    id<MTLCommandBuffer> cb = [q commandBuffer];
    // pass 1: clear + first 2 triangles, store; pass 2 (pass==1 variant: Load) remaining triangles, resolve
    for (int k = 0; k < 2; k++) {
      MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
      rp.colorAttachments[0].texture = msc; rp.depthAttachment.texture = msd; if (dsfmt) rp.stencilAttachment.texture = msd;
      rp.colorAttachments[0].clearColor = MTLClearColorMake(0.25, 0.5, 0.75, 1); rp.depthAttachment.clearDepth = 1.0;
      MTLLoadAction la = k == 0 ? MTLLoadActionClear : MTLLoadActionLoad;
      rp.colorAttachments[0].loadAction = la; rp.depthAttachment.loadAction = la; if (dsfmt) rp.stencilAttachment.loadAction = la;
      rp.colorAttachments[0].storeAction = k == 0 ? MTLStoreActionStore : MTLStoreActionMultisampleResolve; rp.depthAttachment.storeAction = MTLStoreActionStore; if (dsfmt) rp.stencilAttachment.storeAction = MTLStoreActionStore;
      if (k == 1) rp.colorAttachments[0].resolveTexture = res;
      id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
      [re setRenderPipelineState:ps]; [re setDepthStencilState:dss];
      if (pass == 0 || k == 0) { [re setVertexBytes:tri length:sizeof tri atIndex:0]; [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:k ? 6 : 0 vertexCount:6]; }
      if (pass == 1 && k == 1) { [re setVertexBytes:tri length:sizeof tri atIndex:0]; [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:6 vertexCount:6];
        if (dsfmt) { [re setDepthStencilState:dss2]; [re setStencilReferenceValue:2]; P quad[3] = { {{-1,-1,0,1},{1,0,1,1}}, {{3,-1,0,1},{1,0,1,1}}, {{-1,3,0,1},{1,0,1,1}} };
          [re setVertexBytes:quad length:sizeof quad atIndex:0]; [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; } }
      [re endEncoding];
    }
    id<MTLBuffer> out = [dev newBufferWithLength:W * H * 4 options:MTLResourceStorageModeShared];
    id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
    [b copyFromTexture:res sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(W,H,1) toBuffer:out destinationOffset:0 destinationBytesPerRow:W*4 destinationBytesPerImage:W*H*4];
    [b endEncoding]; [cb commit]; [cb waitUntilCompleted];
    char name[64]; snprintf(name, sizeof name, "msaa %s %s resolve", fn[fi], pass ? "2pass-load+stencil" : "2pass");
    sha(name, out.contents, W * H * 4);
    const uint8_t *c = out.contents; printf("   px(10,10)=%u,%u,%u px(650,366)=%u,%u,%u\n", c[(10*W+10)*4+2], c[(10*W+10)*4+1], c[(10*W+10)*4], c[(366*W+650)*4+2], c[(366*W+650)*4+1], c[(366*W+650)*4]);
  }
  // shadow map: 1x depth-only render, then sample_compare it, and copy the depth to a buffer
  for (int fi = 0; fi < 4; fi++) {
    MTLPixelFormat df = fmts[fi]; int dsfmt = fi == 1 || fi == 2;
    const int S = 2048;
    MTLTextureDescriptor *dd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:df width:S height:S mipmapped:NO];
    dd.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead; dd.storageMode = MTLStorageModePrivate;
    id<MTLTexture> sm = [dev newTextureWithDescriptor:dd];
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new]; pd.vertexFunction = [lib newFunctionWithName:@"vs"]; pd.fragmentFunction = nil;
    pd.depthAttachmentPixelFormat = df; if (dsfmt) pd.stencilAttachmentPixelFormat = df;
    id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:pd error:&e]; if (!ps || !sm) { printf("%s depth-only: not supported\n", fn[fi]); continue; }
    MTLDepthStencilDescriptor *dsd = [MTLDepthStencilDescriptor new]; dsd.depthCompareFunction = MTLCompareFunctionLess; dsd.depthWriteEnabled = YES;
    id<MTLDepthStencilState> dss = [dev newDepthStencilStateWithDescriptor:dsd];
    MTLTextureDescriptor *rd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float width:512 height:512 mipmapped:NO];
    rd.usage = MTLTextureUsageRenderTarget; rd.storageMode = MTLStorageModePrivate; id<MTLTexture> rt = [dev newTextureWithDescriptor:rd];
    MTLRenderPipelineDescriptor *pd2 = [MTLRenderPipelineDescriptor new]; pd2.vertexFunction = [lib newFunctionWithName:@"vq"]; pd2.fragmentFunction = [lib newFunctionWithName:@"shadow"];
    pd2.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA32Float; id<MTLRenderPipelineState> ps2 = [dev newRenderPipelineStateWithDescriptor:pd2 error:&e];
    MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new]; sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterLinear; sd.compareFunction = MTLCompareFunctionLessEqual;
    id<MTLSamplerState> smp = [dev newSamplerStateWithDescriptor:sd];
    id<MTLCommandBuffer> cb = [q commandBuffer];
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor]; rp.depthAttachment.texture = sm; rp.depthAttachment.clearDepth = 1.0;
    rp.depthAttachment.loadAction = MTLLoadActionClear; rp.depthAttachment.storeAction = MTLStoreActionStore;
    if (dsfmt) { rp.stencilAttachment.texture = sm; rp.stencilAttachment.loadAction = MTLLoadActionClear; rp.stencilAttachment.storeAction = MTLStoreActionStore; }
    id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp]; [re setRenderPipelineState:ps]; [re setDepthStencilState:dss];
    [re setVertexBytes:tri length:sizeof tri atIndex:0]; [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:12]; [re endEncoding];
    MTLRenderPassDescriptor *rp2 = [MTLRenderPassDescriptor renderPassDescriptor]; rp2.colorAttachments[0].texture = rt; rp2.colorAttachments[0].loadAction = MTLLoadActionClear; rp2.colorAttachments[0].storeAction = MTLStoreActionStore;
    re = [cb renderCommandEncoderWithDescriptor:rp2]; [re setRenderPipelineState:ps2]; [re setFragmentTexture:sm atIndex:0]; [re setFragmentSamplerState:smp atIndex:0];
    [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [re endEncoding];
    id<MTLBuffer> o1 = [dev newBufferWithLength:512*512*16 options:MTLResourceStorageModeShared], o2 = [dev newBufferWithLength:(size_t)S*S*4 options:MTLResourceStorageModeShared];
    id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
    [b copyFromTexture:rt sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(512,512,1) toBuffer:o1 destinationOffset:0 destinationBytesPerRow:512*16 destinationBytesPerImage:512*512*16];
    [b copyFromTexture:sm sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(S,S,1) toBuffer:o2 destinationOffset:0 destinationBytesPerRow:S*4 destinationBytesPerImage:(NSUInteger)S*S*4 options:MTLBlitOptionDepthFromDepthStencil];
    [b endEncoding]; [cb commit]; [cb waitUntilCompleted];
    char n1[64], n2[64]; snprintf(n1, sizeof n1, "shadow sample_compare %s", fn[fi]); snprintf(n2, sizeof n2, "shadow depth->buffer %s", fn[fi]);
    sha(n1, o1.contents, 512*512*16); sha(n2, o2.contents, (size_t)S*S*4);
    if (df == MTLPixelFormatDepth16Unorm) { const uint16_t *h = o2.contents; printf("   depth16(10,10)=%u\n", h[10*S+10]); } else { const float *f = o2.contents; printf("   depth(10,10)=%.4f depth(1024,1024)=%.4f\n", f[10*S+10], f[1024*S+1024]); }
  }
}}
