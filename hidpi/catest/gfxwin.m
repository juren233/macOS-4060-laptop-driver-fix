// gfxwin: a real window composited by WindowServer. Three IOSurfaces rotate as layer contents; each frame copies the previous
// surface and redraws only a moving bar (erase old, draw new). Exactly ONE bar must be visible; several bars or a bar cut in
// two means WindowServer showed old / half-written content. Usage: gfxwin [small|large] [seconds]
#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <IOSurface/IOSurface.h>
#import <CoreVideo/CoreVideo.h>
static NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
"struct V { float4 p [[position]]; };\n"
"vertex V vq(uint i [[vertex_id]], constant float4 &g [[buffer(0)]]) { float2 p[4] = { float2(0,0), float2(1,0), float2(0,1), float2(1,1) };\n"
"  V o; o.p = float4((g.xy + p[i] * g.zw) * 2 - 1, 0, 1); o.p.y = -o.p.y; return o; }\n"
"fragment float4 fcopy(V in [[stage_in]], texture2d<float> t [[texture(0)]]) { constexpr sampler s(filter::nearest, coord::pixel); return t.sample(s, in.p.xy); }\n"
"fragment float4 fbg(V in [[stage_in]]) { int2 c = int2(in.p.xy) / 64; float g = ((c.x + c.y) & 1) ? 0.22 : 0.30; return float4(g, g, g + 0.05, 1); }\n"
"fragment float4 fbar(V in [[stage_in]]) { return float4(1.0, 0.1, 0.1, 1); }\n";
static id<MTLDevice> dev; static id<MTLCommandQueue> q; static id<MTLRenderPipelineState> pcopy, pbg, pbar;
static IOSurfaceRef sf[3]; static int W, H, frame, barx[3]; static NSView *view; static CALayer *cl; static int stopAt, cpuMode; static double t0;
static id<MTLTexture> tex(IOSurfaceRef s, MTLTextureUsage u) {
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:W height:H mipmapped:NO];
    td.usage = u; td.storageMode = MTLStorageModeManaged; return [dev newTextureWithDescriptor:td iosurface:s plane:0];
}
static void rect(id<MTLRenderCommandEncoder> re, id<MTLRenderPipelineState> p, float x, float y, float w, float h) {
    float g[4] = { x / W, y / H, w / W, h / H }; [re setRenderPipelineState:p]; [re setVertexBytes:g length:16 atIndex:0]; [re drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
}
static int skipped;
static void tick(void) {
    static int n; if (++n % 120 == 0) NSLog(@"gfxwin: tick %d, frames drawn %d, skipped(in use) %d, layer contents %@, layer frame %@", n, frame, skipped, cl.contents ? @"set" : @"nil", NSStringFromRect(cl.frame));
    int b = frame % 3, pv = (frame + 2) % 3; const int BW = 48;
    if (getenv("GFXWIN_NOC")) return;
    if (CFAbsoluteTimeGetCurrent() - t0 > stopAt / 60.0) { [NSApp terminate:nil]; return; }
    if (!cpuMode && IOSurfaceIsInUse(sf[b])) { skipped++; return; }            // as Chromium's buffer queue: never reuse a surface still referenced
    int nx = (barx[pv] + 37) % (W - BW); if (frame == 0) nx = 100;
    if (cpuMode) {
        // Chromium's software output device: copy the previous buffer, then repaint only the damage (old bar + new bar).
        const int partial = getenv("GFXWIN_PARTIAL") != NULL;
        IOSurfaceLock(sf[b], 0, NULL); uint8_t *p = IOSurfaceGetBaseAddress(sf[b]); size_t row = IOSurfaceGetBytesPerRow(sf[b]);
        if (partial && frame) { IOSurfaceLock(sf[pv], kIOSurfaceLockReadOnly, NULL); memcpy(p, IOSurfaceGetBaseAddress(sf[pv]), row * H); IOSurfaceUnlock(sf[pv], kIOSurfaceLockReadOnly, NULL); }
        int x0 = 0, x1 = W;   // columns to repaint
        if (partial && frame) { int a = barx[pv], c = nx; x0 = a < c ? a : c; x1 = (a < c ? c : a) + BW; }
        for (int y = 0; y < H; y++) { uint32_t *r = (uint32_t *)(p + (size_t)y * row);
            for (int x = x0; x < x1 && x < W; x++) { uint32_t g = (((x / 64) + (y / 64)) & 1) ? 0x38 : 0x4C; r[x] = (x >= nx && x < nx + BW) ? 0xFFE61A1Au : (0xFF000000u | g << 16 | g << 8 | (g + 12)); } }
        IOSurfaceUnlock(sf[b], 0, NULL); barx[b] = nx;
        [CATransaction begin]; [CATransaction setDisableActions:YES]; cl.contents = (__bridge id)sf[b]; [CATransaction commit]; frame++; return;
    }
    id<MTLTexture> cur = tex(sf[b], MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead); id<MTLTexture> prev = frame ? tex(sf[pv], MTLTextureUsageShaderRead) : nil;
    id<MTLCommandBuffer> cb = [q commandBuffer]; MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = cur; rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
    if (prev) { [re setFragmentTexture:prev atIndex:0]; rect(re, pcopy, 0, 0, W, H); rect(re, pbg, barx[pv], 0, BW, H); }   // copy + erase the old bar
    else rect(re, pbg, 0, 0, W, H);
    rect(re, pbar, nx, 0, BW, H);
    [re endEncoding]; [cb commit]; [cb waitUntilScheduled];
    barx[b] = nx;
    [CATransaction begin]; [CATransaction setDisableActions:YES]; cl.contents = (__bridge id)sf[b]; [CATransaction commit];
    frame++;
}
int main(int argc, char **argv) { @autoreleasepool {
    BOOL small = argc > 1 && !strcmp(argv[1], "small"); cpuMode = argc > 3 && !strcmp(argv[3], "cpu"); int secs = argc > 2 ? atoi(argv[2]) : 60;
    [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    dev = MTLCreateSystemDefaultDevice(); q = [dev newCommandQueue]; NSError *e; id<MTLLibrary> lib = [dev newLibraryWithSource:src options:nil error:&e]; if (!lib) { NSLog(@"lib %@", e); return 1; }
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new]; d.vertexFunction = [lib newFunctionWithName:@"vq"]; d.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    d.fragmentFunction = [lib newFunctionWithName:@"fcopy"]; pcopy = [dev newRenderPipelineStateWithDescriptor:d error:&e];
    d.fragmentFunction = [lib newFunctionWithName:@"fbg"]; pbg = [dev newRenderPipelineStateWithDescriptor:d error:&e];
    d.fragmentFunction = [lib newFunctionWithName:@"fbar"]; pbar = [dev newRenderPipelineStateWithDescriptor:d error:&e];
    NSRect fr = small ? NSMakeRect(60, 120, 900, 560) : NSMakeRect(60, 80, 1600, 850); W = (int)fr.size.width * 2; H = (int)fr.size.height * 2;
    NSWindow *w = [[NSWindow alloc] initWithContentRect:fr styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
    w.title = [NSString stringWithFormat:@"gfxwin %s | %s | %s", small ? "small" : "large", cpuMode ? (getenv("GFXWIN_PARTIAL") ? "CPU-partial-update" : "CPU-full-update") : "GPU-drawn", getenv("GFXWIN_CV") ? "CVPixelBuffer surfaces" : "IOSurfaceCreate surfaces"]; view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, fr.size.width, fr.size.height)]; view.layer = [CALayer layer]; view.wantsLayer = YES; view.layer.contentsScale = 2; view.layer.contentsGravity = kCAGravityResize;
    cl = [CALayer layer]; cl.frame = view.bounds; if (getenv("GFXWIN_BG")) cl.backgroundColor = CGColorCreateGenericRGB(0, 0.6, 0, 1); cl.contentsScale = 2; cl.contentsGravity = kCAGravityResize; [view.layer addSublayer:cl];
    w.contentView = view; [w makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES];
    for (int i = 0; i < 3; i++) { if (getenv("GFXWIN_CV")) { CVPixelBufferRef pb = NULL; CVPixelBufferCreate(NULL, W, H, kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)@{ (id)kCVPixelBufferIOSurfacePropertiesKey: @{}, (id)kCVPixelBufferMetalCompatibilityKey: @YES }, &pb); sf[i] = CVPixelBufferGetIOSurface(pb); CFRetain(sf[i]); NSLog(@"CV surface %u pitch %zu", IOSurfaceGetID(sf[i]), IOSurfaceGetBytesPerRow(sf[i])); } else sf[i] = IOSurfaceCreate((__bridge CFDictionaryRef)@{ (id)kIOSurfaceWidth: @(W), (id)kIOSurfaceHeight: @(H), (id)kIOSurfaceBytesPerElement: @4, (id)kIOSurfacePixelFormat: @'BGRA' }); }
    stopAt = secs * 60; t0 = CFAbsoluteTimeGetCurrent(); NSLog(@"gfxwin %dx%d px (%.1f Mpx, %s path), %d s", W, H, W * (double)H / 1e6, W * H >= 3686400 ? "shared VRAM" : "private image", secs);
    [NSTimer scheduledTimerWithTimeInterval:1.0 / 60 repeats:YES block:^(NSTimer *t) { tick(); }];
    [NSApp run]; return 0;
}}
