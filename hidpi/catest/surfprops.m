#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>
#import <CoreVideo/CoreVideo.h>
int main(void) { @autoreleasepool { int W = 3200, H = 1700;
    IOSurfaceRef a = IOSurfaceCreate((__bridge CFDictionaryRef)@{ (id)kIOSurfaceWidth: @(W), (id)kIOSurfaceHeight: @(H), (id)kIOSurfaceBytesPerElement: @4, (id)kIOSurfacePixelFormat: @'BGRA' });
    CVPixelBufferRef pb = NULL; CVPixelBufferCreate(NULL, W, H, kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)@{ (id)kCVPixelBufferIOSurfacePropertiesKey: @{}, (id)kCVPixelBufferMetalCompatibilityKey: @YES }, &pb);
    IOSurfaceRef b = CVPixelBufferGetIOSurface(pb);
    for (int i = 0; i < 2; i++) { IOSurfaceRef s = i ? b : a; printf("== %s: pitch %zu allocSize %zu planes %zu bpe %zu elemW %zu\n", i ? "CVPixelBuffer" : "IOSurfaceCreate", IOSurfaceGetBytesPerRow(s), IOSurfaceGetAllocSize(s), IOSurfaceGetPlaneCount(s), IOSurfaceGetBytesPerElement(s), IOSurfaceGetElementWidth(s));
        CFDictionaryRef d = IOSurfaceCopyAllValues(s); printf("%s\n", [[(__bridge NSDictionary *)d description] UTF8String]); }
    return 0; } }
