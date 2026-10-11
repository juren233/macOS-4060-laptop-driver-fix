// calayer: a CALayer whose contents is an IOSurface, rendered by CARenderer through the Metal plugin into a texture.
// The surface holds a CPU-written pattern; check the rendered pixels. Usage: calayer [W H] [pluginpath]
#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <IOSurface/IOSurface.h>
#import <objc/runtime.h>
#import <objc/message.h>

static IMP o_surf, o_plain, o_buf;
static id n_surf(id self, SEL _c, MTLTextureDescriptor *d, IOSurfaceRef s, NSUInteger plane) { id r = ((id (*)(id, SEL, id, IOSurfaceRef, NSUInteger))o_surf)(self, _c, d, s, plane);
    printf("  [dev] newTextureWithDescriptor:iosurface: fmt %lu %lux%lu usage 0x%lx storage %lu plane %lu surf %p(%zux%zu planes %zu fmt %08x) -> %s\n", (unsigned long)d.pixelFormat, (unsigned long)d.width, (unsigned long)d.height, (unsigned long)d.usage, (unsigned long)d.storageMode, (unsigned long)plane, s, IOSurfaceGetWidth(s), IOSurfaceGetHeight(s), IOSurfaceGetPlaneCount(s), IOSurfaceGetPixelFormat(s), r ? "OK" : "NIL"); return r; }
static id n_plain(id self, SEL _c, MTLTextureDescriptor *d) { id r = ((id (*)(id, SEL, id))o_plain)(self, _c, d);
    static int n; if (n++ < 40) printf("  [dev] newTextureWithDescriptor: fmt %lu %lux%lu usage 0x%lx storage %lu -> %s\n", (unsigned long)d.pixelFormat, (unsigned long)d.width, (unsigned long)d.height, (unsigned long)d.usage, (unsigned long)d.storageMode, r ? "OK" : "NIL"); return r; }
static void hook(id dev) { Class c = object_getClass(dev); printf("device class %s\n", class_getName(c));
    Method m = class_getInstanceMethod(c, @selector(newTextureWithDescriptor:iosurface:plane:)); if (m) { o_surf = method_getImplementation(m); method_setImplementation(m, (IMP)n_surf); }
    m = class_getInstanceMethod(c, @selector(newTextureWithDescriptor:)); if (m) { o_plain = method_getImplementation(m); method_setImplementation(m, (IMP)n_plain); } }


static IMP o_bufsurf, o_slice, o_tsb;
static id n_bufsurf(id self, SEL _c, IOSurfaceRef s) { id r = ((id (*)(id, SEL, IOSurfaceRef))o_bufsurf)(self, _c, s); printf("  [dev] newBufferWithIOSurface: %p (%zux%zu) -> %s\n", s, IOSurfaceGetWidth(s), IOSurfaceGetHeight(s), r ? "OK" : "NIL"); return r; }
static id n_slice(id self, SEL _c, MTLTextureDescriptor *d, IOSurfaceRef s, NSUInteger plane, NSUInteger slice) { id r = ((id (*)(id, SEL, id, IOSurfaceRef, NSUInteger, NSUInteger))o_slice)(self, _c, d, s, plane, slice); printf("  [dev] newTextureWithDescriptor:iosurface:plane:slice: fmt %lu %lux%lu -> %s\n", (unsigned long)d.pixelFormat, (unsigned long)d.width, (unsigned long)d.height, r ? "OK" : "NIL"); return r; }
static id n_tsb(id self, SEL _c, IOSurfaceRef s, id b) { id r = ((id (*)(id, SEL, IOSurfaceRef, id))o_tsb)(self, _c, s, b); printf("  [dev] newTextureWithSurface:buffer: -> %s\n", r ? "OK" : "NIL"); return r; }
static void hook2(id dev) { Class c = object_getClass(dev);
    Method m = class_getInstanceMethod(c, @selector(newBufferWithIOSurface:)); if (m) { o_bufsurf = method_getImplementation(m); method_setImplementation(m, (IMP)n_bufsurf); }
    m = class_getInstanceMethod(c, NSSelectorFromString(@"newTextureWithDescriptor:iosurface:plane:slice:")); if (m) { o_slice = method_getImplementation(m); method_setImplementation(m, (IMP)n_slice); }
    m = class_getInstanceMethod(c, NSSelectorFromString(@"newTextureWithSurface:buffer:")); if (m) { o_tsb = method_getImplementation(m); method_setImplementation(m, (IMP)n_tsb); } }
int main(int argc, char **argv) { @autoreleasepool {
    int W = argc > 2 ? atoi(argv[1]) : 600, H = argc > 2 ? atoi(argv[2]) : 400;
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice(); id<MTLCommandQueue> q = [dev newCommandQueue]; hook(dev); hook2(dev);
    IOSurfaceRef sf = IOSurfaceCreate((__bridge CFDictionaryRef)@{ (id)kIOSurfaceWidth: @(W), (id)kIOSurfaceHeight: @(H), (id)kIOSurfaceBytesPerElement: @4, (id)kIOSurfacePixelFormat: @'BGRA' });
    IOSurfaceLock(sf, 0, NULL); uint8_t *p = IOSurfaceGetBaseAddress(sf); size_t row = IOSurfaceGetBytesPerRow(sf);
    for (int y = 0; y < H; y++) { uint32_t *r = (uint32_t *)(p + (size_t)y * row); for (int x = 0; x < W; x++) r[x] = x < W / 2 ? (y < H / 2 ? 0xFFFF0000u : 0xFF00FF00u) : (y < H / 2 ? 0xFF0000FFu : 0xFFFFFF00u); }
    IOSurfaceUnlock(sf, 0, NULL);
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:W height:H mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead; td.storageMode = MTLStorageModeManaged; id<MTLTexture> tex = [dev newTextureWithDescriptor:td];
    CALayer *root = [CALayer layer]; root.frame = CGRectMake(0, 0, W, H); root.backgroundColor = CGColorCreateGenericRGB(0.5, 0.5, 0.5, 1);
    CALayer *c = [CALayer layer]; c.frame = root.frame; if (!getenv("CAL_NOCONTENTS")) c.contents = (__bridge id)sf; else c.backgroundColor = CGColorCreateGenericRGB(1, 0, 0, 1); c.contentsGravity = kCAGravityResize; [root addSublayer:c];
    CARenderer *r = [CARenderer rendererWithMTLTexture:tex options:@{}]; r.layer = root; r.bounds = root.frame; [CATransaction flush];
    [r beginFrameAtTime:CACurrentMediaTime() timeStamp:NULL]; [r addUpdateRect:r.bounds]; [r render]; [r endFrame];
    id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder]; [bl synchronizeResource:tex]; [bl endEncoding]; [cb commit]; [cb waitUntilCompleted];
    uint32_t *px = malloc((size_t)W * H * 4); [tex getBytes:px bytesPerRow:W * 4 fromRegion:MTLRegionMake2D(0,0,W,H) mipmapLevel:0];
    struct { int x, y; uint32_t want; const char *n; } t[4] = { { W / 4, H / 4, 0xFFFF0000u, "top-left (red)" }, { W / 4, 3 * H / 4, 0xFF00FF00u, "bottom-left (green)" }, { 3 * W / 4, H / 4, 0xFF0000FFu, "top-right (blue)" }, { 3 * W / 4, 3 * H / 4, 0xFFFFFF00u, "bottom-right (yellow)" } };
    int bad = 0;
    for (int i = 0; i < 4; i++) { uint32_t got = px[t[i].y * W + t[i].x]; int ok = got == t[i].want || ((got ^ t[i].want) & 0xFEFEFEFE) == 0; if (!ok) bad++; printf("  %-22s got %08x want %08x %s\n", t[i].n, got, t[i].want, ok ? "ok" : "WRONG"); }
    printf("%dx%d: %s\n", W, H, bad ? "FAIL" : "PASS"); return bad != 0;
}}
