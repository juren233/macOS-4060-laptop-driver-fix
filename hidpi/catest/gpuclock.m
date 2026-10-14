// gpuclock: is the GPU running at full clock? FP32 FMA throughput and VRAM copy bandwidth through the installed plugin + NVK.
//   gpuclock <plugin> <vulkan-icd> [SECONDS]
// RTX 4060 Laptop (24 SMs x 128 lanes, 2 FLOP per FMA): ~6.1 TFLOPS per GHz of GPC clock, so 2.37 GHz boost ~ 14.6 TFLOPS;
// 128-bit GDDR6 at 16 Gbps = 256 GB/s. Each test runs for SECONDS (default 3) so the clocks have time to ramp up.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOKit/IOKitLib.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#include <mach/mach_time.h>
static NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
"kernel void fma_k(device float4 *o [[buffer(0)]], constant uint &n [[buffer(1)]], uint i [[thread_position_in_grid]]) {\n"
"  float4 a = float4(i * 1e-9) + float4(1.0001, 0.9999, 1.0, 1.0002), b = a + 0.5, c = a + 0.25, d = a + 0.125; const float4 m = float4(0.99999), k = float4(1e-6);\n"
"  for (uint j = 0; j < n; j++) { a = fma(a, m, k); b = fma(b, m, k); c = fma(c, m, k); d = fma(d, m, k);\n"
"    a = fma(a, m, k); b = fma(b, m, k); c = fma(c, m, k); d = fma(d, m, k); }\n"
"  o[i] = a + b + c + d; }\n"
"kernel void copy_k(device const float4 *s [[buffer(0)]], device float4 *d [[buffer(1)]], uint i [[thread_position_in_grid]]) { d[i] = s[i]; }\n";
static double now_s(void) { static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb); return mach_absolute_time() * (double)tb.numer / tb.denom / 1e9; }
int main(int argc, char **argv) { @autoreleasepool {
  if (argc < 3) { printf("usage: gpuclock <plugin> <icd> [SECONDS]\n"); return 2; }
  if (!dlopen(argv[1], RTLD_NOW)) { printf("dlopen: %s\n", dlerror()); return 2; }
  setenv("NVMTL_ICD_LIB", argv[2], 1);
  // PP_<NAME>=v is set as <NAME>=v after the plugin loaded (the release plugin unsets NVRM_* / NVK_* / NVMTL_* / NAK_* at load)
  { extern char **environ; char *set[32]; int n = 0; for (char **e = environ; *e && n < 32; e++) if (!strncmp(*e, "PP_", 3)) set[n++] = strdup(*e + 3);
    for (int i = 0; i < n; i++) { char *eq = strchr(set[i], '='); if (eq) { *eq = 0; setenv(set[i], eq + 1, 1); } } }
  const double S = argc > 3 ? atof(argv[3]) : 3;
  io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"));
  id<MTLDevice> dev = ((id (*)(id, SEL, mach_port_t))objc_msgSend)([objc_getClass("NVMTLDevice") alloc], sel_registerName("initWithAcceleratorPort:"), svc);
  if (!dev) { printf("no device\n"); return 1; }
  NSError *e = nil; id<MTLLibrary> lib = [dev newLibraryWithSource:src options:nil error:&e]; if (!lib) { printf("lib %s\n", e.localizedDescription.UTF8String); return 1; }
  id<MTLComputePipelineState> pf = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"fma_k"] error:&e];
  id<MTLComputePipelineState> pc = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"copy_k"] error:&e];
  if (!pf || !pc) { printf("pso %s\n", e.localizedDescription.UTF8String); return 1; }
  id<MTLCommandQueue> q = [dev newCommandQueue];
  const NSUInteger T = 24 * 128 * 64; const uint32_t N = 4096;                         // 196608 threads, 4 float4 chains x 2 FMA x N
  id<MTLBuffer> out = [dev newBufferWithLength:T * 16 options:MTLResourceStorageModePrivate];
  const NSUInteger B = 256u << 20;                                                       // 256 MB each way
  id<MTLBuffer> s = [dev newBufferWithLength:B options:MTLResourceStorageModePrivate], d = [dev newBufferWithLength:B options:MTLResourceStorageModePrivate];
  double (^run)(int) = ^double(int which) {
    double best = 1e9, t0 = now_s(); int n = 0;
    while (now_s() - t0 < S || n < 3) { @autoreleasepool {
      id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
      if (which == 0) { [ce setComputePipelineState:pf]; [ce setBuffer:out offset:0 atIndex:0]; [ce setBytes:&N length:4 atIndex:1];
        [ce dispatchThreads:MTLSizeMake(T, 1, 1) threadsPerThreadgroup:MTLSizeMake(256, 1, 1)]; }
      else { [ce setComputePipelineState:pc]; [ce setBuffer:s offset:0 atIndex:0]; [ce setBuffer:d offset:0 atIndex:1];
        [ce dispatchThreads:MTLSizeMake(B / 16, 1, 1) threadsPerThreadgroup:MTLSizeMake(256, 1, 1)]; }
      [ce endEncoding]; const double a = now_s(); [cb commit]; [cb waitUntilCompleted]; const double dt = now_s() - a; n++;
      if (dt < best) best = dt; } }
    return best; };
  const double tf = run(0), tc = run(1);
  const double flops = (double)T * 4 * 4 * 2 * N * 2;   // threads x float4 chains x lanes x 2 FMA per loop x N x 2 FLOP
  printf("gpuclock: FMA %.2f ms -> %.2f TFLOPS (~%.2f GHz GPC clock if all 24 SMs run) | copy %.2f ms -> %.0f GB/s (256 GB/s = full memory clock)\n",
         tf * 1e3, flops / tf / 1e12, flops / tf / 1e12 / 6.144, tc * 1e3, 2.0 * B / tc / 1e9);
  return 0; } }
