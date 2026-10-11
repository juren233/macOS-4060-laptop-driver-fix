// backdrop: offscreen Core Animation render of backdrop (blur) layers and NSVisualEffectView materials -- the pieces
// the Finder sidebar header / selection use -- saved to backdrop.png (top half: CAFilter blur backdrops, bottom: materials).
#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <IOSurface/IOSurface.h>
@interface CAFilter : NSObject + (id)filterWithType:(NSString *)t; @end
int main(int argc, char **argv) { @autoreleasepool {
    [NSApplication sharedApplication];
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice(); id<MTLCommandQueue> q = [dev newCommandQueue];
    const int W = 600, H = 240;
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:W height:H mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead; td.storageMode = MTLStorageModeManaged;
    // argv[2] == "surf": render into an IOSurface-backed texture (what WindowServer's framebuffers and caches are)
    const int useSurf = argc > 2 && !strcmp(argv[2], "surf");
    IOSurfaceRef surf = useSurf ? IOSurfaceCreate((__bridge CFDictionaryRef)@{ (id)kIOSurfaceWidth: @(W), (id)kIOSurfaceHeight: @(H),
        (id)kIOSurfaceBytesPerElement: @4, (id)kIOSurfaceBytesPerRow: @(W * 4), (id)kIOSurfacePixelFormat: @((uint32_t)'BGRA') }) : NULL;
    if (useSurf) td.storageMode = MTLStorageModeShared;
    id<MTLTexture> tex = useSurf ? [dev newTextureWithDescriptor:td iosurface:surf plane:0] : [dev newTextureWithDescriptor:td];
    printf("target: %s\n", useSurf ? "IOSurface texture" : "plain texture");
    CALayer *root = [CALayer layer]; root.frame = CGRectMake(0, 0, W, H); root.geometryFlipped = YES;
    for (int i = 0; i < W / 20; i++) { CALayer *s = [CALayer layer]; s.frame = CGRectMake(i * 20, 0, 10, H);
        s.backgroundColor = CGColorCreateGenericRGB(i % 2, 0.6, 1 - i % 2, 1); [root addSublayer:s]; }
    Class bd = NSClassFromString(@"CABackdropLayer"), cf = NSClassFromString(@"CAFilter");
    const double radii[] = { 0, 4, 12, 30 };
    for (int k = 0; k < 4; k++) {
        CALayer *e = [bd layer]; e.frame = CGRectMake(10 + k * 148, 10, 136, 50);
        if (radii[k] > 0) { id f = [cf filterWithType:@"gaussianBlur"]; [f setValue:@(radii[k]) forKey:@"inputRadius"]; e.filters = @[f]; }
        if (k == 3) { e.cornerRadius = 12; e.masksToBounds = YES; }
        [root addSublayer:e];
        CATextLayer *t = [CATextLayer layer]; t.frame = CGRectMake(10 + k * 148, 64, 136, 20); t.string = [NSString stringWithFormat:@"blur %g", radii[k]];
        t.fontSize = 14; t.foregroundColor = CGColorCreateGenericGray(0, 1); t.contentsScale = 2; [root addSublayer:t]; }
    const NSVisualEffectMaterial mats[] = { NSVisualEffectMaterialSidebar, NSVisualEffectMaterialHeaderView, NSVisualEffectMaterialSelection, NSVisualEffectMaterialWindowBackground };
    for (int k = 0; k < 4; k++) {
        NSVisualEffectView *v = [[NSVisualEffectView alloc] initWithFrame:NSMakeRect(0, 0, 136, 60)];
        v.material = mats[k]; v.blendingMode = NSVisualEffectBlendingModeWithinWindow; v.state = NSVisualEffectStateActive;
        if (k == 2) v.emphasized = YES;
        v.wantsLayer = YES; [v layoutSubtreeIfNeeded]; [v displayIfNeeded];
        CALayer *l = v.layer; [l removeFromSuperlayer]; l.frame = CGRectMake(10 + k * 148, 110, 136, 60); [root addSublayer:l];
        printf("material %d: layer %s, %lu sublayers, filters %lu\n", k, object_getClassName(l), (unsigned long)l.sublayers.count, (unsigned long)l.filters.count);
        for (CALayer *s in l.sublayers) printf("   %s filters %lu bg %s\n", object_getClassName(s), (unsigned long)s.filters.count, s.backgroundColor ? "y" : "n"); }
    CARenderer *r = [CARenderer rendererWithMTLTexture:tex options:@{}]; r.layer = root; r.bounds = root.frame;
    [CATransaction flush];
    [r beginFrameAtTime:CACurrentMediaTime() timeStamp:NULL]; [r addUpdateRect:r.bounds]; [r render]; [r endFrame];
    id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder];
    if (!useSurf) [bl synchronizeResource:tex]; [bl endEncoding]; [cb commit]; [cb waitUntilCompleted];
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:W pixelsHigh:H bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:W*4 bitsPerPixel:32];
    [tex getBytes:rep.bitmapData bytesPerRow:W*4 fromRegion:MTLRegionMake2D(0,0,W,H) mipmapLevel:0];
    uint8_t *px = rep.bitmapData; for (int i = 0; i < W*H; i++) { uint8_t s = px[i*4]; px[i*4] = px[i*4+2]; px[i*4+2] = s; }
    [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:@(argc > 1 ? argv[1] : "backdrop.png") atomically:YES];
    return 0;
}}
