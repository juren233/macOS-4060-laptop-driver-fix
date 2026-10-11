#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>
#import <CoreVideo/CoreVideo.h>
static void t(IOSurfaceRef s, const char *nm, IOSurfaceLockOptions o, int write) {
    uint32_t before = IOSurfaceGetSeed(s), us = 0;
    IOSurfaceLock(s, o, NULL); if (write) ((uint8_t *)IOSurfaceGetBaseAddress(s))[0]++; IOSurfaceUnlock(s, o, &us);
    printf("  %-34s write=%d seed %u -> %u (unlock reported %u)  %s\n", nm, write, before, IOSurfaceGetSeed(s), us, IOSurfaceGetSeed(s) != before ? "BUMPED" : "unchanged");
}
int main(void) { @autoreleasepool {
    IOSurfaceRef s = IOSurfaceCreate((__bridge CFDictionaryRef)@{ (id)kIOSurfaceWidth: @512, (id)kIOSurfaceHeight: @512, (id)kIOSurfaceBytesPerElement: @4, (id)kIOSurfacePixelFormat: @(0x42475241) });
    t(s, "lock 0", 0, 1); t(s, "lock ReadOnly", kIOSurfaceLockReadOnly, 0); t(s, "lock AvoidSync", kIOSurfaceLockAvoidSync, 1);
    t(s, "lock AvoidSync|ReadOnly", kIOSurfaceLockAvoidSync | kIOSurfaceLockReadOnly, 0); t(s, "lock 0 (no actual write)", 0, 0);
    CVPixelBufferRef pb = NULL; CVPixelBufferCreate(NULL, 512, 512, kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)@{ (id)kCVPixelBufferIOSurfacePropertiesKey: @{} }, &pb); IOSurfaceRef c = CVPixelBufferGetIOSurface(pb);
    printf("CVPixelBuffer:\n"); uint32_t b = IOSurfaceGetSeed(c); CVPixelBufferLockBaseAddress(pb, 0); ((uint8_t *)CVPixelBufferGetBaseAddress(pb))[0]++; CVPixelBufferUnlockBaseAddress(pb, 0);
    printf("  CVPixelBufferLock/Unlock write     seed %u -> %u %s\n", b, IOSurfaceGetSeed(c), IOSurfaceGetSeed(c) != b ? "BUMPED" : "unchanged");
    return 0; } }
