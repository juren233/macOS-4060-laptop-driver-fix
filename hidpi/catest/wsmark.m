#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurface.h>
#include <mach/mach_time.h>
#include <objc/message.h>
#include <sys/sysctl.h>
// wsmark capture|swap|fps : the plugin side of NullMoth 79f47d0 / e75be1e / 40daaa6 (NVAccel nvSurfGpuEscape + page-off wait).
// Run it from a file NAMED "WindowServer" (cp wsmark <dir>/WindowServer): NVAccel takes marks only from a process whose
// p_comm is WindowServer, and the plugin marks only when getprogname() is WindowServer. Every mode prints the change of
// debug.nvaccel_surface_gpu_marks / _waits / _timeouts it caused.
//  capture: 24 frames, each renders a distinct colour (~5 ms of fragment work) into an IOSurface texture, commits, and at once
//           takes a normal read-only IOSurfaceLock and reads the pixels - a window capture locking a surface WindowServer is
//           still drawing (SkyLight do_finish_and_clear_capture_state). Apple's lock waits for the GPU; so must ours:
//           every frame must read its own colour. PASS = 24/24 (a build without the marks reads zeros / the previous frame).
//  swap:    WindowServer's commitAndWaitUntilSubmitted on that ~5 ms composite: with the kernel waiting for the swap it returns
//           before the GPU finishes (e75be1e); without, it waits for completion. Prints how many of 10 had completed.
//  fps:     a compositor loop for 3 s: 3 surfaces in rotation, ~1.5 ms composite each + commitAndWaitUntilSubmitted, a CPU
//           read of the frame two back (as a capture would); prints frames/s and how many reads were wrong (must be 0).
static NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\nstruct VOut { float4 pos [[position]]; };\n"
"vertex VOut vs(uint vid [[vertex_id]]) { float2 q[3] = { float2(-1,-1), float2(3,-1), float2(-1,3) }; VOut o; o.pos = float4(q[vid],0,1); return o; }\n"
"fragment float4 fs(VOut in [[stage_in]], constant float4 &c [[buffer(0)]], constant int &n [[buffer(1)]]) {\n"
"  float a = 0.1; float2 u = in.pos.xy * 0.001; for (int i = 0; i < n; i++) a = fract(sin(a + u.x) * 43758.5 + u.y);\n"
"  return a > 5.0 ? float4(0) : c; }\n";
static double now_ms(void) { static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb); return mach_absolute_time() * (double)tb.numer / tb.denom / 1e6; }
static long long ctl(const char *n) { long long v = 0; size_t l = sizeof v; if (sysctlbyname(n, &v, &l, NULL, 0)) return -1; return l == 4 ? (long long)*(int *)&v : v; }
typedef struct { long long marks, waits, timeouts; } cnt;
static cnt cnow(void) { return (cnt){ ctl("debug.nvaccel_surface_gpu_marks"), ctl("debug.nvaccel_surface_gpu_waits"), ctl("debug.nvaccel_surface_gpu_timeouts") }; }
static IOSurfaceRef mksurf(int W, int H) {
  return IOSurfaceCreate((__bridge CFDictionaryRef)@{ (id)kIOSurfaceWidth: @(W), (id)kIOSurfaceHeight: @(H), (id)kIOSurfaceBytesPerElement: @4,
                                                      (id)kIOSurfacePixelFormat: @(0x42475241) });
}
static uint32_t px(IOSurfaceRef s, int x, int y) { return ((uint32_t *)((uint8_t *)IOSurfaceGetBaseAddress(s) + (size_t)y * IOSurfaceGetBytesPerRow(s)))[x]; }
// colour of frame i, exact in 8 bits; BGRA in memory = 0xAARRGGBB
static uint32_t colour(int i, float c[4]) {
  const int r = (37 * i + 20) % 250 + 3, g = (91 * i + 7) % 250 + 3, b = (53 * i + 101) % 250 + 3;
  c[0] = r / 255.f; c[1] = g / 255.f; c[2] = b / 255.f; c[3] = 1;
  return 0xff000000u | (uint32_t)r << 16 | (uint32_t)g << 8 | (uint32_t)b;
}
int main(int argc, char **argv) { @autoreleasepool {
  const char *mode = argc > 1 ? argv[1] : "capture";
  id<MTLDevice> dev = MTLCreateSystemDefaultDevice(); NSError *e = nil;
  if (!dev) { printf("wsmark %s: FAIL no device\n", mode); return 1; }
  id<MTLLibrary> lib = [dev newLibraryWithSource:src options:nil error:&e];
  if (!lib) { printf("wsmark %s: FAIL lib %s\n", mode, e.localizedDescription.UTF8String); return 1; }
  MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new]; pd.vertexFunction = [lib newFunctionWithName:@"vs"]; pd.fragmentFunction = [lib newFunctionWithName:@"fs"];
  pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
  id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:pd error:&e];
  if (!ps) { printf("wsmark %s: FAIL pipeline %s\n", mode, e.localizedDescription.UTF8String); return 1; }
  id<MTLCommandQueue> q = [dev newCommandQueue];
  // WSMARK_ITERS=<n>: fragment loop length (default 400, fps 100) - 12000 makes one capture frame ~150 ms, past NVAccel's 100 ms bound
  const char *ie = getenv("WSMARK_ITERS");
  const int fps = !strcmp(mode, "fps"), W = fps ? 2048 : 3200, H = fps ? 1152 : 1600, NS = fps ? 3 : 1, iters = ie ? atoi(ie) : fps ? 100 : 400;
  IOSurfaceRef s[3]; NSMutableArray<id<MTLTexture>> *t = [NSMutableArray new];
  for (int k = 0; k < NS; k++) {
    s[k] = mksurf(W, H);
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:W height:H mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead; td.storageMode = MTLStorageModeManaged;
    [t addObject:[dev newTextureWithDescriptor:td iosurface:s[k] plane:0]];
  }
  id<MTLCommandBuffer> (^frame)(int, int) = ^id<MTLCommandBuffer>(int k, int i) {
    float c[4]; colour(i, c); int n = iters;
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor]; rp.colorAttachments[0].texture = t[k];
    rp.colorAttachments[0].loadAction = MTLLoadActionDontCare; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
    [re setRenderPipelineState:ps]; [re setFragmentBytes:c length:sizeof c atIndex:0]; [re setFragmentBytes:&n length:sizeof n atIndex:1];
    [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [re endEncoding];
    return cb;
  };
  // the very first frame compiles and maps; keep it out of every count
  { id<MTLCommandBuffer> cb = frame(0, 999); [cb commit]; [cb waitUntilCompleted]; }
  const cnt c0 = cnow();
  int bad = 0, racing = 0, total = 0; double ms = 0;
  if (!strcmp(mode, "capture")) {
    total = 24;
    for (int i = 0; i < total; i++) {
      float c[4]; const uint32_t want = colour(i, c);
      id<MTLCommandBuffer> cb = frame(0, i); [cb commit];
      racing += cb.status != MTLCommandBufferStatusCompleted;
      uint32_t seed = 0;
      if (IOSurfaceLock(s[0], kIOSurfaceLockReadOnly, &seed)) { bad++; continue; }
      const uint32_t a = px(s[0], W / 2, H / 2), b = px(s[0], 3, H - 4), d = px(s[0], W - 2, 1);
      IOSurfaceUnlock(s[0], kIOSurfaceLockReadOnly, &seed);
      if (a != want || b != want || d != want) { if (bad < 4) printf("  frame %d: want %08x read %08x %08x %08x\n", i, want, a, b, d); bad++; }
      [cb waitUntilCompleted];
    }
  } else if (!strcmp(mode, "swap")) {
    total = 10;
    for (int i = 0; i < total; i++) {
      id<MTLCommandBuffer> cb = frame(0, i);
      const double t0 = now_ms(); ((BOOL (*)(id, SEL))objc_msgSend)(cb, sel_registerName("commitAndWaitUntilSubmitted")); ms += now_ms() - t0;
      bad += cb.status == MTLCommandBufferStatusCompleted;
      [cb waitUntilCompleted];
      if (cb.status != MTLCommandBufferStatusCompleted) { printf("wsmark swap: FAIL command buffer error\n"); return 1; }
    }
  } else if (fps) {
    const double t0 = now_ms(); int i = 0;
    id<MTLCommandBuffer> prev[3] = { nil, nil, nil };
    while (now_ms() - t0 < 3000 && i < 2000) {
      const int k = i % 3;
      if (prev[k]) [prev[k] waitUntilCompleted];   // a surface is redrawn only after the swap that showed it
      prev[k] = frame(k, i);
      ((BOOL (*)(id, SEL))objc_msgSend)(prev[k], sel_registerName("commitAndWaitUntilSubmitted"));
      if (i >= 2) {   // the frame two back, as a capture would read it
        const int j = i - 2, kj = j % 3; float c[4]; const uint32_t want = colour(j, c); uint32_t seed = 0;
        if (!IOSurfaceLock(s[kj], kIOSurfaceLockReadOnly, &seed)) {
          const uint32_t a = px(s[kj], W / 2, H / 2); IOSurfaceUnlock(s[kj], kIOSurfaceLockReadOnly, &seed);
          if (a != want) { if (bad < 4) printf("  frame %d: want %08x read %08x\n", j, want, a); bad++; }
        } else bad++;
        total++;
      }
      i++;
    }
    for (int k = 0; k < 3; k++) [prev[k] waitUntilCompleted];
    ms = now_ms() - t0; racing = i;
  } else { printf("usage: wsmark capture|swap|fps\n"); return 2; }
  const cnt c1 = cnow();
  printf("kernel: marks +%lld waits +%lld timeouts +%lld\n", c1.marks - c0.marks, c1.waits - c0.waits, c1.timeouts - c0.timeouts);
  if (!strcmp(mode, "capture"))
    printf("wsmark capture: %d of %d locks raced the GPU, %d read the wrong pixels -> %s\n", racing, total, bad, bad ? "FAIL" : "PASS");
  else if (!strcmp(mode, "swap"))
    printf("wsmark swap: %d of %d completed when commitAndWaitUntilSubmitted returned, %.2f ms per call\n", bad, total, ms / total);
  else
    printf("wsmark fps: %.1f frames/s, %d of %d reads wrong -> %s\n", racing * 1000.0 / ms, bad, total, bad ? "FAIL" : "PASS");
  for (int k = 0; k < NS; k++) CFRelease(s[k]);
  return bad && strcmp(mode, "swap") ? 1 : 0; } }
