// tiletest: Core Animation layer contents of odd widths (row pitch not a multiple of 32 B), rendered offscreen through the
// Metal driver, then replaced with a different colour and rendered again. Prints what the GPU actually shows.
#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
static CGImageRef solid(int w, int h, float r, float g, float b) {
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef c = CGBitmapContextCreate(NULL, w, h, 8, 0, cs, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGContextSetRGBFillColor(c, r, g, b, 1); CGContextFillRect(c, CGRectMake(0, 0, w, h));
    CGImageRef i = CGBitmapContextCreateImage(c); CGContextRelease(c); CGColorSpaceRelease(cs); return i;
}
int main(void) { @autoreleasepool {
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice(); id<MTLCommandQueue> q = [dev newCommandQueue];
    const int W = 400, H = 40; const int widths[] = {44, 45, 47, 50, 53, 61, 64, 72, 77, 90};
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:W height:H mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead; td.storageMode = MTLStorageModeManaged;
    id<MTLTexture> tex = [dev newTextureWithDescriptor:td];
    CALayer *root = [CALayer layer]; root.frame = CGRectMake(0, 0, W, H); root.backgroundColor = CGColorCreateGenericGray(0.5, 1);
    NSMutableArray *ls = [NSMutableArray array]; int x = 0;
    for (int i = 0; i < 10; i++) { CALayer *l = [CALayer layer]; l.frame = CGRectMake(x, 0, widths[i] / 2.0 * 0 + 38, 16); x += 40;
        l.contentsGravity = kCAGravityResize; [root addSublayer:l]; [ls addObject:l]; }
    CARenderer *r = [CARenderer rendererWithMTLTexture:tex options:@{}]; r.layer = root; r.bounds = root.frame;
    int bad = 0;
    for (int round = 0; round < 6; round++) {
        float cr = round % 3 == 0, cg = round % 3 == 1, cbl = round % 3 == 2;
        [CATransaction begin]; [CATransaction setDisableActions:YES];
        for (int i = 0; i < 10; i++) { CGImageRef im = solid(widths[i], 16, cr, cg, cbl); ((CALayer *)ls[i]).contents = (__bridge id)im; CGImageRelease(im); }
        [CATransaction commit]; [CATransaction flush];
        [r beginFrameAtTime:CACurrentMediaTime() timeStamp:NULL]; [r addUpdateRect:r.bounds]; [r render]; [r endFrame];
        id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
        [b synchronizeResource:tex]; [b endEncoding]; [cb commit]; [cb waitUntilCompleted];
        printf("round %d want %s:", round, cr ? "R" : cg ? "G" : "B");
        for (int i = 0; i < 10; i++) { uint8_t p[4]; [tex getBytes:p bytesPerRow:4 fromRegion:MTLRegionMake2D(i * 40 + 19, 8, 1, 1) mipmapLevel:0];
            const char *got = p[2] > 128 && p[1] < 64 && p[0] < 64 ? "R" : p[1] > 128 && p[2] < 64 && p[0] < 64 ? "G" : p[0] > 128 && p[2] < 64 && p[1] < 64 ? "B" : "?";
            if (strcmp(got, cr ? "R" : cg ? "G" : "B")) { bad++; printf(" [w%d %s %u,%u,%u]", widths[i], got, p[2], p[1], p[0]); } else printf(" w%d ok", widths[i]); }
        printf("\n");
    }
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:W pixelsHigh:H bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:W*4 bitsPerPixel:32];
    [tex getBytes:rep.bitmapData bytesPerRow:W*4 fromRegion:MTLRegionMake2D(0,0,W,H) mipmapLevel:0];
    uint8_t *d = rep.bitmapData; for (int i = 0; i < W*H; i++) { uint8_t t = d[i*4]; d[i*4] = d[i*4+2]; d[i*4+2] = t; }
    [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:@"tile.png" atomically:YES];
    printf("mismatches: %d\n", bad);
    return 0;
}}
