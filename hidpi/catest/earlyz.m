#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <mach/mach_time.h>
// Does early depth rejection survive a fragment shader that writes [[sample_mask]] (ANGLE's WriteHelperSampleMask) or has a
// discard? Near occluder first, then 10 heavy fullscreen passes behind it (all rejected if early-Z works).
static NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\nstruct VOut { float4 pos [[position]]; };\n"
"vertex VOut vs(uint vid [[vertex_id]], constant float &z [[buffer(0)]]) { float2 q[3] = { float2(-1,-1), float2(3,-1), float2(-1,3) }; VOut o; o.pos = float4(q[vid],z,1); return o; }\n"
"static float4 heavy(float4 p, float k) { float3 acc = 0; for (int i = 0; i < 64; i++) { float3 d = float3(i*0.37, i*0.11+k, 1.0-i*0.05) - float3(p.xy*0.001, k); float r = rsqrt(dot(d,d)+0.01); acc += float3(0.5, 0.4, 0.3) * r * r; } return float4(acc, 1); }\n"
"fragment float4 plain(VOut in [[stage_in]], constant float &k [[buffer(0)]]) { return heavy(in.pos, k); }\n"
"struct OM { float4 c [[color(0)]]; uint m [[sample_mask]]; };\n"
"fragment OM mask(VOut in [[stage_in]], constant float &k [[buffer(0)]], constant uint &mm [[buffer(1)]]) { OM o; o.c = heavy(in.pos, k); o.m = mm; return o; }\n"
"fragment float4 disc(VOut in [[stage_in]], constant float &k [[buffer(0)]]) { if (k > 100.0) discard_fragment(); return heavy(in.pos, k); }\n"
"fragment float4 flat(VOut in [[stage_in]]) { return float4(0.2, 0.3, 0.4, 1); }\n";
static double now_ms(void) { static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb); return mach_absolute_time() * (double)tb.numer / tb.denom / 1e6; }
int main(int argc, char **argv) { @autoreleasepool {
  id<MTLDevice> dev = MTLCreateSystemDefaultDevice(); NSError *e = nil;
  id<MTLLibrary> lib = [dev newLibraryWithSource:src options:nil error:&e]; if (!lib) { printf("lib %s\n", e.localizedDescription.UTF8String); return 1; }
  id<MTLCommandQueue> q = [dev newCommandQueue];
  const int W = 1600, H = 800;
  for (int S = 1; S <= 4; S += 3) {
    MTLTextureDescriptor *cd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:W height:H mipmapped:NO];
    if (S > 1) { cd.textureType = MTLTextureType2DMultisample; cd.sampleCount = S; } cd.usage = MTLTextureUsageRenderTarget; cd.storageMode = MTLStorageModePrivate;
    MTLTextureDescriptor *dd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float_Stencil8 width:W height:H mipmapped:NO];
    if (S > 1) { dd.textureType = MTLTextureType2DMultisample; dd.sampleCount = S; } dd.usage = MTLTextureUsageRenderTarget; dd.storageMode = MTLStorageModePrivate;
    id<MTLTexture> c = [dev newTextureWithDescriptor:cd], d = [dev newTextureWithDescriptor:dd];
    MTLDepthStencilDescriptor *dsd = [MTLDepthStencilDescriptor new]; dsd.depthCompareFunction = MTLCompareFunctionLessEqual; dsd.depthWriteEnabled = YES;
    id<MTLDepthStencilState> dss = [dev newDepthStencilStateWithDescriptor:dsd];
    id<MTLRenderPipelineState> (^pso)(NSString *) = ^(NSString *fs) { MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
      pd.vertexFunction = [lib newFunctionWithName:@"vs"]; pd.fragmentFunction = [lib newFunctionWithName:fs]; pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
      pd.depthAttachmentPixelFormat = pd.stencilAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8; pd.rasterSampleCount = S; NSError *er = nil;
      id<MTLRenderPipelineState> p = [dev newRenderPipelineStateWithDescriptor:pd error:&er]; if (!p) printf("pso %s: %s\n", fs.UTF8String, er.localizedDescription.UTF8String); return p; };
    id<MTLRenderPipelineState> occ = pso(@"flat");
    for (NSString *fs in @[@"plain", @"mask", @"disc"]) for (int occluded = 0; occluded < 2; occluded++) {
      id<MTLRenderPipelineState> ps = pso(fs); double best = 1e9;
      for (int rep = 0; rep < 6; rep++) {
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor]; rp.colorAttachments[0].texture = c; rp.depthAttachment.texture = d; rp.stencilAttachment.texture = d;
        rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].storeAction = MTLStoreActionDontCare; rp.depthAttachment.loadAction = MTLLoadActionClear; rp.depthAttachment.storeAction = MTLStoreActionDontCare;
        rp.stencilAttachment.loadAction = MTLLoadActionClear; rp.stencilAttachment.storeAction = MTLStoreActionDontCare;
        id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp]; [re setDepthStencilState:dss];
        if (occluded) { float z = 0.1f; [re setRenderPipelineState:occ]; [re setVertexBytes:&z length:4 atIndex:0]; [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; }
        [re setRenderPipelineState:ps]; float k = 0.5f; uint32_t mm = 0xffffffff; [re setFragmentBytes:&k length:4 atIndex:0]; [re setFragmentBytes:&mm length:4 atIndex:1];
        for (int i = 0; i < 10; i++) { float z = 0.5f + i * 0.04f; [re setVertexBytes:&z length:4 atIndex:0]; [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; }
        [re endEncoding]; double t0 = now_ms(); [cb commit]; [cb waitUntilCompleted]; double ms = now_ms() - t0;
        double g = (cb.GPUEndTime - cb.GPUStartTime) * 1000; if (g > 0) ms = g; if (ms < best) best = ms; }
      printf("%dx  %-6s %-10s %7.3f ms\n", S, fs.UTF8String, occluded ? "occluded" : "visible", best);
    }
  }
}}
