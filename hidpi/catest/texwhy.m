// texwhy: DYLD_INSERT_LIBRARIES diagnostic - times -[NVMTLDevice newTextureWithDescriptor:iosurface:plane:] and reports, every 5 s on stderr,
// calls / ms / distinct IOSurface IDs / repeats of an ID seen before (what a per-surface VRAM import cache would save), by surface kind.
// build: clang -arch x86_64 -dynamiclib -fno-objc-arc -O1 -o texwhy.dylib texwhy.m -framework Foundation -framework IOSurface && codesign -f -s - texwhy.dylib
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>
#import <objc/runtime.h>
#import <mach/mach_time.h>
#import <os/lock.h>
static double tb; static os_unfair_lock lk = OS_UNFAIR_LOCK_INIT;
static NSMutableDictionary *seen; // id -> @[count, lastPtr]
static unsigned long long sameSurf[2], newSurf[2]; static double gapSum[2]; static unsigned long long gapN[2], gapLt1[2];
static unsigned long long calls[2], ns[2], repeatId[2], repeatPtr[2], big[2]; // [0] single-plane, [1] multi-plane
static id (*orig)(id, SEL, id, IOSurfaceRef, NSUInteger);
static id my(id self, SEL s, id d, IOSurfaceRef surf, NSUInteger plane) {
    const uint64_t t0 = mach_absolute_time();
    id r = orig(self, s, d, surf, plane);
    const double dt = (mach_absolute_time() - t0) * tb;
    if (!surf) return r;
    const int k = IOSurfaceGetPlaneCount(surf) > 1;
    os_unfair_lock_lock(&lk);
    calls[k]++; ns[k] += (unsigned long long)dt; if (dt > 1e6) big[k]++;
    { // token: a per-surface value only this process sets - tells a surface seen before from a new one that got a recycled ID
        static unsigned long long next = 1; CFTypeRef v = IOSurfaceCopyValue(surf, CFSTR("texwhy.token"));
        const double now = mach_absolute_time() * tb / 1e9;
        if (v && CFGetTypeID(v) == CFArrayGetTypeID()) { sameSurf[k]++; double last = [((__bridge NSArray *)v)[1] doubleValue]; gapSum[k] += now - last; gapN[k]++; if (now - last < 1.0) gapLt1[k]++; }
        else newSurf[k]++;
        if (v) CFRelease(v);
        IOSurfaceSetValue(surf, CFSTR("texwhy.token"), (__bridge CFTypeRef)@[@(next++), @(now)]);
    }
    NSNumber *key = @(((unsigned long long)IOSurfaceGetID(surf) << 8) | plane);
    NSArray *e = seen[key];
    if (e) { repeatId[k]++; if ([e[1] unsignedLongLongValue] == (unsigned long long)(uintptr_t)surf) repeatPtr[k]++; }
    seen[key] = @[@([e[0] unsignedLongLongValue] + 1), @((unsigned long long)(uintptr_t)surf), @(IOSurfaceGetWidth(surf) * 100000 + IOSurfaceGetHeight(surf))];
    os_unfair_lock_unlock(&lk);
    return r;
}
static void report(void) {
    os_unfair_lock_lock(&lk);
    for (int k = 0; k < 2; k++) if (calls[k])
        fprintf(stderr, "texwhy[%d] %s: %llu textures, %.1f ms total (%.3f ms avg, %llu >1ms), same surface ID before %llu (same IOSurfaceRef %llu)\n", getpid(),
                k ? "multi-plane" : "single-plane", calls[k], ns[k] / 1e6, ns[k] / 1e6 / calls[k], big[k], repeatId[k], repeatPtr[k]);
    for (int k = 0; k < 2; k++) if (calls[k])
        fprintf(stderr, "texwhy[%d] %s: really the same surface again %llu (gap avg %.2f s, <1 s %llu), new surface %llu\n", getpid(), k ? "multi-plane" : "single-plane",
                sameSurf[k], gapN[k] ? gapSum[k] / gapN[k] : 0.0, gapLt1[k], newSurf[k]);
    NSArray *top = [seen keysSortedByValueUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) { return [b[0] compare:a[0]]; }];
    fprintf(stderr, "texwhy[%d] %lu distinct surfaces; busiest:", getpid(), (unsigned long)seen.count);
    for (NSUInteger i = 0; i < top.count && i < 8; i++) { NSArray *e = seen[top[i]]; unsigned long long sz = [e[2] unsignedLongLongValue];
        fprintf(stderr, " %llu:%llu %llux%llu x%llu", [top[i] unsignedLongLongValue] >> 8, [top[i] unsignedLongLongValue] & 255, sz / 100000, sz % 100000, [e[0] unsignedLongLongValue]); }
    fprintf(stderr, "\n");
    os_unfair_lock_unlock(&lk);
}
static BOOL install(void) {
    Class c = objc_getClass("NVMTLDevice"); if (!c) return NO;
    Method m = class_getInstanceMethod(c, sel_registerName("newTextureWithDescriptor:iosurface:plane:")); if (!m) return YES;
    seen = [NSMutableDictionary new];
    orig = (void *)method_getImplementation(m); method_setImplementation(m, (IMP)my);
    fprintf(stderr, "texwhy[%d]: installed\n", getpid());
    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), 5 * NSEC_PER_SEC, NSEC_PER_SEC);
    dispatch_source_set_event_handler(t, ^{ if (calls[0] + calls[1]) report(); }); dispatch_resume(t);
    atexit(report);
    return YES;
}
__attribute__((constructor)) static void texwhy_init(void) {
    mach_timebase_info_data_t i; mach_timebase_info(&i); tb = (double)i.numer / i.denom;
    __block int tries = 0;
    static dispatch_source_t t; t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_timer(t, DISPATCH_TIME_NOW, NSEC_PER_SEC / 20, NSEC_PER_SEC / 100);
    dispatch_source_set_event_handler(t, ^{ if (install() || ++tries > 20 * 120) dispatch_source_cancel(t); });
    dispatch_resume(t);
}
