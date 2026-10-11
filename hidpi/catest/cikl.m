// cikl: bisects Core Image's _lanczosDownH failure with CIKL kernels (CI compiles these through the same stitched AIR as its
// built-in kernels). Each variant is rendered on the Metal device and in software; the mean abs difference must be ~0.
// usage: cikl [variant ...]
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <CoreImage/CoreImage.h>
static NSString *V[] = {
 // 0 plain resample through the sampler transform
 @"kernel vec4 k(sampler s, vec4 sc) { vec2 p = sc.xy * destCoord(); return sample(s, samplerTransform(s, p)); }",
 // 1 + floor on x
 @"kernel vec4 k(sampler s, vec4 sc) { vec2 p = sc.xy * destCoord(); p.x = floor(p.x - 0.5) + 0.5; return sample(s, samplerTransform(s, p)); }",
 // 2 + 3 taps along sc.zw, plain average
 @"kernel vec4 k(sampler s, vec4 sc) { vec2 p = sc.xy * destCoord(); p.x = floor(p.x - 0.5) + 0.5;"
  " return (sample(s, samplerTransform(s, p - sc.zw)) + sample(s, samplerTransform(s, p)) + sample(s, samplerTransform(s, p + sc.zw))) / 3.0; }",
 // 3 + branchy lanczos weights, 3 taps
 @"float lw(float x) { x = abs(x); if (x < 3.0) { if (x < 0.001) return 1.0; float a = x * 3.14159265; return sin(a) * 3.0 * sin(x * 1.0471976) / (a * a); } return 0.0; }\n"
  "kernel vec4 k(sampler s, vec4 sc) { vec2 d = sc.xy * destCoord(); vec2 p = d; p.x = floor(p.x - 0.5) + 0.5;"
  " float w0 = lw((p.x - sc.z - d.x) / sc.x), w1 = lw((p.x - d.x) / sc.x), w2 = lw((p.x + sc.z - d.x) / sc.x);"
  " return (w0 * sample(s, samplerTransform(s, p - sc.zw)) + w1 * sample(s, samplerTransform(s, p)) + w2 * sample(s, samplerTransform(s, p + sc.zw))) / (w0 + w1 + w2); }",
 // 4 = 3 without floor
 @"float lw(float x) { x = abs(x); if (x < 3.0) { if (x < 0.001) return 1.0; float a = x * 3.14159265; return sin(a) * 3.0 * sin(x * 1.0471976) / (a * a); } return 0.0; }\n"
  "kernel vec4 k(sampler s, vec4 sc) { vec2 d = sc.xy * destCoord(); vec2 p = d;"
  " float w0 = lw((p.x - sc.z - d.x) / sc.x + 0.3), w1 = lw((p.x - d.x) / sc.x + 0.3), w2 = lw((p.x + sc.z - d.x) / sc.x + 0.3);"
  " return (w0 * sample(s, samplerTransform(s, p - sc.zw)) + w1 * sample(s, samplerTransform(s, p)) + w2 * sample(s, samplerTransform(s, p + sc.zw))) / (w0 + w1 + w2); }",
 // 5 full 12-tap lanczosDownH as Core Image has it
 @"float lw(float x) { x = abs(x); if (x < 3.0) { if (x < 0.001) return 1.0; float a = x * 3.14159265; return sin(a) * 3.0 * sin(x * 1.0471976) / (a * a); } return 0.0; }\n"
  "kernel vec4 k(sampler s, vec4 sc) { vec2 d = sc.xy * destCoord(); vec2 p = d; p.x = floor(p.x - 0.5) + 0.5;"
  " vec2 c0 = p + -5.0 * sc.zw; float w0 = lw((c0.x - d.x) / sc.x); vec4 s0 = sample(s, samplerTransform(s, c0));"
  " vec2 c1 = p + -4.0 * sc.zw; float w1 = lw((c1.x - d.x) / sc.x); vec4 s1 = sample(s, samplerTransform(s, c1));"
  " vec2 c2 = p + -3.0 * sc.zw; float w2 = lw((c2.x - d.x) / sc.x); vec4 s2 = sample(s, samplerTransform(s, c2));"
  " vec2 c3 = p + -2.0 * sc.zw; float w3 = lw((c3.x - d.x) / sc.x); vec4 s3 = sample(s, samplerTransform(s, c3));"
  " vec2 c4 = p + -1.0 * sc.zw; float w4 = lw((c4.x - d.x) / sc.x); vec4 s4 = sample(s, samplerTransform(s, c4));"
  " vec2 c5 = p + 0.0 * sc.zw; float w5 = lw((c5.x - d.x) / sc.x); vec4 s5 = sample(s, samplerTransform(s, c5));"
  " vec2 c6 = p + 1.0 * sc.zw; float w6 = lw((c6.x - d.x) / sc.x); vec4 s6 = sample(s, samplerTransform(s, c6));"
  " vec2 c7 = p + 2.0 * sc.zw; float w7 = lw((c7.x - d.x) / sc.x); vec4 s7 = sample(s, samplerTransform(s, c7));"
  " vec2 c8 = p + 3.0 * sc.zw; float w8 = lw((c8.x - d.x) / sc.x); vec4 s8 = sample(s, samplerTransform(s, c8));"
  " vec2 c9 = p + 4.0 * sc.zw; float w9 = lw((c9.x - d.x) / sc.x); vec4 s9 = sample(s, samplerTransform(s, c9));"
  " vec2 c10 = p + 5.0 * sc.zw; float w10 = lw((c10.x - d.x) / sc.x); vec4 s10 = sample(s, samplerTransform(s, c10));"
  " vec2 c11 = p + 6.0 * sc.zw; float w11 = lw((c11.x - d.x) / sc.x); vec4 s11 = sample(s, samplerTransform(s, c11));"
  " return (w0*s0+w1*s1+w2*s2+w3*s3+w4*s4+w5*s5+w6*s6+w7*s7+w8*s8+w9*s9+w10*s10+w11*s11) / (w0+w1+w2+w3+w4+w5+w6+w7+w8+w9+w10+w11); }",
 // 6 = 5 without floor
 @"float lw(float x) { x = abs(x); if (x < 3.0) { if (x < 0.001) return 1.0; float a = x * 3.14159265; return sin(a) * 3.0 * sin(x * 1.0471976) / (a * a); } return 0.0; }\n"
  "kernel vec4 k(sampler s, vec4 sc) { vec2 d = sc.xy * destCoord(); vec2 p = d;"
  " vec2 c0 = p + -5.0 * sc.zw; float w0 = lw((c0.x - d.x) / sc.x); vec4 s0 = sample(s, samplerTransform(s, c0));"
  " vec2 c1 = p + -4.0 * sc.zw; float w1 = lw((c1.x - d.x) / sc.x); vec4 s1 = sample(s, samplerTransform(s, c1));"
  " vec2 c2 = p + -3.0 * sc.zw; float w2 = lw((c2.x - d.x) / sc.x); vec4 s2 = sample(s, samplerTransform(s, c2));"
  " vec2 c3 = p + -2.0 * sc.zw; float w3 = lw((c3.x - d.x) / sc.x); vec4 s3 = sample(s, samplerTransform(s, c3));"
  " vec2 c4 = p + -1.0 * sc.zw; float w4 = lw((c4.x - d.x) / sc.x); vec4 s4 = sample(s, samplerTransform(s, c4));"
  " vec2 c5 = p + 0.0 * sc.zw; float w5 = lw((c5.x - d.x) / sc.x); vec4 s5 = sample(s, samplerTransform(s, c5));"
  " vec2 c6 = p + 1.0 * sc.zw; float w6 = lw((c6.x - d.x) / sc.x); vec4 s6 = sample(s, samplerTransform(s, c6));"
  " vec2 c7 = p + 2.0 * sc.zw; float w7 = lw((c7.x - d.x) / sc.x); vec4 s7 = sample(s, samplerTransform(s, c7));"
  " vec2 c8 = p + 3.0 * sc.zw; float w8 = lw((c8.x - d.x) / sc.x); vec4 s8 = sample(s, samplerTransform(s, c8));"
  " vec2 c9 = p + 4.0 * sc.zw; float w9 = lw((c9.x - d.x) / sc.x); vec4 s9 = sample(s, samplerTransform(s, c9));"
  " vec2 c10 = p + 5.0 * sc.zw; float w10 = lw((c10.x - d.x) / sc.x); vec4 s10 = sample(s, samplerTransform(s, c10));"
  " vec2 c11 = p + 6.0 * sc.zw; float w11 = lw((c11.x - d.x) / sc.x); vec4 s11 = sample(s, samplerTransform(s, c11));"
  " return (w0*s0+w1*s1+w2*s2+w3*s3+w4*s4+w5*s5+w6*s6+w7*s7+w8*s8+w9*s9+w10*s10+w11*s11) / (w0+w1+w2+w3+w4+w5+w6+w7+w8+w9+w10+w11); }",
};
int main(int argc, char **argv) { @autoreleasepool {
    const int NV = sizeof V / sizeof *V; int first = 0, last = NV - 1; if (argc > 1) first = last = atoi(argv[1]);
    // source: a 600x300 pattern with structure in both x and y
    const int W = 600, H = 300; uint8_t *px = malloc(W * H * 4);
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) { uint8_t *p = px + (y * W + x) * 4; p[0] = x * 255 / W; p[1] = y * 255 / H; p[2] = ((x / 16 + y / 16) & 1) ? 220 : 30; p[3] = 255; }
    CIImage *src = [CIImage imageWithBitmapData:[NSData dataWithBytesNoCopy:px length:W * H * 4 freeWhenDone:NO] bytesPerRow:W * 4 size:CGSizeMake(W, H) format:kCIFormatRGBA8 colorSpace:nil];
    CIContext *gpu = [CIContext contextWithMTLDevice:MTLCreateSystemDefaultDevice() options:@{ kCIContextWorkingColorSpace: [NSNull null] }];
    CIContext *cpu = [CIContext contextWithOptions:@{ kCIContextUseSoftwareRenderer: @YES, kCIContextWorkingColorSpace: [NSNull null] }];
    const float S = 1.42857f; int fails = 0;
    for (int v = first; v <= last; v++) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        CIKernel *k = [CIKernel kernelWithString:V[v]];
#pragma clang diagnostic pop
        if (!k) { printf("variant %d: kernel did not compile\n", v); fails++; continue; }
        CGRect ext = CGRectMake(0, 0, (int)(W / S), H);
        CIImage *o = [k applyWithExtent:ext roiCallback:^CGRect(int i, CGRect r) { return CGRectInset(CGRectMake(r.origin.x * S, r.origin.y, r.size.width * S, r.size.height), -8, -8); }
                              arguments:@[ src, [CIVector vectorWithX:S Y:1 Z:1 W:0] ]];
        int OW = (int)ext.size.width; uint8_t *a = calloc(OW * H, 4), *b = calloc(OW * H, 4);
        [gpu render:o toBitmap:a rowBytes:OW * 4 bounds:ext format:kCIFormatRGBA8 colorSpace:nil];
        [cpu render:o toBitmap:b rowBytes:OW * 4 bounds:ext format:kCIFormatRGBA8 colorSpace:nil];
        double d = 0; int rowsEqual = 1;
        for (int i = 0; i < OW * H * 4; i++) d += abs(a[i] - b[i]);
        for (int y = 1; y < H && rowsEqual; y++) if (memcmp(a, a + y * OW * 4, OW * 4)) rowsEqual = 0;
        d /= OW * H * 4; int bad = d > 1.5;
        printf("variant %d: mad %.2f%s %s\n", v, d, rowsEqual ? " (all GPU rows equal)" : "", bad ? "BAD" : "ok"); fails += bad;
    }
    // system Lanczos on the same source at several sizes / scales (CILANCZOS=WxH,scale)
    int sizes[][2] = { { 600, 300 }, { 1100, 300 }, { 1800, 1012 }, { 1850, 1980 }, { 3520, 1980 } }; float scales[] = { 0.7f, 0.35f };
    for (unsigned si = 0; si < sizeof sizes / sizeof *sizes; si++) for (unsigned sc = 0; sc < 2; sc++) {
        int w = sizes[si][0], h = sizes[si][1]; uint8_t *q = malloc((size_t)w * h * 4);
        for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) { uint8_t *p = q + ((size_t)y * w + x) * 4; p[0] = x * 255 / w; p[1] = y * 255 / h; p[2] = ((x / 16 + y / 16) & 1) ? 220 : 30; p[3] = 255; }
        CIImage *im = [CIImage imageWithBitmapData:[NSData dataWithBytesNoCopy:q length:(size_t)w * h * 4 freeWhenDone:YES] bytesPerRow:w * 4 size:CGSizeMake(w, h) format:kCIFormatRGBA8 colorSpace:nil];
        CIFilter *f = [CIFilter filterWithName:@"CILanczosScaleTransform"]; [f setValue:im forKey:kCIInputImageKey]; [f setValue:@(scales[sc]) forKey:kCIInputScaleKey]; [f setValue:@1.0 forKey:kCIInputAspectRatioKey];
        CIImage *o = f.outputImage; CGRect ext = CGRectIntegral(o.extent); int OW = ext.size.width, OH = ext.size.height;
        uint8_t *a = calloc((size_t)OW * OH, 4), *b = calloc((size_t)OW * OH, 4);
        [gpu render:o toBitmap:a rowBytes:OW * 4 bounds:ext format:kCIFormatRGBA8 colorSpace:nil];
        [cpu render:o toBitmap:b rowBytes:OW * 4 bounds:ext format:kCIFormatRGBA8 colorSpace:nil];
        double d = 0; for (size_t i = 0; i < (size_t)OW * OH * 4; i++) d += abs(a[i] - b[i]); d /= (double)OW * OH * 4; int bad = d > 1.5;
        double ma = 0, mb = 0; for (size_t i = 0; i < (size_t)OW * OH * 4; i++) { ma += a[i]; mb += b[i]; } ma /= (double)OW * OH * 4; mb /= (double)OW * OH * 4;
        printf("CILanczos %dx%d x%.2f -> %dx%d: mad %.2f (gpu mean %.1f cpu mean %.1f) %s\n", w, h, scales[sc], OW, OH, d, ma, mb, bad ? "BAD" : "ok"); fails += bad; free(a); free(b);
    }
    printf(fails ? "FAIL %d\n" : "PASS\n", fails); return fails != 0;
}}
