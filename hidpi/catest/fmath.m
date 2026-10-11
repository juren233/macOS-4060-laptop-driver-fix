// fmath: fast-math float intrinsics (fast::floor / fast::sin / fabs / fdiv) on the GPU vs the CPU. Core Image's Lanczos
// downscale kernels (_lanczosDownH/_lanczosDownV) use air.fast_floor + air.fast_sin and came out as one flat colour per tile.
// usage: fmath
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <math.h>
static NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
 "kernel void k(device const float *in [[buffer(0)]], device float *out [[buffer(1)]], uint i [[thread_position_in_grid]]) {\n"
 "  float x = in[i];\n"
 "  out[i * 8 + 0] = fast::floor(x);\n"
 "  out[i * 8 + 1] = precise::floor(x);\n"
 "  out[i * 8 + 2] = fast::sin(x);\n"
 "  out[i * 8 + 3] = fast::fabs(x);\n"
 "  out[i * 8 + 4] = fast::floor(x - 0.5f) + 0.5f;\n"
 "  out[i * 8 + 5] = fast::ceil(x);\n"
 "  out[i * 8 + 6] = fast::fract(x);\n"
 "  out[i * 8 + 7] = fast::trunc(x);\n"
 "}\n";
int main(void) { @autoreleasepool {
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice(); id<MTLCommandQueue> q = [dev newCommandQueue]; NSError *e = nil;
    MTLCompileOptions *o = [MTLCompileOptions new]; o.fastMathEnabled = YES;
    id<MTLLibrary> lib = [dev newLibraryWithSource:src options:o error:&e]; if (!lib) { printf("lib: %s\n", e.description.UTF8String); return 1; }
    id<MTLComputePipelineState> p = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&e]; if (!p) { printf("pso: %s\n", e.description.UTF8String); return 1; }
    enum { N = 64 }; float in[N]; for (int i = 0; i < N; i++) in[i] = (i - 32) * 37.37f + 0.25f * (i % 4);
    in[0] = 0.4f; in[1] = 1.6f; in[2] = -0.4f; in[3] = 1234.7f; in[4] = 0.7f; in[5] = 2.2f;
    id<MTLBuffer> bi = [dev newBufferWithBytes:in length:sizeof in options:MTLResourceStorageModeShared];
    id<MTLBuffer> bo = [dev newBufferWithLength:N * 8 * 4 options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
    [ce setComputePipelineState:p]; [ce setBuffer:bi offset:0 atIndex:0]; [ce setBuffer:bo offset:0 atIndex:1];
    [ce dispatchThreads:MTLSizeMake(N, 1, 1) threadsPerThreadgroup:MTLSizeMake(N, 1, 1)]; [ce endEncoding]; [cb commit]; [cb waitUntilCompleted];
    const float *r = bo.contents; int bad = 0; const char *nm[8] = { "fast::floor", "precise::floor", "fast::sin", "fast::fabs", "floor(x-.5)+.5", "fast::ceil", "fast::fract", "fast::trunc" };
    for (int i = 0; i < N; i++) { float x = in[i]; float ref[8] = { floorf(x), floorf(x), sinf(x), fabsf(x), floorf(x - 0.5f) + 0.5f, ceilf(x), x - floorf(x), truncf(x) };
        for (int k = 0; k < 8; k++) { float d = fabsf(r[i * 8 + k] - ref[k]); float tol = k == 2 ? 2e-3f * fmaxf(1, fabsf(x) / 100) : 1e-4f * fmaxf(1, fabsf(ref[k]));
            if (!(d <= tol)) { if (bad < 30) printf("BAD %-16s x=%g gpu=%g cpu=%g\n", nm[k], x, r[i * 8 + k], ref[k]); bad++; } } }
    printf(bad ? "FAIL %d\n" : "PASS\n", bad); return bad != 0;
}}
