// lanczos: hand-written copy of Core Image's _lanczosDownH (12 taps along x, weights 3*sin(pi x)*sin(pi x/3)/(pi x)^2 behind
// two branches each, sample coords = 3x2 matrix * (tap, 1)) vs the same maths on the CPU. CI's version came out with every
// output row equal (y of the sample coordinate lost) on NullMoth, so Preview / screenshot thumbnails showed flat tiles.
// usage: lanczos [variant]   variant 0 = as CI, 1 = no branches, 2 = no matrix (sample pixel coords directly)
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <math.h>
static NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
 "static inline float lw(float x) { x = fabs(x); if (x < 3.0f) { if (x < 0.001f) return 1.0f; float a = x * M_PI_F; return sin(a) * 3.0f * sin(x * 1.0471976f) / (a * a); } return 0.0f; }\n"
 "kernel void k(texture2d<float, access::write> out [[texture(0)]], texture2d<float> src [[texture(1)]], sampler s [[sampler(0)]],\n"
 "              constant float4 *buf [[buffer(0)]], constant int &variant [[buffer(1)]], uint2 gid [[thread_position_in_grid]]) {\n"
 "  if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;\n"
 "  float2 dc = float2(gid) + 0.5f; float4 sc = buf[0]; float4 m0 = buf[1], m1 = buf[2];\n"
 "  float2 p = sc.xy * dc; float cx = p.x; p.x = floor(p.x - 0.5f) + 0.5f; float2 d = sc.zw;\n"
 "  float4 acc = 0; float wsum = 0;\n"
 "  for (int k = -5; k <= 6; k++) { float2 c = p + float(k) * d;\n"
 "    float2 uv = variant == 2 ? c / float2(src.get_width(), src.get_height()) : float2(dot(float3(c, 1), m0.xyz), dot(float3(c, 1), m1.xyz));\n"
 "    float4 t = src.sample(s, uv); float w = variant == 1 ? 1.0f / (1.0f + fabs(c.x - cx)) : lw((c.x - cx) / sc.x); acc += w * t; wsum += w; }\n"
 "  out.write(acc / wsum, gid);\n"
 "}\n";
static float lwc(float x) { x = fabsf(x); if (x < 3) { if (x < 0.001f) return 1; float a = x * (float)M_PI; return sinf(a) * 3 * sinf(x * 1.0471976f) / (a * a); } return 0; }
int main(int argc, char **argv) { @autoreleasepool {
    int variant = argc > 1 ? atoi(argv[1]) : 0;
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice(); id<MTLCommandQueue> q = [dev newCommandQueue]; NSError *e = nil;
    MTLCompileOptions *o = [MTLCompileOptions new]; o.fastMathEnabled = YES;
    id<MTLLibrary> lib = [dev newLibraryWithSource:src options:o error:&e]; if (!lib) { printf("lib: %s\n", e.description.UTF8String); return 1; }
    id<MTLComputePipelineState> p = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&e]; if (!p) { printf("pso: %s\n", e.description.UTF8String); return 1; }
    const int SW = 256, SH = 64; const float S = 1.42857f; const int OW = (int)(SW / S), OH = SH;
    float *pix = malloc(SW * SH * 16); for (int y = 0; y < SH; y++) for (int x = 0; x < SW; x++) { float *q4 = pix + (y * SW + x) * 4; q4[0] = x / (float)SW; q4[1] = y / (float)SH; q4[2] = ((x ^ y) & 8) ? 1 : 0; q4[3] = 1; }
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float width:SW height:SH mipmapped:NO]; td.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> st = [dev newTextureWithDescriptor:td]; [st replaceRegion:MTLRegionMake2D(0, 0, SW, SH) mipmapLevel:0 withBytes:pix bytesPerRow:SW * 16];
    td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float width:OW height:OH mipmapped:NO]; td.usage = MTLTextureUsageShaderWrite;
    id<MTLTexture> ot = [dev newTextureWithDescriptor:td];
    MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new]; sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterNearest; id<MTLSamplerState> ss = [dev newSamplerStateWithDescriptor:sd];
    float buf[12] = { S, 1, 1, 0,   1.0f / SW, 0, 0, 0,   0, 1.0f / SH, 0, 0 };   // scale; row0 (x/W); row1 (y/H)
    id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
    [ce setComputePipelineState:p]; [ce setTexture:ot atIndex:0]; [ce setTexture:st atIndex:1]; [ce setSamplerState:ss atIndex:0];
    [ce setBytes:buf length:sizeof buf atIndex:0]; [ce setBytes:&variant length:4 atIndex:1];
    [ce dispatchThreads:MTLSizeMake(OW, OH, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)]; [ce endEncoding]; [cb commit]; [cb waitUntilCompleted];
    float *got = malloc(OW * OH * 16); [ot getBytes:got bytesPerRow:OW * 16 fromRegion:MTLRegionMake2D(0, 0, OW, OH) mipmapLevel:0];
    int bad = 0;
    for (int y = 0; y < OH; y++) for (int x = 0; x < OW; x++) {
        float dcx = x + 0.5f, dcy = y + 0.5f, px = S * dcx, py = dcy, cx = px; px = floorf(px - 0.5f) + 0.5f; float acc[4] = { 0 }, ws = 0;
        for (int k = -5; k <= 6; k++) { float c0 = px + k, c1 = py; int ix = (int)floorf(c0), iy = (int)floorf(c1); ix = ix < 0 ? 0 : ix >= SW ? SW - 1 : ix; iy = iy < 0 ? 0 : iy >= SH ? SH - 1 : iy;
            float w = variant == 1 ? 1.0f / (1.0f + fabsf(c0 - cx)) : lwc((c0 - cx) / S); for (int c = 0; c < 4; c++) acc[c] += w * pix[(iy * SW + ix) * 4 + c]; ws += w; }
        for (int c = 0; c < 4; c++) { float r = acc[c] / ws, g = got[(y * OW + x) * 4 + c]; if (!(fabsf(r - g) < 2e-3f)) { if (bad < 12) printf("BAD (%d,%d).%d gpu %g cpu %g\n", x, y, c, g, r); bad++; } } }
    printf("variant %d: %s %d of %d\n", variant, bad ? "FAIL" : "PASS", bad, OW * OH * 4); return bad != 0;
}}
