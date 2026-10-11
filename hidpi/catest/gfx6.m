// gfx6: does every way of WRITING an IOSurface-backed texture survive the texture being released and a new one made?
// write modes: buffer->texture blit, texture->texture blit, compute write, MSAA resolve, render. Then a fresh texture reads it back.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurface.h>
static id<MTLDevice> dev; static id<MTLCommandQueue> q; static id<MTLLibrary> lib;
static NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
"struct V { float4 p [[position]]; };\n"
"vertex V vq(uint i [[vertex_id]]) { float2 p[4] = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1) }; V o; o.p = float4(p[i], 0, 1); return o; }\n"
"fragment float4 fc(V in [[stage_in]], constant float4 &c [[buffer(0)]]) { return c; }\n"
"kernel void kw(texture2d<float, access::write> t [[texture(0)]], constant float4 &c [[buffer(0)]], uint2 g [[thread_position_in_grid]]) { if (g.x < t.get_width() && g.y < t.get_height()) t.write(c, g); }\n";
static id<MTLTexture> mk(IOSurfaceRef s, int W, int H, MTLTextureUsage u) { MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:W height:H mipmapped:NO]; td.usage = u; td.storageMode = MTLStorageModeManaged; return [dev newTextureWithDescriptor:td iosurface:s plane:0]; }
static int test(const char *nm, int W, int H, int mode) {
    IOSurfaceRef sf = IOSurfaceCreate((__bridge CFDictionaryRef)@{ (id)kIOSurfaceWidth: @(W), (id)kIOSurfaceHeight: @(H), (id)kIOSurfaceBytesPerElement: @4, (id)kIOSurfacePixelFormat: @(0x42475241) });
    int bad = 0; id<MTLBuffer> rb = [dev newBufferWithLength:(size_t)W * H * 4 options:MTLResourceStorageModeShared];
    for (int round = 0; round < 4; round++) {
        float c[4] = { round / 3.f, 1 - round / 3.f, 0.5f, 1 }; uint32_t want = 0xFF000000u | (uint32_t)(c[0] * 255 + 0.5f) << 16 | (uint32_t)(c[1] * 255 + 0.5f) << 8 | (uint32_t)(c[2] * 255 + 0.5f);
        @autoreleasepool {
            id<MTLTexture> t = mk(sf, W, H, MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite | MTLTextureUsagePixelFormatView);
            id<MTLCommandBuffer> cb = [q commandBuffer];
            if (mode == 0) { id<MTLBuffer> src = [dev newBufferWithLength:(size_t)W * H * 4 options:MTLResourceStorageModeShared]; uint32_t *p = src.contents; for (size_t i = 0; i < (size_t)W * H; i++) p[i] = want;
                id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder]; [bl copyFromBuffer:src sourceOffset:0 sourceBytesPerRow:(size_t)W * 4 sourceBytesPerImage:(size_t)W * H * 4 sourceSize:MTLSizeMake(W,H,1) toTexture:t destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)]; [bl endEncoding]; }
            else if (mode == 1) { MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:W height:H mipmapped:NO]; td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead; td.storageMode = MTLStorageModePrivate; id<MTLTexture> tmp = [dev newTextureWithDescriptor:td];
                MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor]; rp.colorAttachments[0].texture = tmp; rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].clearColor = MTLClearColorMake(c[0], c[1], c[2], 1); rp.colorAttachments[0].storeAction = MTLStoreActionStore;
                [[cb renderCommandEncoderWithDescriptor:rp] endEncoding];
                id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder]; [bl copyFromTexture:tmp toTexture:t]; [bl endEncoding]; }
            else if (mode == 2) { id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder]; id<MTLFunction> f = [lib newFunctionWithName:@"kw"]; NSError *e; id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:f error:&e];
                [ce setComputePipelineState:ps]; [ce setTexture:t atIndex:0]; [ce setBytes:c length:16 atIndex:0]; [ce dispatchThreadgroups:MTLSizeMake((W + 7) / 8, (H + 7) / 8, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)]; [ce endEncoding]; }
            else if (mode == 3) { MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:W height:H mipmapped:NO]; td.textureType = MTLTextureType2DMultisample; td.sampleCount = 4; td.usage = MTLTextureUsageRenderTarget; td.storageMode = MTLStorageModePrivate; id<MTLTexture> ms = [dev newTextureWithDescriptor:td];
                MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor]; rp.colorAttachments[0].texture = ms; rp.colorAttachments[0].resolveTexture = t; rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].clearColor = MTLClearColorMake(c[0], c[1], c[2], 1); rp.colorAttachments[0].storeAction = MTLStoreActionMultisampleResolve;
                [[cb renderCommandEncoderWithDescriptor:rp] endEncoding]; }
            else { MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor]; rp.colorAttachments[0].texture = t; rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].clearColor = MTLClearColorMake(c[0], c[1], c[2], 1); rp.colorAttachments[0].storeAction = MTLStoreActionStore; [[cb renderCommandEncoderWithDescriptor:rp] endEncoding]; }
            [cb commit]; [cb waitUntilCompleted];
        }
        id<MTLTexture> r = mk(sf, W, H, MTLTextureUsageShaderRead);   // a NEW texture, as Chromium makes every frame
        id<MTLCommandBuffer> c2 = [q commandBuffer]; id<MTLBlitCommandEncoder> bl = [c2 blitCommandEncoder];
        [bl copyFromTexture:r sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(W,H,1) toBuffer:rb destinationOffset:0 destinationBytesPerRow:(size_t)W * 4 destinationBytesPerImage:(size_t)W * H * 4]; [bl endEncoding]; [c2 commit]; [c2 waitUntilCompleted];
        const uint32_t *g = rb.contents; long diff = 0; for (size_t i = 0; i < (size_t)W * H; i++) { int dd = 0; for (int sh = 0; sh < 24; sh += 8) { int a = (g[i] >> sh) & 255, b2 = (want >> sh) & 255; if (abs(a - b2) > 1) dd = 1; } diff += dd; }
        if (diff) { bad++; if (bad == 1) printf("   round %d: %ld px differ; first px %08x want %08x\n", round, diff, g[0], want); }
    }
    printf("%-26s %-18s %s\n", nm, (const char *[]){ "buffer->texture blit", "texture->texture blit", "compute write", "MSAA resolve", "render clear" }[mode], bad ? "WRONG" : "ok");
    return bad != 0;
}
int main(void) { @autoreleasepool { dev = MTLCreateSystemDefaultDevice(); q = [dev newCommandQueue]; NSError *e; lib = [dev newLibraryWithSource:src options:nil error:&e]; int bad = 0;
    for (int m = 0; m < 5; m++) { bad += test("small (private image)", 640, 480, m); bad += test("large (shared linear)", 2560, 1440, m); }
    printf("%s\n", bad ? "FAIL" : "PASS"); return bad; } }
