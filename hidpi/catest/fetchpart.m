#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
// Framebuffer fetch ([[color(n)]]) in an app process (upstream 416ee60 input attachments, 351f5ed missing attachments,
// 2.3.6 #270 fetch-off reads). Pass with ONE colour attachment cleared to (0.2, 0.4, 0.6, 1.0):
//  case 0: fs reads color(0) and adds 0.25                         -> (0.45, 0.65, 0.85, 1.0)
//  case 1: fs reads color(0) and color(1) (the pass has no 1)    -> the missing one reads zero: same as case 0
//  case 2: two overlapping triangles in ONE draw each add 0.1 to what is there (per-pixel order inside a draw)
//          -> the overlap gets +0.2: (0.4, 0.6, 0.8)
static NSString *src = @
"#include <metal_stdlib>\n"
"using namespace metal;\n"
"struct VOut { float4 pos [[position]]; };\n"
"vertex VOut vs(uint vid [[vertex_id]]) {\n"
"  float2 q[6] = { float2(0,0), float2(1,0), float2(0,1), float2(1,0), float2(0,1), float2(1,1) };\n"
"  VOut o; o.pos = float4(q[vid % 6]*2.0-1.0, 0, 1); return o; }\n"
"vertex VOut vs2(uint vid [[vertex_id]]) {\n"
"  float2 q[3] = { float2(-1,-1), float2(3,-1), float2(-1,3) };\n"
"  VOut o; o.pos = float4(q[vid % 3], 0, 1); return o; }\n"
"struct F1 { float4 c [[color(0)]]; };\n"
"fragment F1 fs0(VOut in [[stage_in]], float4 c0 [[color(0)]]) { F1 o; o.c = c0 + 0.25; return o; }\n"
"fragment F1 fs1(VOut in [[stage_in]], float4 c0 [[color(0)]], float4 c1 [[color(1)]]) { F1 o; o.c = c0 + c1 + 0.25; return o; }\n"
"fragment F1 fs2(VOut in [[stage_in]], float4 c0 [[color(0)]]) { F1 o; o.c = float4(c0.rgb + 0.1, 1); return o; }\n";
int main(void) { @autoreleasepool {
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    NSError *e = nil; id<MTLLibrary> lib = [dev newLibraryWithSource:src options:nil error:&e];
    if (!lib) { printf("library FAILED: %s\nFAIL\n", e.localizedDescription.UTF8String); return 1; }
    id<MTLCommandQueue> q = [dev newCommandQueue];
    int bad = 0;
    const char *fsn[3] = { "fs0", "fs1", "fs2" };
    const int want[3][3] = { { 115, 166, 217 }, { 115, 166, 217 }, { 102, 153, 204 } };   // BGRA8 read back as RGB
    for (int c = 0; c < 3; c++) {
        MTLTextureDescriptor *rd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:16 height:16 mipmapped:NO];
        rd.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead; rd.storageMode = MTLStorageModeShared;
        id<MTLTexture> rt = [dev newTextureWithDescriptor:rd];
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = rt; rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        rp.colorAttachments[0].storeAction = MTLStoreActionStore; rp.colorAttachments[0].clearColor = MTLClearColorMake(0.2, 0.4, 0.6, 1.0);
        MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
        d.vertexFunction = [lib newFunctionWithName:c == 2 ? @"vs2" : @"vs"]; d.fragmentFunction = [lib newFunctionWithName:@(fsn[c])];
        d.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
        id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:d error:&e];
        if (!ps) { printf("case %d pipeline FAILED: %s\n", c, e.localizedDescription.UTF8String); bad++; continue; }
        id<MTLCommandBuffer> cb = [q commandBuffer];
        id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
        [re setRenderPipelineState:ps];
        [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];   // case 2: the same full-screen triangle twice
        [re endEncoding]; [cb commit]; [cb waitUntilCompleted];
        uint8_t px[16 * 16 * 4]; [rt getBytes:px bytesPerRow:64 fromRegion:MTLRegionMake2D(0, 0, 16, 16) mipmapLevel:0];
        int off = 0; for (int i = 0; i < 256; i++) for (int k = 0; k < 3; k++) if (abs((int)px[i * 4 + k] - want[c][k]) > 2) { off++; break; }
        printf("case %d (%s): pixel 0 = %d %d %d, want %d %d %d, %d of 256 off\n", c, fsn[c], px[0], px[1], px[2], want[c][0], want[c][1], want[c][2], off);
        bad += off != 0;
    }
    printf("%s\n", bad ? "FAIL" : "PASS");
    return bad ? 1 : 0;
} }
