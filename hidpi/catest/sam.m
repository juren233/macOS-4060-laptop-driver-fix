// sam: samples a CPU-filled texture with every sampler address mode / filter / coordinate type out of range, once from a plain
// texture and once from an IOSurface texture (a linear image over shared VRAM once the surface has >= NVMTL_SURF_SHARE_MINPX
// pixels). Window compositing samples layer caches with clamp-to-zero / clamp-to-border / repeat to get transparent edges.
// usage: sam [W H]
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurface.h>
static NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
 "struct V { float4 p [[position]]; float2 uv; };\n"
 "vertex V vs(uint i [[vertex_id]], constant float2 *pts [[buffer(0)]]) { V o; o.p = float4(pts[i], 0, 1); o.uv = pts[i] * float2(0.5, -0.5) * 2.0 + 0.5; return o; }\n"  // uv spans -0.5..1.5
 "fragment float4 fs(V in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]], constant float2 &sz [[buffer(0)]]) { return t.sample(s, in.uv); }\n"
 "fragment float4 fsu(V in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]], constant float2 &sz [[buffer(0)]]) { return t.sample(s, in.uv * sz); }\n";
int main(int argc, char **argv) { @autoreleasepool {
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice(); id<MTLCommandQueue> q = [dev newCommandQueue]; NSError *e = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:src options:nil error:&e]; if (!lib) { printf("lib: %s\n", e.description.UTF8String); return 1; }
    const int W = argc > 2 ? atoi(argv[1]) : 288, H = argc > 2 ? atoi(argv[2]) : 32; const int OW = 192, OH = 108;
    const float quad[] = { -1, -1, 1, -1, -1, 1, 1, -1, 1, 1, -1, 1 }; const float szv[2] = { (float)W, (float)H }; int bad = 0;
    const size_t pitch = ((size_t)W * 4 + 63) & ~(size_t)63;
    uint8_t *cpu = malloc((size_t)W * H * 4); for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) { uint8_t *p = cpu + ((size_t)y * W + x) * 4;
        p[0] = (uint8_t)(x * 255 / W); p[1] = (uint8_t)(y * 255 / H); p[2] = (uint8_t)((x ^ y) & 0xff); p[3] = (x < 4 || y < 4 || x >= W - 4 || y >= H - 4) ? 0 : 255; }   // transparent rim
    struct { const char *n; MTLSamplerAddressMode m; } AM[] = { { "clamp_to_edge", MTLSamplerAddressModeClampToEdge }, { "repeat", MTLSamplerAddressModeRepeat },
        { "mirror_repeat", MTLSamplerAddressModeMirrorRepeat }, { "clamp_to_zero", MTLSamplerAddressModeClampToZero }, { "clamp_to_border", MTLSamplerAddressModeClampToBorderColor } };
    for (int pass = 0; pass < 2; pass++)        // 0 normalized coordinates, 1 pixel coordinates
    for (int fl = 0; fl < 2; fl++)              // nearest / linear
    for (unsigned am = 0; am < sizeof AM / sizeof *AM; am++) {
        if (pass == 1 && AM[am].m != MTLSamplerAddressModeClampToEdge && AM[am].m != MTLSamplerAddressModeClampToZero && AM[am].m != MTLSamplerAddressModeClampToBorderColor) continue;   // wrap needs normalized coords
        uint8_t *out[2] = { 0, 0 };
        for (int target = 0; target < 2; target++) {
            MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:W height:H mipmapped:NO];
            td.usage = MTLTextureUsageShaderRead; td.storageMode = MTLStorageModeShared; id<MTLTexture> t; IOSurfaceRef s = NULL;
            if (target) { s = IOSurfaceCreate((__bridge CFDictionaryRef)@{ (id)kIOSurfaceWidth: @(W), (id)kIOSurfaceHeight: @(H), (id)kIOSurfaceBytesPerElement: @4, (id)kIOSurfaceBytesPerRow: @(pitch), (id)kIOSurfacePixelFormat: @((uint32_t)'BGRA') });
                IOSurfaceLock(s, 0, NULL); uint8_t *b = IOSurfaceGetBaseAddress(s); for (int y = 0; y < H; y++) memcpy(b + y * pitch, cpu + (size_t)y * W * 4, (size_t)W * 4); IOSurfaceUnlock(s, 0, NULL);
                t = [dev newTextureWithDescriptor:td iosurface:s plane:0]; }
            else { t = [dev newTextureWithDescriptor:td]; [t replaceRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0 withBytes:cpu bytesPerRow:(size_t)W * 4]; }
            MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new]; sd.sAddressMode = sd.tAddressMode = AM[am].m; sd.minFilter = sd.magFilter = fl ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
            sd.borderColor = MTLSamplerBorderColorOpaqueWhite; sd.normalizedCoordinates = pass == 0; id<MTLSamplerState> ss = [dev newSamplerStateWithDescriptor:sd];
            MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new]; pd.vertexFunction = [lib newFunctionWithName:@"vs"]; pd.fragmentFunction = [lib newFunctionWithName:pass ? @"fsu" : @"fs"];
            pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm; id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:pd error:&e]; if (!ps) { printf("pso: %s\n", e.description.UTF8String); return 1; }
            MTLTextureDescriptor *od = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:OW height:OH mipmapped:NO]; od.usage = MTLTextureUsageRenderTarget; od.storageMode = MTLStorageModeShared; id<MTLTexture> ot = [dev newTextureWithDescriptor:od];
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor]; rp.colorAttachments[0].texture = ot; rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].clearColor = MTLClearColorMake(0.3, 0.6, 0.3, 1); rp.colorAttachments[0].storeAction = MTLStoreActionStore;
            id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLRenderCommandEncoder> en = [cb renderCommandEncoderWithDescriptor:rp]; [en setRenderPipelineState:ps];
            [en setVertexBytes:quad length:sizeof quad atIndex:0]; [en setFragmentTexture:t atIndex:0]; [en setFragmentSamplerState:ss atIndex:0]; [en setFragmentBytes:szv length:8 atIndex:0];
            [en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6]; [en endEncoding]; [cb commit]; [cb waitUntilCompleted];
            out[target] = malloc((size_t)OW * OH * 4); [ot getBytes:out[target] bytesPerRow:OW * 4 fromRegion:MTLRegionMake2D(0, 0, OW, OH) mipmapLevel:0]; if (s) CFRelease(s);
        }
        size_t d = 0; int m = 0; for (size_t i = 0; i < (size_t)OW * OH * 4; i++) { int c = abs(out[0][i] - out[1][i]); if (c > 3) d++; if (c > m) m = c; }
        printf("%-12s %-7s %-16s %dx%d: %6zu bytes differ (max %3d) %s\n", pass ? "pixel coords" : "normalized", fl ? "linear" : "nearest", AM[am].n, W, H, d, m, d ? "MISMATCH" : "ok");
        bad += d != 0; free(out[0]); free(out[1]);
    }
    printf("mismatches: %d\n", bad); return 0;
}}
