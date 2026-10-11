// shapes: offscreen Core Animation render of the features the broken Finder/Terminal pixels use -- rounded corners
// (circular and continuous), masksToBounds, a shadow, and a backdrop (blur) layer -- saved to shapes.png.
#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
int main(int argc, char **argv) { @autoreleasepool {
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice(); id<MTLCommandQueue> q = [dev newCommandQueue];
    const int W = 480, H = 160;
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:W height:H mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead; td.storageMode = MTLStorageModeManaged;
    id<MTLTexture> tex = [dev newTextureWithDescriptor:td];
    CALayer *root = [CALayer layer]; root.frame = CGRectMake(0, 0, W, H); root.geometryFlipped = YES;
    // striped background so blur/backdrop/transparency are visible
    for (int i = 0; i < W / 20; i++) { CALayer *s = [CALayer layer]; s.frame = CGRectMake(i * 20, 0, 10, H);
        s.backgroundColor = CGColorCreateGenericRGB(i % 2, 0.6, 1 - i % 2, 1); [root addSublayer:s]; }
    CGColorRef grey = CGColorCreateGenericGray(0.85, 1);
    CALayer *a = [CALayer layer]; a.frame = CGRectMake(10, 10, 100, 40); a.backgroundColor = grey; a.cornerRadius = 12; [root addSublayer:a];
    CALayer *b = [CALayer layer]; b.frame = CGRectMake(130, 10, 100, 40); b.backgroundColor = grey; b.cornerRadius = 12;
    b.cornerCurve = kCACornerCurveContinuous; [root addSublayer:b];
    CALayer *c = [CALayer layer]; c.frame = CGRectMake(250, 10, 100, 40); c.cornerRadius = 12; c.masksToBounds = YES; [root addSublayer:c];
    CALayer *ci = [CALayer layer]; ci.frame = c.bounds; ci.backgroundColor = grey; [c addSublayer:ci];
    CALayer *d = [CALayer layer]; d.frame = CGRectMake(370, 10, 100, 40); d.backgroundColor = grey; d.cornerRadius = 12;
    d.shadowOpacity = 0.8; d.shadowRadius = 6; d.shadowOffset = CGSizeMake(0, 3); [root addSublayer:d];
    Class bd = NSClassFromString(@"CABackdropLayer");
    CALayer *e = bd ? [bd layer] : [CALayer layer]; e.frame = CGRectMake(10, 80, 220, 60); e.cornerRadius = 10; e.masksToBounds = YES;
    if (bd) { CIFilter *f = [CIFilter filterWithName:@"CIGaussianBlur"]; [f setValue:@8 forKey:@"inputRadius"]; e.filters = @[f]; }
    [root addSublayer:e];
    CATextLayer *t = [CATextLayer layer]; t.frame = CGRectMake(250, 80, 220, 40); t.string = @"个人收藏 Favorites"; t.fontSize = 22;
    t.foregroundColor = CGColorCreateGenericGray(0.2, 1); t.contentsScale = 2; [root addSublayer:t];
    CARenderer *r = [CARenderer rendererWithMTLTexture:tex options:@{}]; r.layer = root; r.bounds = root.frame;
    [CATransaction flush];
    [r beginFrameAtTime:CACurrentMediaTime() timeStamp:NULL]; [r addUpdateRect:r.bounds]; [r render]; [r endFrame];
    id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder];
    [bl synchronizeResource:tex]; [bl endEncoding]; [cb commit]; [cb waitUntilCompleted];
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:W pixelsHigh:H bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:W*4 bitsPerPixel:32];
    [tex getBytes:rep.bitmapData bytesPerRow:W*4 fromRegion:MTLRegionMake2D(0,0,W,H) mipmapLevel:0];
    uint8_t *px = rep.bitmapData; for (int i = 0; i < W*H; i++) { uint8_t s = px[i*4]; px[i*4] = px[i*4+2]; px[i*4+2] = s; }
    [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:@(argc > 1 ? argv[1] : "shapes.png") atomically:YES];
    printf("backdrop class %s\n", bd ? "present" : "absent");
    return 0;
}}
