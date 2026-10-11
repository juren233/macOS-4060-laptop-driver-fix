// lintarget: renders the same small scene into a plain texture and into an IOSurface texture (a linear image over the
// surface's shared VRAM with NullMoth) with: plain draw, 4x MSAA + resolve, blending, stencil. Prints per-case mismatches.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurface.h>
static NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
 "struct V { float4 p [[position]]; };\n"
 "vertex V vs(uint i [[vertex_id]], constant float2 *pts [[buffer(0)]]) { V o; o.p = float4(pts[i], 0, 1); return o; }\n"
 "fragment float4 fs(constant float4 &c [[buffer(0)]]) { return c; }\n";
int main(int argc, char **argv) { @autoreleasepool {
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice(); id<MTLCommandQueue> q = [dev newCommandQueue]; NSError *e = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:src options:nil error:&e]; if (!lib) { printf("lib: %s\n", e.description.UTF8String); return 1; }
    const int W = argc > 1 ? atoi(argv[1]) : 288, H = argc > 2 ? atoi(argv[2]) : 32; int bad = 0;
    // octagon-prone shape: a triangle fan of a rounded-ish polygon, drawn with edges at odd angles
    float pts[] = { -0.9f, -0.8f, 0.85f, -0.6f, -0.3f, 0.9f };
    for (int cs = 0; cs < 4; cs++) {   // 0 plain, 1 msaa4 resolve, 2 blend over grey, 3 stencil-masked
        uint8_t *img[2]; int lin = 0;
        for (int target = 0; target < 2; target++) {
            MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:W height:H mipmapped:NO];
            td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead; td.storageMode = MTLStorageModeShared;
            const size_t pitch = ((size_t)W * 4 + 63) & ~(size_t)63;
            IOSurfaceRef s = target ? IOSurfaceCreate((__bridge CFDictionaryRef)@{ (id)kIOSurfaceWidth: @(W), (id)kIOSurfaceHeight: @(H),
                (id)kIOSurfaceBytesPerElement: @4, (id)kIOSurfaceBytesPerRow: @(pitch), (id)kIOSurfacePixelFormat: @((uint32_t)'BGRA') }) : NULL;
            id<MTLTexture> t = target ? [dev newTextureWithDescriptor:td iosurface:s plane:0] : [dev newTextureWithDescriptor:td];
            MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new]; pd.vertexFunction = [lib newFunctionWithName:@"vs"]; pd.fragmentFunction = [lib newFunctionWithName:@"fs"];
            pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm; pd.rasterSampleCount = cs == 1 ? 4 : 1;
            if (cs == 2) { pd.colorAttachments[0].blendingEnabled = YES; pd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
                pd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha; pd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
                pd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha; }
            if (cs == 3) pd.stencilAttachmentPixelFormat = MTLPixelFormatStencil8;
            id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:pd error:&e]; if (!ps) { printf("pso: %s\n", e.description.UTF8String); return 1; }
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.colorAttachments[0].clearColor = MTLClearColorMake(0.5, 0.5, 0.5, 1); rp.colorAttachments[0].loadAction = MTLLoadActionClear;
            if (cs == 1) { MTLTextureDescriptor *md = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:W height:H mipmapped:NO];
                md.textureType = MTLTextureType2DMultisample; md.sampleCount = 4; md.usage = MTLTextureUsageRenderTarget; md.storageMode = MTLStorageModePrivate;
                rp.colorAttachments[0].texture = [dev newTextureWithDescriptor:md]; rp.colorAttachments[0].resolveTexture = t;
                rp.colorAttachments[0].storeAction = MTLStoreActionMultisampleResolve; }
            else { rp.colorAttachments[0].texture = t; rp.colorAttachments[0].storeAction = MTLStoreActionStore; }
            id<MTLDepthStencilState> dss = nil, dss2 = nil;
            if (cs == 3) { MTLTextureDescriptor *sd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatStencil8 width:W height:H mipmapped:NO];
                sd.usage = MTLTextureUsageRenderTarget; sd.storageMode = MTLStorageModePrivate;
                rp.stencilAttachment.texture = [dev newTextureWithDescriptor:sd]; rp.stencilAttachment.loadAction = MTLLoadActionClear; rp.stencilAttachment.clearStencil = 0;
                MTLDepthStencilDescriptor *a = [MTLDepthStencilDescriptor new]; MTLStencilDescriptor *st = [MTLStencilDescriptor new];
                st.stencilCompareFunction = MTLCompareFunctionAlways; st.depthStencilPassOperation = MTLStencilOperationReplace; a.frontFaceStencil = a.backFaceStencil = st;
                dss = [dev newDepthStencilStateWithDescriptor:a];
                MTLDepthStencilDescriptor *b = [MTLDepthStencilDescriptor new]; MTLStencilDescriptor *st2 = [MTLStencilDescriptor new];
                st2.stencilCompareFunction = MTLCompareFunctionEqual; b.frontFaceStencil = b.backFaceStencil = st2; dss2 = [dev newDepthStencilStateWithDescriptor:b]; }
            id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLRenderCommandEncoder> en = [cb renderCommandEncoderWithDescriptor:rp];
            [en setRenderPipelineState:ps]; [en setVertexBytes:pts length:sizeof pts atIndex:0];
            float col[4] = { 0.1f, 0.4f, 0.9f, cs == 2 ? 0.5f : 1.0f };
            if (cs == 3) { // write stencil 1 inside the triangle (colour masked by drawing same colour as clear), then draw a full quad where stencil == 1
                float clr[4] = { 0.5f, 0.5f, 0.5f, 1 }; [en setDepthStencilState:dss]; [en setStencilReferenceValue:1]; [en setFragmentBytes:clr length:16 atIndex:0];
                [en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
                float quad[] = { -1, -1, 1, -1, -1, 1, 1, -1, 1, 1, -1, 1 }; [en setVertexBytes:quad length:sizeof quad atIndex:0];
                [en setDepthStencilState:dss2]; [en setStencilReferenceValue:1]; [en setFragmentBytes:col length:16 atIndex:0];
                [en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
            } else { [en setFragmentBytes:col length:16 atIndex:0]; [en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; }
            [en endEncoding]; [cb commit]; [cb waitUntilCompleted];
            img[target] = malloc((size_t)W * H * 4); [t getBytes:img[target] bytesPerRow:W * 4 fromRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0];
            if (target) { lin = 1; CFRelease(s); }
        }
        int diff = 0, maxd = 0; for (int i = 0; i < W * H * 4; i++) { int d = abs(img[0][i] - img[1][i]); if (d > 2) diff++; if (d > maxd) maxd = d; }
        const char *nm[] = { "plain draw", "4x MSAA resolve", "alpha blend", "stencil mask" };
        printf("%-16s %dx%d: %d bytes differ (max %d) plain px(10,%d)=%02x%02x%02x%02x iosurface=%02x%02x%02x%02x %s\n", nm[cs], W, H, diff, maxd, H / 2,
               img[0][(H / 2 * W + 10) * 4 + 2], img[0][(H / 2 * W + 10) * 4 + 1], img[0][(H / 2 * W + 10) * 4], img[0][(H / 2 * W + 10) * 4 + 3],
               img[1][(H / 2 * W + 10) * 4 + 2], img[1][(H / 2 * W + 10) * 4 + 1], img[1][(H / 2 * W + 10) * 4], img[1][(H / 2 * W + 10) * 4 + 3], diff ? "MISMATCH" : "ok");
        bad += diff != 0; (void)lin; free(img[0]); free(img[1]);
    }
    printf("mismatching cases: %d\n", bad);
    return 0;
}}
