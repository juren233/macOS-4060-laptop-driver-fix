// selfrect: the self-bind guard (a render pass that samples its own shared-VRAM IOSurface target) with scissored draws.
// Every draw reads the target at an offset - often outside its own scissor - and blends a colour in, so each draw sees what
// all earlier draws wrote anywhere: a stale region in the guard's shadow shows up as a mismatch against a CPU replay.
// Covers: overlapping / touching / disjoint rects, more than 8 rects, draws with no scissor, rebinding another texture and
// back mid-encoder, and a second encoder. Name the binary WindowServer to get WindowServer's path (no tiled render shadow).
// usage: selfrect [plugin] [W H]    SR_DUMP=<file> writes the final surface bytes
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurface.h>
#import <IOKit/IOKitLib.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
static NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
 "struct V { float4 p [[position]]; };\n"
 "struct U { int2 off; float4 col; };\n"
 "vertex V vs(uint i [[vertex_id]]) { float2 q = float2((i << 1) & 2, i & 2); V o; o.p = float4(q * 2 - 1, 0, 1); return o; }\n"
 "fragment float4 grad(V v [[stage_in]]) { uint2 p = uint2(v.p.xy); return float4(float(p.x & 255) / 255, float(p.y & 255) / 255, float((p.x ^ p.y) & 255) / 255, 1); }\n"
 "fragment float4 fb(V v [[stage_in]], texture2d<float> t [[texture(0)]], constant U &u [[buffer(0)]]) {\n"
 "  int2 p = clamp(int2(v.p.xy) + u.off, int2(0), int2(t.get_width() - 1, t.get_height() - 1));\n"
 "  return t.read(uint2(p)) * 0.75 + u.col * 0.25; }\n";
typedef struct { int ox, oy; float pad[2]; float col[4]; } U;
typedef struct { int sc; uint32_t x, y, w, h; int ox, oy; float col[4]; int rebind; } Step;   // sc 0: no setScissorRect
static int W = 2600, H = 1500;
static uint8_t cv(float f) { f = f < 0 ? 0 : f > 1 ? 1 : f; return (uint8_t)(f * 255.f + 0.5f); }
int main(int argc, char **argv) { @autoreleasepool {
    id<MTLDevice> dev; int ai = 1;
    if (argc > 1 && strchr(argv[1], '/')) { if (!dlopen(argv[1], RTLD_NOW)) { printf("dlopen: %s\n", dlerror()); return 2; }
        io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"));
        dev = ((id (*)(id, SEL, mach_port_t))objc_msgSend)([objc_getClass("NVMTLDevice") alloc], sel_registerName("initWithAcceleratorPort:"), svc); ai = 2;
    } else dev = MTLCreateSystemDefaultDevice();
    if (argc > ai + 1) { W = atoi(argv[ai]); H = atoi(argv[ai + 1]); }
    NSError *e = nil; id<MTLLibrary> lib = [dev newLibraryWithSource:src options:nil error:&e]; if (!lib) { printf("lib: %s\n", e.description.UTF8String); return 1; }
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new]; pd.vertexFunction = [lib newFunctionWithName:@"vs"];
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    pd.fragmentFunction = [lib newFunctionWithName:@"grad"]; id<MTLRenderPipelineState> pg = [dev newRenderPipelineStateWithDescriptor:pd error:&e];
    pd.fragmentFunction = [lib newFunctionWithName:@"fb"]; id<MTLRenderPipelineState> pf = [dev newRenderPipelineStateWithDescriptor:pd error:&e];
    if (!pg || !pf) { printf("pso: %s\n", e.description.UTF8String); return 1; }
    IOSurfaceRef s = IOSurfaceCreate((__bridge CFDictionaryRef)@{ (id)kIOSurfaceWidth: @(W), (id)kIOSurfaceHeight: @(H),
        (id)kIOSurfaceBytesPerElement: @4, (id)kIOSurfacePixelFormat: @((uint32_t)'BGRA') });
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:W height:H mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead; id<MTLTexture> t = [dev newTextureWithDescriptor:td iosurface:s plane:0];
    MTLTextureDescriptor *od = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:16 height:16 mipmapped:NO];
    od.usage = MTLTextureUsageShaderRead; id<MTLTexture> other = [dev newTextureWithDescriptor:od];
    // the steps: two encoders of sampling draws
    Step st[2][64]; int ns[2] = { 0, 0 }; srand(11);
    const int NK = getenv("SR_N") ? atoi(getenv("SR_N")) : 44, NE = getenv("SR_E") ? atoi(getenv("SR_E")) : 2;
    for (int en = 0; en < 2; en++) for (int k = 0; k < 44; k++) {
        Step *p = &st[en][ns[en]++]; memset(p, 0, sizeof *p);
        p->sc = !(k == 0 && en == 1) && k != 17;                        // encoder 2 starts with no scissor; draw 17 resets to the whole target
        p->w = 40 + (uint32_t)(rand() % 500); p->h = 30 + (uint32_t)(rand() % 300);
        p->x = (uint32_t)(rand() % (W - (int)p->w)); p->y = (uint32_t)(rand() % (H - (int)p->h));
        if (k % 7 == 3) { p->x = st[en][ns[en] - 2].x + st[en][ns[en] - 2].w; p->y = st[en][ns[en] - 2].y;   // touching the previous rect
            if (p->x + p->w > (uint32_t)W) p->x = st[en][ns[en] - 2].x - p->w;                              // (on its left when no room)
            if (p->y + p->h > (uint32_t)H) p->y = (uint32_t)H - p->h; }
        if (k % 11 == 5) { p->x = (uint32_t)W - p->w; p->y = (uint32_t)H - p->h; }                           // flush with the far edges
        if (k == 30) { p->x = 0; p->y = 0; p->w = (uint32_t)W; p->h = (uint32_t)H; }                         // full-size scissor
        p->ox = (rand() % 1201) - 600; p->oy = (rand() % 801) - 400;
        for (int c = 0; c < 3; c++) p->col[c] = (float)(rand() % 256) / 255.f; p->col[3] = 1;
        p->rebind = (k == 22);                                         // bind another texture and the target again before this draw
    }
    for (int en = 0; en < 2; en++) ns[en] = en < NE ? (NK < ns[en] ? NK : ns[en]) : 0;   // SR_E / SR_N: run a prefix (bisecting)
    // GPU
    id<MTLCommandQueue> q = [dev newCommandQueue]; id<MTLCommandBuffer> cb = [q commandBuffer];
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor]; rp.colorAttachments[0].texture = t;
    rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> en = [cb renderCommandEncoderWithDescriptor:rp];
    [en setRenderPipelineState:pg]; [en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [en endEncoding];
    rp.colorAttachments[0].loadAction = MTLLoadActionLoad;
    for (int n = 0; n < 2; n++) {
        en = [cb renderCommandEncoderWithDescriptor:rp]; [en setRenderPipelineState:pf]; [en setFragmentTexture:t atIndex:0];
        for (int k = 0; k < ns[n]; k++) { Step *p = &st[n][k];
            if (p->rebind) { [en setFragmentTexture:other atIndex:0]; [en setFragmentTexture:t atIndex:0]; }
            if (p->sc) [en setScissorRect:(MTLScissorRect){ p->x, p->y, p->w, p->h }];
            else if (k) [en setScissorRect:(MTLScissorRect){ 0, 0, (NSUInteger)W, (NSUInteger)H }];
            U u = { p->ox, p->oy, { 0, 0 }, { p->col[0], p->col[1], p->col[2], p->col[3] } }; [en setFragmentBytes:&u length:sizeof u atIndex:0];
            [en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; }
        [en endEncoding];
    }
    [cb commit]; [cb waitUntilCompleted]; const double gms = (cb.GPUEndTime - cb.GPUStartTime) * 1e3;
    uint8_t *g = malloc((size_t)W * H * 4); [t getBytes:g bytesPerRow:(NSUInteger)W * 4 fromRegion:MTLRegionMake2D(0, 0, (NSUInteger)W, (NSUInteger)H) mipmapLevel:0];
    // CPU replay (BGRA bytes; colours are RGBA)
    uint8_t *a = malloc((size_t)W * H * 4), *b = malloc((size_t)W * H * 4);
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) { uint8_t *o = a + ((size_t)y * W + x) * 4;
        o[2] = (uint8_t)(x & 255); o[1] = (uint8_t)(y & 255); o[0] = (uint8_t)((x ^ y) & 255); o[3] = 255; }
    for (int n = 0; n < 2; n++) for (int k = 0; k < ns[n]; k++) { Step *p = &st[n][k];
        const uint32_t x0 = p->sc ? p->x : 0, y0 = p->sc ? p->y : 0, x1 = p->sc ? p->x + p->w : (uint32_t)W, y1 = p->sc ? p->y + p->h : (uint32_t)H;
        memcpy(b, a, (size_t)W * H * 4);
        for (uint32_t y = y0; y < y1; y++) for (uint32_t x = x0; x < x1; x++) {
            int sx = (int)x + p->ox, sy = (int)y + p->oy; sx = sx < 0 ? 0 : sx >= W ? W - 1 : sx; sy = sy < 0 ? 0 : sy >= H ? H - 1 : sy;
            const uint8_t *i = a + ((size_t)sy * W + sx) * 4; uint8_t *o = b + ((size_t)y * W + x) * 4;
            o[2] = cv(i[2] / 255.f * .75f + p->col[0] * .25f); o[1] = cv(i[1] / 255.f * .75f + p->col[1] * .25f);
            o[0] = cv(i[0] / 255.f * .75f + p->col[2] * .25f); o[3] = cv(i[3] / 255.f * .75f + p->col[3] * .25f); }
        uint8_t *x = a; a = b; b = x; }
    long bad = 0; int worst = 0, bx0 = W, by0 = H, bx1 = -1, by1 = -1;
    for (size_t i = 0; i < (size_t)W * H * 4; i++) { int d = abs(g[i] - a[i]); if (d > worst) worst = d;
        if (d > 6) { bad++; const int px = (int)(i / 4 % (size_t)W), py = (int)(i / 4 / (size_t)W);
            bx0 = px < bx0 ? px : bx0; by0 = py < by0 ? py : by0; bx1 = px > bx1 ? px : bx1; by1 = py > by1 ? py : by1; } }
    if (bad) printf("  mismatches inside x %d..%d y %d..%d\n", bx0, bx1, by0, by1);
    if (bad && getenv("SR_WHY")) for (int n = 0; n < 2; n++) for (int k = 0; k < ns[n]; k++) { Step *p = &st[n][k];
        const int x0 = p->sc ? (int)p->x : 0, y0 = p->sc ? (int)p->y : 0, x1 = p->sc ? (int)(p->x + p->w) : W, y1 = p->sc ? (int)(p->y + p->h) : H;
        if (x0 <= bx1 && bx0 < x1 && y0 <= by1 && by0 < y1) printf("  enc %d draw %d sc %d rect %d,%d %dx%d off %d,%d rebind %d\n", n, k, p->sc, x0, y0, x1 - x0, y1 - y0, p->ox, p->oy, p->rebind); }
    uint64_t hsh = 1469598103934665603ull; for (size_t i = 0; i < (size_t)W * H * 4; i++) hsh = (hsh ^ g[i]) * 1099511628211ull;
    if (getenv("SR_DUMP")) { FILE *f = fopen(getenv("SR_DUMP"), "wb"); fwrite(g, 1, (size_t)W * H * 4, f); fclose(f); }
    printf("selfrect %dx%d (%s): %ld bytes off the CPU replay (max diff %d), hash %016llx, GPU %.2f ms  %s\n", W, H, getprogname(), bad, worst,
           (unsigned long long)hsh, gms, bad ? "FAIL" : "PASS");
    return bad ? 1 : 0;
}}
