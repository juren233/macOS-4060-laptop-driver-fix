#include <signal.h>
// gfx4 (two processes): a compositor-style buffer queue. N IOSurfaces rotate; each frame a NEW texture is made on the next surface, the
// previous surface is sampled to copy its contents, then a few damage rects are drawn. A CPU model checks every few frames.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurface.h>
#import <IOKit/IOKitLib.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <spawn.h>
#import <unistd.h>
#import <sys/wait.h>
static id<MTLDevice> dev; static id<MTLCommandQueue> q; static id<MTLLibrary> lib;
static NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
"struct V { float4 p [[position]]; };\n"
"vertex V vq(uint i [[vertex_id]], constant float4 &g [[buffer(0)]]) { float2 p[4] = { float2(0,0), float2(1,0), float2(0,1), float2(1,1) };\n"
"  V o; o.p = float4((g.xy + p[i] * g.zw) * 2 - 1, 0, 1); o.p.y = -o.p.y; return o; }\n"
"fragment float4 fc(V in [[stage_in]], constant float4 &c [[buffer(0)]]) { return c; }\n"
"fragment float4 fs(V in [[stage_in]], texture2d<float> t [[texture(0)]]) { constexpr sampler s(filter::nearest, coord::pixel); return t.sample(s, in.p.xy); }\n";
static uint32_t rnd(uint32_t *s) { *s = *s * 1664525u + 1013904223u; return *s >> 8; }
static id<MTLTexture> tex(IOSurfaceRef surf, int W, int H, MTLTextureUsage u) {
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:W height:H mipmapped:NO];
    td.usage = u; td.storageMode = MTLStorageModeManaged; return [dev newTextureWithDescriptor:td iosurface:surf plane:0];
}

extern char **environ;
static void initdev(void) { dev = MTLCreateSystemDefaultDevice(); q = [dev newCommandQueue]; NSError *e; lib = [dev newLibraryWithSource:src options:nil error:&e]; }
// the drawing sequence both sides replay: frame f draws into buffer f%n after copying (f-1)%n, then k rects
typedef struct { int x, y, w, h; uint8_t r, g, b; } DRect;
static int rects(uint32_t *s, int W, int H, DRect *out) {
    int n = 1 + rnd(s) % 3;
    for (int k = 0; k < n; k++) { DRect *r = &out[k]; r->w = 16 + rnd(s) % (W / 3); r->h = 16 + rnd(s) % (H / 3); r->x = rnd(s) % (W - r->w); r->y = rnd(s) % (H - r->h); r->r = rnd(s); r->g = rnd(s); r->b = rnd(s); }
    return n;
}
static void apply(uint32_t *m, int W, const DRect *r) { uint32_t px = 0xFF000000u | (uint32_t)r->r << 16 | (uint32_t)r->g << 8 | r->b; for (int y = r->y; y < r->y + r->h; y++) for (int x = r->x; x < r->x + r->w; x++) m[(size_t)y * W + x] = px; }
static int producer(int W, int H, int nbuf, int frames) {
    initdev(); IOSurfaceRef sf[4]; NSError *e;
    for (int i = 0; i < nbuf; i++) { sf[i] = IOSurfaceCreate((__bridge CFDictionaryRef)@{ (id)kIOSurfaceWidth: @(W), (id)kIOSurfaceHeight: @(H), (id)kIOSurfaceBytesPerElement: @4, (id)kIOSurfacePixelFormat: @'BGRA', (id)kIOSurfaceIsGlobal: @YES }); printf("%u\n", IOSurfaceGetID(sf[i])); }
    fflush(stdout);
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new]; d.vertexFunction = [lib newFunctionWithName:@"vq"]; d.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    d.fragmentFunction = [lib newFunctionWithName:@"fc"]; id<MTLRenderPipelineState> pc = [dev newRenderPipelineStateWithDescriptor:d error:&e];
    d.fragmentFunction = [lib newFunctionWithName:@"fs"]; id<MTLRenderPipelineState> pcopy = [dev newRenderPipelineStateWithDescriptor:d error:&e];
    uint32_t s = 777; char line[64];
    for (int f = 0; f < frames; f++) {
        if (f >= nbuf - 1) { if (!fgets(line, sizeof line, stdin)) return 3; }   // credit: consumer finished frame f-(nbuf-1)
        int b = f % nbuf, pv = (f + nbuf - 1) % nbuf;
        id<MTLTexture> cur = tex(sf[b], W, H, MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead), prev = f ? tex(sf[pv], W, H, MTLTextureUsageShaderRead) : nil;
        id<MTLCommandBuffer> cb = [q commandBuffer]; MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = cur; rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1); rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
        if (prev) { [re setRenderPipelineState:pcopy]; float full[4] = { 0, 0, 1, 1 }; [re setVertexBytes:full length:16 atIndex:0]; [re setFragmentTexture:prev atIndex:0]; [re drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4]; }
        [re setRenderPipelineState:pc]; DRect rc[3]; int n = rects(&s, W, H, rc);
        for (int k = 0; k < n; k++) { float geom[4] = { (float)rc[k].x / W, (float)rc[k].y / H, (float)rc[k].w / W, (float)rc[k].h / H }, col[4] = { rc[k].r / 255.f, rc[k].g / 255.f, rc[k].b / 255.f, 1 };
            [re setVertexBytes:geom length:16 atIndex:0]; [re setFragmentBytes:col length:16 atIndex:0]; [re drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4]; }
        [re endEncoding]; [cb commit]; [cb waitUntilScheduled];   // what Chromium does before handing the surface to Core Animation
        printf("F %d %d\n", f, b); fflush(stdout);
    }
    return 0;
}
static int consumer(const char *self, int W, int H, int nbuf, int frames, const char *label) {
    signal(SIGPIPE, SIG_IGN);   // the producer may exit as soon as it handed over its last frame
    initdev(); int po[2], pi[2]; pipe(po); pipe(pi);
    posix_spawn_file_actions_t fa; posix_spawn_file_actions_init(&fa); posix_spawn_file_actions_adddup2(&fa, po[1], 1); posix_spawn_file_actions_adddup2(&fa, pi[0], 0);
    posix_spawn_file_actions_addclose(&fa, po[0]); posix_spawn_file_actions_addclose(&fa, pi[1]);
    char a1[16], a2[16], a3[16], a4[16]; snprintf(a1, 16, "%d", W); snprintf(a2, 16, "%d", H); snprintf(a3, 16, "%d", nbuf); snprintf(a4, 16, "%d", frames);
    char *av[] = { (char *)self, (char *)"producer", a1, a2, a3, a4, NULL }; pid_t pid; if (posix_spawn(&pid, self, &fa, NULL, av, environ)) { printf("spawn failed\n"); return 2; }
    close(po[1]); close(pi[0]); FILE *in = fdopen(po[0], "r"); char line[64]; IOSurfaceRef sf[4]; uint32_t *model[4];
    for (int i = 0; i < nbuf; i++) { if (!fgets(line, sizeof line, in)) return 2; sf[i] = IOSurfaceLookup((uint32_t)atoi(line)); if (!sf[i]) { printf("lookup failed\n"); return 2; }
        model[i] = malloc((size_t)W * H * 4); for (size_t k = 0; k < (size_t)W * H; k++) model[i][k] = 0xFF000000u; }
    id<MTLBuffer> rb = [dev newBufferWithLength:(size_t)W * H * 4 options:MTLResourceStorageModeShared]; uint32_t s = 777; int bad = 0, n = 0; long worst = 0;
    while (fgets(line, sizeof line, in)) {
        int f, b; if (sscanf(line, "F %d %d", &f, &b) != 2) { if (getenv("GFX_V")) printf("   unparsed producer line: %.60s\n", line); continue; }
        DRect rc[3]; int k = rects(&s, W, H, rc); int pv = (f + nbuf - 1) % nbuf; if (f) memcpy(model[b], model[pv], (size_t)W * H * 4); else for (size_t i = 0; i < (size_t)W * H; i++) model[b][i] = 0xFF000000u;
        for (int i = 0; i < k; i++) apply(model[b], W, &rc[i]);
        id<MTLTexture> rd = tex(sf[b], W, H, MTLTextureUsageShaderRead); id<MTLCommandBuffer> c2 = [q commandBuffer]; id<MTLBlitCommandEncoder> bl = [c2 blitCommandEncoder];
        [bl copyFromTexture:rd sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(W,H,1) toBuffer:rb destinationOffset:0 destinationBytesPerRow:(size_t)W * 4 destinationBytesPerImage:(size_t)W * H * 4];
        [bl endEncoding]; [c2 commit]; [c2 waitUntilCompleted];
        const uint32_t *got = rb.contents; long diff = 0; for (size_t i = 0; i < (size_t)W * H; i++) if (got[i] != model[b][i]) diff++;
        n++; if (diff) { bad++; if (diff > worst) worst = diff; if (getenv("GFX_V")) printf("   frame %d buf %d: %ld px differ\n", f, b, diff); }
        // A credit lets the producer start frame f + nbuf - 1; none is owed after that frame would be the last. A failed write
        // (the producer already gone) must not end the loop either: its last frames are still in the pipe.
        if (f + nbuf <= frames) (void)!write(pi[1], "ok\n", 3);
    }
    int st = 0; waitpid(pid, &st, 0);
    if (n < frames) printf("   producer delivered %d of %d frames: %s %d\n", n, frames, WIFSIGNALED(st) ? "killed by signal" : "exit status", WIFSIGNALED(st) ? WTERMSIG(st) : WEXITSTATUS(st));
    printf("%-34s %dx%d x%d bufs, %d frames: consumer saw %d/%d frames WRONG%s\n", label, W, H, nbuf, frames, bad, n, bad ? "  <==" : "");
    return bad != 0 || n < frames;
}
int main(int argc, char **argv) { @autoreleasepool {
    if (argc > 1 && !strcmp(argv[1], "producer")) return producer(atoi(argv[2]), atoi(argv[3]), atoi(argv[4]), atoi(argv[5]));
    int bad = 0;
    bad += consumer(argv[0], 960, 540, 3, 60, "small (private image)");
    bad += consumer(argv[0], 2560, 1440, 3, 40, "large (shared linear VRAM)");
    printf("%s\n", bad ? "FAIL" : "PASS"); return bad;
}}
