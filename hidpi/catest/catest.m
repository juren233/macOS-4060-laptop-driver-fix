// catest: renders a small Core Animation tree offscreen through the Metal driver (CARenderer) and prints pixels,
// to see which layer features come out black. Background is mid-grey (128); each probe layer covers x 20..80 of a row.
#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
static id<MTLDevice> dev; static id<MTLCommandQueue> q;
static void px(id<MTLTexture> t, int x, int y, const char *tag) {
    uint8_t p[4]; [t getBytes:p bytesPerRow:4 fromRegion:MTLRegionMake2D(x, y, 1, 1) mipmapLevel:0];
    printf("  %-28s (%3d,%3d) B %3u G %3u R %3u A %3u\n", tag, x, y, p[0], p[1], p[2], p[3]);
}
int main(int argc, char **argv) { @autoreleasepool {
    dev = MTLCreateSystemDefaultDevice(); q = [dev newCommandQueue];
    printf("device: %s\n", dev.name.UTF8String);
    const int W = 100, H = 20 * 8;
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:W height:H mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead; td.storageMode = MTLStorageModeManaged;
    id<MTLTexture> tex = [dev newTextureWithDescriptor:td];
    CALayer *root = [CALayer layer]; root.frame = CGRectMake(0, 0, W, H); root.geometryFlipped = YES;
    root.backgroundColor = CGColorCreateGenericRGB(0.5, 0.5, 0.5, 1);
    const char *names[] = {"plain 50% white", "plusD (plus-darker)", "plusL (plus-lighter)", "multiplyBlendMode",
                           "overlayBlendMode", "text layer", "text + plusD", "opacity 0.5 group"};
    for (int i = 0; i < 8; i++) {
        CALayer *l;
        if (i == 5 || i == 6) { CATextLayer *t = [CATextLayer layer]; t.string = @"MMMMMM"; t.fontSize = 18;
            t.foregroundColor = CGColorCreateGenericRGB(1, 1, 1, 0.6); l = t; }
        else { l = [CALayer layer]; l.backgroundColor = CGColorCreateGenericRGB(1, 1, 1, 0.5); }
        l.frame = CGRectMake(20, i * 20 + 2, 60, 16);
        if (i == 1 || i == 6) l.compositingFilter = @"plusD";
        if (i == 2) l.compositingFilter = @"plusL";
        if (i == 3) l.compositingFilter = [CIFilter filterWithName:@"CIMultiplyBlendMode"];
        if (i == 4) l.compositingFilter = [CIFilter filterWithName:@"CIOverlayBlendMode"];
        if (i == 7) { l.opacity = 0.5; l.allowsGroupOpacity = YES; CALayer *s = [CALayer layer]; s.frame = CGRectMake(0,0,30,16);
            s.backgroundColor = CGColorCreateGenericRGB(0, 0, 1, 1); [l addSublayer:s]; }
        [root addSublayer:l];
    }
    CARenderer *r = [CARenderer rendererWithMTLTexture:tex options:@{kCARendererColorSpace: (__bridge id)CGColorSpaceCreateWithName(kCGColorSpaceSRGB)}];
    r.layer = root; r.bounds = root.frame;
    [CATransaction flush];
    [r beginFrameAtTime:CACurrentMediaTime() timeStamp:NULL]; [r addUpdateRect:r.bounds]; [r render]; [r endFrame];
    id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
    [b synchronizeResource:tex]; [b endEncoding]; [cb commit]; [cb waitUntilCompleted];
    usleep(200000);
    px(tex, 10, 10, "background");
    for (int i = 0; i < 8; i++) { px(tex, 30, i * 20 + 10, names[i]); }
    // Also dump a PNG so the result can be looked at.
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:W pixelsHigh:H bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:W*4 bitsPerPixel:32];
    [tex getBytes:rep.bitmapData bytesPerRow:W*4 fromRegion:MTLRegionMake2D(0,0,W,H) mipmapLevel:0];
    uint8_t *d = rep.bitmapData; for (int i = 0; i < W*H; i++) { uint8_t t = d[i*4]; d[i*4] = d[i*4+2]; d[i*4+2] = t; }
    if (argc > 1) [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:@(argv[1]) atomically:YES];
    return 0;
}}
