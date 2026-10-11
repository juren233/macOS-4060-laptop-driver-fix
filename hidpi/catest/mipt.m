// mipt: mipmapped texture sampling. Preview / the screenshot thumbnail draw big images as 1024-px tiles that came out as one
// flat colour each (= the smallest mip level). Builds a mipmapped texture three ways (blit generateMipmaps, render into each
// level through attachment.level, render into each level through a level view), reads every level back, then samples it
// at 1:1, 1/2 and 1/4 scale with a trilinear sampler and with explicit bias/level/gradient.
// usage: mipt [N]   (N = texture side, default 1024)
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
static NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
 "struct V { float4 p [[position]]; float2 uv; };\n"
 "vertex V vs(uint i [[vertex_id]], constant float2 *pts [[buffer(0)]]) { V o; o.p = float4(pts[i], 0, 1); o.uv = pts[i] * float2(0.5, -0.5) + 0.5; return o; }\n"
 "fragment float4 fs(V in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) { return t.sample(s, in.uv); }\n"
 "fragment float4 fsb(V in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) { return t.sample(s, in.uv, bias(0.0)); }\n"
 "fragment float4 fsl(V in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]], constant float &l [[buffer(0)]]) { return t.sample(s, in.uv, level(l)); }\n"
 "fragment float4 fsg(V in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) { return t.sample(s, in.uv, gradient2d(dfdx(in.uv), dfdy(in.uv))); }\n"
 "fragment float4 down(V in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]], constant float &l [[buffer(0)]]) { return t.sample(s, in.uv, level(l)); }\n";
static int N;
static uint8_t px0(int x, int y, int c) { return c == 0 ? (uint8_t)(x * 255 / (N - 1)) : c == 1 ? (uint8_t)(y * 255 / (N - 1)) : c == 2 ? (uint8_t)(((x >> 4) ^ (y >> 4)) & 1 ? 230 : 20) : 255; }
// reference level k: box average of level 0 (exact for power-of-two N)
static uint8_t *refLevel(const uint8_t *l0, int k) {
    int s = N >> k, f = 1 << k; uint8_t *r = malloc((size_t)s * s * 4);
    for (int y = 0; y < s; y++) for (int x = 0; x < s; x++) for (int c = 0; c < 4; c++) { double a = 0;
        for (int j = 0; j < f; j++) for (int i = 0; i < f; i++) a += l0[(((size_t)(y * f + j)) * N + x * f + i) * 4 + c];
        r[((size_t)y * s + x) * 4 + c] = (uint8_t)(a / (f * f) + 0.5); }
    return r;
}
// mean abs diff over the image; also the spread (stddev of channel 0) to spot "flat colour"
static void cmp(const char *what, const uint8_t *a, const uint8_t *b, int w, int h, int *bad) {
    double d = 0, m = 0, m2 = 0; size_t n = (size_t)w * h;
    for (size_t i = 0; i < n; i++) { for (int c = 0; c < 3; c++) d += abs(a[i * 4 + c] - b[i * 4 + c]); m += a[i * 4]; m2 += (double)a[i * 4] * a[i * 4]; }
    d /= n * 3; m /= n; double sd = sqrt(fmax(0, m2 / n - m * m)); int ok = d < 6;
    printf("%-44s %4dx%-4d mad %6.2f  spread %6.1f  %s\n", what, w, h, d, sd, ok ? "ok" : "BAD"); if (!ok) (*bad)++;
}
static void readTex(id<MTLCommandQueue> q, id<MTLTexture> t, int lvl, uint8_t *out) {
    int s = (int)t.width >> lvl; id<MTLBuffer> b = [q.device newBufferWithLength:(size_t)s * s * 4 options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder];
    [bl copyFromTexture:t sourceSlice:0 sourceLevel:lvl sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(s, s, 1) toBuffer:b destinationOffset:0 destinationBytesPerRow:s * 4 destinationBytesPerImage:(size_t)s * s * 4];
    [bl endEncoding]; [cb commit]; [cb waitUntilCompleted]; memcpy(out, b.contents, (size_t)s * s * 4);
}
int main(int argc, char **argv) { @autoreleasepool {
    N = argc > 1 ? atoi(argv[1]) : 1024; int bad = 0, L = 0; while ((N >> L) > 1) L++; L++;
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice(); id<MTLCommandQueue> q = [dev newCommandQueue]; NSError *e = nil;
    printf("device %s, N %d, levels %d\n", dev.name.UTF8String, N, L);
    id<MTLLibrary> lib = [dev newLibraryWithSource:src options:nil error:&e]; if (!lib) { printf("lib: %s\n", e.description.UTF8String); return 1; }
    static const float quad[] = { -1, -1, 1, -1, -1, 1, 1, -1, 1, 1, -1, 1 };
    uint8_t *l0 = malloc((size_t)N * N * 4); for (int y = 0; y < N; y++) for (int x = 0; x < N; x++) for (int c = 0; c < 4; c++) l0[((size_t)y * N + x) * 4 + c] = px0(x, y, c);
    uint8_t *ref[16]; for (int k = 0; k < L; k++) ref[k] = refLevel(l0, k);
    uint8_t *got = malloc((size_t)N * N * 4);
    MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new]; sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterLinear; sd.mipFilter = MTLSamplerMipFilterLinear;
    id<MTLSamplerState> tri = [dev newSamplerStateWithDescriptor:sd];
    sd.mipFilter = MTLSamplerMipFilterNearest; id<MTLSamplerState> near = [dev newSamplerStateWithDescriptor:sd];
    sd.mipFilter = MTLSamplerMipFilterLinear; sd.lodMinClamp = 0; sd.lodMaxClamp = 3; id<MTLSamplerState> clamp3 = [dev newSamplerStateWithDescriptor:sd];
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new]; pd.vertexFunction = [lib newFunctionWithName:@"vs"]; pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    NSDictionary *pipes = @{}; NSMutableDictionary *pm = [NSMutableDictionary dictionary];
    for (NSString *f in @[ @"fs", @"fsb", @"fsl", @"fsg", @"down" ]) { pd.fragmentFunction = [lib newFunctionWithName:f]; id p = [dev newRenderPipelineStateWithDescriptor:pd error:&e]; if (!p) { printf("%s: %s\n", f.UTF8String, e.description.UTF8String); return 1; } pm[f] = p; }
    pipes = pm;
    // draw `fn` sampling t into a fresh OWxOW target, read it back
    uint8_t *(^draw)(id<MTLTexture>, id<MTLSamplerState>, NSString *, float, int) = ^uint8_t *(id<MTLTexture> t, id<MTLSamplerState> s, NSString *fn, float lv, int OW) {
        MTLTextureDescriptor *od = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:OW height:OW mipmapped:NO];
        od.usage = MTLTextureUsageRenderTarget; od.storageMode = MTLStorageModePrivate; id<MTLTexture> o = [dev newTextureWithDescriptor:od];
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor]; rp.colorAttachments[0].texture = o; rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
        [re setRenderPipelineState:pipes[fn]]; [re setVertexBytes:quad length:sizeof quad atIndex:0]; [re setFragmentTexture:t atIndex:0]; [re setFragmentSamplerState:s atIndex:0];
        [re setFragmentBytes:&lv length:4 atIndex:0]; [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6]; [re endEncoding]; [cb commit]; [cb waitUntilCompleted];
        uint8_t *r = malloc((size_t)OW * OW * 4); readTex(q, o, 0, r); return r; };
    for (int build = 0; build < 3; build++) {
        static const char *BN[] = { "generateMipmaps", "render attachment.level", "render level view" };
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:N height:N mipmapped:YES];
        td.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget | (build == 2 ? MTLTextureUsagePixelFormatView : 0); td.storageMode = MTLStorageModePrivate;
        id<MTLTexture> t = [dev newTextureWithDescriptor:td];
        id<MTLBuffer> up = [dev newBufferWithBytes:l0 length:(size_t)N * N * 4 options:MTLResourceStorageModeShared];
        id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder];
        [bl copyFromBuffer:up sourceOffset:0 sourceBytesPerRow:N * 4 sourceBytesPerImage:(size_t)N * N * 4 sourceSize:MTLSizeMake(N, N, 1) toTexture:t destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
        if (build == 0) [bl generateMipmapsForTexture:t];
        [bl endEncoding];
        if (build > 0) for (int k = 1; k < L; k++) {   // level k = linear sample of level k-1 at its texel centres (2x2 box)
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
            if (build == 1) { rp.colorAttachments[0].texture = t; rp.colorAttachments[0].level = k; }
            else rp.colorAttachments[0].texture = [t newTextureViewWithPixelFormat:t.pixelFormat textureType:MTLTextureType2D levels:NSMakeRange(k, 1) slices:NSMakeRange(0, 1)];
            rp.colorAttachments[0].loadAction = MTLLoadActionDontCare; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
            id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp]; float lv = k - 1;
            [re setRenderPipelineState:pipes[@"down"]]; [re setVertexBytes:quad length:sizeof quad atIndex:0]; [re setFragmentTexture:t atIndex:0]; [re setFragmentSamplerState:near atIndex:0];
            [re setFragmentBytes:&lv length:4 atIndex:0]; [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6]; [re endEncoding];
        }
        [cb commit]; [cb waitUntilCompleted]; if (cb.error) printf("cb error %s\n", cb.error.description.UTF8String);
        printf("--- %s\n", BN[build]);
        for (int k = 0; k < L && k < 4; k++) { char nm[64]; snprintf(nm, 64, "level %d readback", k); readTex(q, t, k, got); cmp(nm, got, ref[k], N >> k, N >> k, &bad); }
        for (int k = 0; k < 3; k++) { int OW = N >> k; char nm[64]; uint8_t *r;
            snprintf(nm, 64, "trilinear sample @1/%d", 1 << k); r = draw(t, tri, @"fs", 0, OW); cmp(nm, r, ref[k], OW, OW, &bad); free(r);
            snprintf(nm, 64, "mip-nearest sample @1/%d", 1 << k); r = draw(t, near, @"fs", 0, OW); cmp(nm, r, ref[k], OW, OW, &bad); free(r);
            snprintf(nm, 64, "lodMaxClamp 3 sample @1/%d", 1 << k); r = draw(t, clamp3, @"fs", 0, OW); cmp(nm, r, ref[k], OW, OW, &bad); free(r);
            snprintf(nm, 64, "bias(0) @1/%d", 1 << k); r = draw(t, tri, @"fsb", 0, OW); cmp(nm, r, ref[k], OW, OW, &bad); free(r);
            snprintf(nm, 64, "gradient2d @1/%d", 1 << k); r = draw(t, tri, @"fsg", 0, OW); cmp(nm, r, ref[k], OW, OW, &bad); free(r);
            snprintf(nm, 64, "level(%d) @1/%d", k, 1 << k); r = draw(t, tri, @"fsl", k, OW); cmp(nm, r, ref[k], OW, OW, &bad); free(r);
        }
    }
    printf(bad ? "FAIL %d\n" : "PASS\n", bad); return bad != 0;
}}
