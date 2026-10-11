// selffetch: Core Animation's framebuffer-fetch emulation on a shared-VRAM IOSurface target - the fragment shader reads the
// render target (bound as texture 0, like CA's attachment_0) at its own pixel and blends a colour in, one quad per draw,
// quads overlapping each other, all in one encoder (plus a second encoder and a pipeline switch). The plugin serves a
// fragment function named fixed_frag_* with a barrier between draws and anything else with a copied shadow; both must
// match a CPU replay where every draw sees all earlier ones. Name the binary WindowServer for WindowServer's path.
// usage: selffetch [plugin] [W H]     SF_NAME=<fragment function name> (default fixed_frag_selftest)   SF_DUMP=<file>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurface.h>
#import <IOKit/IOKitLib.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
typedef struct { float r[4]; float col[4]; } U;   // r: x0 y0 x1 y1 in pixels
static uint8_t cv(float f) { f = f < 0 ? 0 : f > 1 ? 1 : f; return (uint8_t)(f * 255.f + 0.5f); }
int main(int argc, char **argv) { @autoreleasepool {
    id<MTLDevice> dev; int ai = 1, W = 3520, H = 1980;
    if (argc > 1 && strchr(argv[1], '/')) { if (!dlopen(argv[1], RTLD_NOW)) { printf("dlopen: %s\n", dlerror()); return 2; }
        io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"));
        dev = ((id (*)(id, SEL, mach_port_t))objc_msgSend)([objc_getClass("NVMTLDevice") alloc], sel_registerName("initWithAcceleratorPort:"), svc); ai = 2;
    } else dev = MTLCreateSystemDefaultDevice();
    if (argc > ai + 1) { W = atoi(argv[ai]); H = atoi(argv[ai + 1]); }
    NSString *fname = getenv("SF_NAME") ? @(getenv("SF_NAME")) : @"fixed_frag_selftest";
    NSString *src = [NSString stringWithFormat:@"#include <metal_stdlib>\nusing namespace metal;\n"
     "struct V { float4 p [[position]]; };\n"
     "struct U { float4 r; float4 col; };\n"
     "vertex V vs(uint i [[vertex_id]], constant U &u [[buffer(0)]], constant float2 &vp [[buffer(1)]]) {\n"
     "  float2 k = float2((i == 1 || i == 2 || i == 4) ? 1 : 0, (i == 2 || i == 4 || i == 5) ? 1 : 0);\n"
     "  float2 px = mix(u.r.xy, u.r.zw, k); V o; o.p = float4(px.x / vp.x * 2 - 1, 1 - px.y / vp.y * 2, 0, 1); return o; }\n"
     "fragment float4 %@(V v [[stage_in]], texture2d<float> attachment_0 [[texture(0)]], constant U &u [[buffer(0)]]) {\n"
     "  float4 d = attachment_0.read(uint2(v.p.xy)); return d * (1 - u.col.a) + float4(u.col.rgb, 1) * u.col.a; }\n"
     "fragment float4 fixed_frag_plain(V v [[stage_in]], constant U &u [[buffer(0)]]) { return float4(u.col.rgb, 1); }\n", fname];
    NSError *e = nil; id<MTLLibrary> lib = [dev newLibraryWithSource:src options:nil error:&e]; if (!lib) { printf("lib: %s\n", e.description.UTF8String); return 1; }
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new]; pd.vertexFunction = [lib newFunctionWithName:@"vs"];
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    pd.fragmentFunction = [lib newFunctionWithName:fname]; id<MTLRenderPipelineState> pf = [dev newRenderPipelineStateWithDescriptor:pd error:&e];
    pd.fragmentFunction = [lib newFunctionWithName:@"fixed_frag_plain"]; id<MTLRenderPipelineState> pp = [dev newRenderPipelineStateWithDescriptor:pd error:&e];
    if (!pf || !pp) { printf("pso: %s\n", e.description.UTF8String); return 1; }
    IOSurfaceRef s = IOSurfaceCreate((__bridge CFDictionaryRef)@{ (id)kIOSurfaceWidth: @(W), (id)kIOSurfaceHeight: @(H),
        (id)kIOSurfaceBytesPerElement: @4, (id)kIOSurfacePixelFormat: @((uint32_t)'BGRA') });
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:W height:H mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead; id<MTLTexture> t = [dev newTextureWithDescriptor:td iosurface:s plane:0];
    // steps: per encoder, quads; plain (non-sampling) quads in between, a full-screen sampling quad, overlapping placement
    enum { NE = 2, NK = 70 }; U st[NE][NK]; int plain[NE][NK]; srand(5);
    for (int n = 0; n < NE; n++) for (int k = 0; k < NK; k++) { U *u = &st[n][k];
        float w = 30 + rand() % 700, h = 20 + rand() % 400, x = rand() % (int)(W - w), y = rand() % (int)(H - h);
        if (k % 9 == 4) { x = 0; y = 0; w = W; h = H; }                                // full screen
        if (k > 0 && k % 5 == 2) { x = st[n][k - 1].r[0] + 10; y = st[n][k - 1].r[1] + 7; w = fminf(w, W - x); h = fminf(h, H - y); }   // over the previous quad
        u->r[0] = x; u->r[1] = y; u->r[2] = x + w; u->r[3] = y + h;
        for (int c = 0; c < 3; c++) u->col[c] = (float)(rand() % 256) / 255.f; u->col[3] = 0.25f + (float)(rand() % 128) / 255.f;
        plain[n][k] = (k % 7 == 6); }
    id<MTLCommandQueue> q = [dev newCommandQueue]; id<MTLCommandBuffer> cb = [q commandBuffer];
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor]; rp.colorAttachments[0].texture = t;
    rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].clearColor = MTLClearColorMake(0.2, 0.4, 0.6, 1);
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    const float vp[2] = { (float)W, (float)H };
    for (int n = 0; n < NE; n++) {
        id<MTLRenderCommandEncoder> en = [cb renderCommandEncoderWithDescriptor:rp]; rp.colorAttachments[0].loadAction = MTLLoadActionLoad;
        [en setRenderPipelineState:pf]; [en setFragmentTexture:t atIndex:0]; [en setVertexBytes:vp length:sizeof vp atIndex:1];
        [en setScissorRect:(MTLScissorRect){ 0, 0, (NSUInteger)W, (NSUInteger)H }];
        for (int k = 0; k < NK; k++) {
            [en setRenderPipelineState:plain[n][k] ? pp : pf];
            [en setVertexBytes:&st[n][k] length:sizeof(U) atIndex:0]; [en setFragmentBytes:&st[n][k] length:sizeof(U) atIndex:0];
            [en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6]; }
        [en endEncoding];
    }
    [cb commit]; [cb waitUntilCompleted]; const double gms = (cb.GPUEndTime - cb.GPUStartTime) * 1e3;
    uint8_t *g = malloc((size_t)W * H * 4); [t getBytes:g bytesPerRow:(NSUInteger)W * 4 fromRegion:MTLRegionMake2D(0, 0, (NSUInteger)W, (NSUInteger)H) mipmapLevel:0];
    // CPU replay: pixel centres inside the quad (top-left fill rule is irrelevant for integer-aligned rects)
    uint8_t *a = malloc((size_t)W * H * 4);
    for (size_t i = 0; i < (size_t)W * H; i++) { a[i * 4 + 0] = cv(0.6f); a[i * 4 + 1] = cv(0.4f); a[i * 4 + 2] = cv(0.2f); a[i * 4 + 3] = 255; }
    for (int n = 0; n < NE; n++) for (int k = 0; k < NK; k++) { U *u = &st[n][k]; const float al = plain[n][k] ? 1.f : u->col[3];
        for (int y = (int)u->r[1]; y < (int)u->r[3]; y++) for (int x = (int)u->r[0]; x < (int)u->r[2]; x++) { uint8_t *o = a + ((size_t)y * W + x) * 4;
            o[2] = cv(o[2] / 255.f * (1 - al) + u->col[0] * al); o[1] = cv(o[1] / 255.f * (1 - al) + u->col[1] * al);
            o[0] = cv(o[0] / 255.f * (1 - al) + u->col[2] * al); o[3] = cv(o[3] / 255.f * (1 - al) + al); } }
    long bad = 0; int worst = 0;
    for (size_t i = 0; i < (size_t)W * H * 4; i++) { int d = abs(g[i] - a[i]); if (d > worst) worst = d; if (d > 3) bad++; }
    if (getenv("SF_DUMP")) { FILE *f = fopen(getenv("SF_DUMP"), "wb"); fwrite(g, 1, (size_t)W * H * 4, f); fclose(f); }
    printf("selffetch %dx%d (%s, fs %s): %ld bytes off the CPU replay (max diff %d), GPU %.2f ms  %s\n", W, H, getprogname(), fname.UTF8String,
           bad, worst, gms, bad ? "FAIL" : "PASS");
    return bad ? 1 : 0;
}}
