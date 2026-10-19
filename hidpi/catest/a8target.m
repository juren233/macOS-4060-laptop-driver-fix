#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
// A8Unorm colour attachments (upstream 2.3.6 #271): Vulkan has no A8 render format, so the target is an R8 image whose red
// lane must hold Metal's ALPHA. Core Animation draws text and badge masks this way. Checked: clear alpha, an unblended draw
// (fragment alpha only), and source-over blending (alpha factors applied to the red lane). Before the fix the red lane got
// the fragment's red and the clear's red: every value below came out wrong.
static NSString *src = @
"#include <metal_stdlib>\n"
"using namespace metal;\n"
"struct VOut { float4 pos [[position]]; };\n"
"vertex VOut vs(uint vid [[vertex_id]]) {\n"
"  float2 q[4] = { float2(0,0), float2(1,0), float2(0,1), float2(1,1) };\n"
"  VOut o; o.pos = float4(q[vid]*2.0-1.0, 0, 1); return o; }\n"
"fragment float4 fs(VOut in [[stage_in]]) { return float4(0.1, 0.9, 0.3, 0.75); }\n";
int main(void) { @autoreleasepool {
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    NSError *e = nil; id<MTLLibrary> lib = [dev newLibraryWithSource:src options:nil error:&e];
    if (!lib) { printf("library FAILED: %s\nFAIL\n", e.localizedDescription.UTF8String); return 1; }
    id<MTLCommandQueue> q = [dev newCommandQueue];
    int bad = 0;
    // case 0: clear only; 1: draw without blending; 2: source-over (alpha = a*Sa + d*(1-Sa))
    const int want[3] = { 64, 191, 159 };   // 0.25; 0.75; 0.75*0.75 + 0.25*0.25 = 0.625
    for (int c = 0; c < 3; c++) {
        MTLTextureDescriptor *rd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatA8Unorm width:16 height:16 mipmapped:NO];
        rd.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead; rd.storageMode = MTLStorageModeShared;
        id<MTLTexture> rt = [dev newTextureWithDescriptor:rd];
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = rt; rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        rp.colorAttachments[0].storeAction = MTLStoreActionStore; rp.colorAttachments[0].clearColor = MTLClearColorMake(0.9, 0.9, 0.9, 0.25);
        id<MTLCommandBuffer> cb = [q commandBuffer];
        id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
        if (c) {
            MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
            d.vertexFunction = [lib newFunctionWithName:@"vs"]; d.fragmentFunction = [lib newFunctionWithName:@"fs"];
            d.colorAttachments[0].pixelFormat = MTLPixelFormatA8Unorm;
            if (c == 2) { MTLRenderPipelineColorAttachmentDescriptor *a = d.colorAttachments[0]; a.blendingEnabled = YES;
                a.sourceRGBBlendFactor = a.sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
                a.destinationRGBBlendFactor = a.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha; }
            id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:d error:&e];
            if (!ps) { printf("pipeline FAILED: %s\nFAIL\n", e.localizedDescription.UTF8String); return 1; }
            [re setRenderPipelineState:ps]; [re drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
        }
        [re endEncoding]; [cb commit]; [cb waitUntilCompleted];
        uint8_t px[256]; [rt getBytes:px bytesPerRow:16 fromRegion:MTLRegionMake2D(0, 0, 16, 16) mipmapLevel:0];
        int off = 0; for (int i = 0; i < 256; i++) if (abs((int)px[i] - want[c]) > 1) off++;
        printf("case %d (%s): pixel 0 = %d, want %d, %d of 256 off\n", c, c == 0 ? "clear" : c == 1 ? "draw" : "blend", px[0], want[c], off);
        bad += off != 0;
    }
    printf("%s\n", bad ? "FAIL" : "PASS");
    return bad ? 1 : 0;
} }
