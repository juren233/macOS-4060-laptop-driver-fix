// cidown: Core Image downscale of a big image on the Metal device (what Preview / the screenshot thumbnail editor do when they
// show a large image: tiles come out as one flat colour each). Renders the image scaled by S with CIContext into a PNG and
// reports the per-1024-block spread so a flat-colour block is caught without looking.
// usage: cidown in.png out.png [scale=0.35] [cpu]
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
int main(int argc, char **argv) { @autoreleasepool {
    if (argc < 3) { printf("usage: cidown in.png out.png [scale] [cpu]\n"); return 2; }
    double S = argc > 3 ? atof(argv[3]) : 0.35; int cpu = argc > 4 && !strcmp(argv[4], "cpu");
    CIImage *im = [CIImage imageWithContentsOfURL:[NSURL fileURLWithPath:@(argv[1])]];
    if (!im) { printf("cannot read %s\n", argv[1]); return 1; }
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    CIContext *ctx = cpu ? [CIContext contextWithOptions:@{ kCIContextUseSoftwareRenderer: @YES }] : [CIContext contextWithMTLDevice:dev];
    NSString *mode = getenv("CIDOWN_MODE") ? @(getenv("CIDOWN_MODE")) : @"lanczos";
    CIImage *o;
    if ([mode isEqualToString:@"affine"]) o = [im imageByApplyingTransform:CGAffineTransformMakeScale(S, S)];
    else if ([mode isEqualToString:@"area"]) o = [im imageByApplyingTransform:CGAffineTransformMakeScale(S, S) highQualityDownsample:YES];
    else { CIFilter *f = [CIFilter filterWithName:@"CILanczosScaleTransform"]; [f setValue:im forKey:kCIInputImageKey]; [f setValue:@(S) forKey:kCIInputScaleKey]; [f setValue:@1.0 forKey:kCIInputAspectRatioKey]; o = f.outputImage; }
    CGRect r = CGRectIntegral(o.extent);
    printf("device %s, %s %s scale %.3f -> %dx%d\n", cpu ? "CPU" : dev.name.UTF8String, mode.UTF8String, argv[1], S, (int)r.size.width, (int)r.size.height);
    CGImageRef cg = [ctx createCGImage:o fromRect:r]; if (!cg) { printf("render failed\n"); return 1; }
    CGImageDestinationRef d = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:@(argv[2])], CFSTR("public.png"), 1, NULL);
    CGImageDestinationAddImage(d, cg, NULL); CGImageDestinationFinalize(d); CFRelease(d);
    // spread per 256x256 output block: a correct downscale of a screenshot has texture almost everywhere
    size_t W = CGImageGetWidth(cg), H = CGImageGetHeight(cg); uint8_t *px = calloc(W * H, 4);
    CGContextRef bc = CGBitmapContextCreate(px, W, H, 8, W * 4, CGColorSpaceCreateDeviceRGB(), kCGImageAlphaPremultipliedLast);
    CGContextDrawImage(bc, CGRectMake(0, 0, W, H), cg); int flat = 0, blocks = 0;
    for (size_t by = 0; by < H; by += 256) for (size_t bx = 0; bx < W; bx += 256) { double m = 0, m2 = 0; size_t n = 0;
        for (size_t y = by; y < by + 256 && y < H; y++) for (size_t x = bx; x < bx + 256 && x < W; x++) { double v = px[(y * W + x) * 4 + 1]; m += v; m2 += v * v; n++; }
        m /= n; double sd = sqrt(fmax(0, m2 / n - m * m)); blocks++; if (sd < 0.5) flat++; }
    printf("%d of %d blocks flat\n", flat, blocks); return flat * 4 > blocks;
}}
