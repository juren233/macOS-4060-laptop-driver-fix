// surftrack: DYLD_INSERT_LIBRARIES diagnostic for Chrome's GPU process (read-only, no behaviour change).
// Follows every large IOSurface (>= 256x256) from creation (IOSurfaceCreate / IOSurfaceLookupFromMachPort / IOSurfaceLookup,
// or from the first CALayer setContents: that shows it, keyed then on the setContents caller)
// to its destruction and reports, every 5 s on stderr, by creating image+offset and size:
//  - created / destroyed, lifetime (median, max)
//  - IOSurfaceIsInUse() calls on it: total, answered "in use", longest stretch it stayed "in use" after its first query
//  - who asked IsInUse (image+offset) and how long the plugin held its own use count per hold
// build: clang -arch x86_64 -dynamiclib -fno-objc-arc -O1 -o surftrack.dylib surftrack.m -framework Foundation -framework IOSurface && codesign -f -s - surftrack.dylib
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach/mach_time.h>
#import <os/lock.h>
#import <dlfcn.h>
#import <crt_externs.h>
#define DYLD_INTERPOSE(_r, _o) __attribute__((used)) static struct { const void *r; const void *o; } _interpose_##_o __attribute__((section("__DATA,__interpose"))) = { (const void *)(unsigned long)&_r, (const void *)(unsigned long)&_o };
static double tb; static os_unfair_lock lk = OS_UNFAIR_LOCK_INIT; static int on;
static double now_ms(void) { return mach_absolute_time() * tb / 1e6; }
typedef struct { void *s; uint32_t id, w, h, fmt; double t0, firstQ, lastBusy, holdT; unsigned q, qBusy, holds; double holdMs; char site[64]; char name[48]; struct Agg *a; double tSet, tUnset, lastBusyU, firstFreeU; unsigned sets; } Ent;
#define NE 8192
static Ent tab[NE];
typedef struct Agg { char key[128]; char name[48]; unsigned created, died, alive; double lifeSum, lifeMax; unsigned long long q, qBusy; double busyAfterQMax, busyAfterQSum; unsigned busyN; unsigned holds; double holdMs, holdMax; double lives[512]; unsigned nl; unsigned shown, unsetN, unsetFreeN, neverShown; double onScreen[512], relBusy[512], relFree[512]; unsigned nos, nrb, nrf; } Agg;
static NSMutableDictionary<NSString *, NSValue *> *aggs; static Agg aggPool[256]; static int naggs;
static NSMutableDictionary<NSString *, NSNumber *> *askers;
static void site_of(void *ra, char *out, size_t n) {
    Dl_info d; if (dladdr(ra, &d) && d.dli_fname) { const char *b = strrchr(d.dli_fname, '/'); snprintf(out, n, "%s+0x%lx", b ? b + 1 : d.dli_fname, (unsigned long)((char *)ra - (char *)d.dli_fbase)); }
    else snprintf(out, n, "%p", ra);
}
static Ent *find(void *s, int make) {
    unsigned h = (unsigned)(((uintptr_t)s >> 4) * 2654435761u) % NE;
    for (unsigned i = 0; i < NE; i++) { Ent *e = &tab[(h + i) % NE]; if (e->s == s) return e; if (!e->s) { if (!make) return NULL; memset(e, 0, sizeof *e); e->s = s; return e; } }
    return NULL;
}
static void del(Ent *e) { // re-insert the following cluster (open addressing)
    unsigned i = (unsigned)(e - tab); e->s = NULL;
    for (unsigned j = (i + 1) % NE; tab[j].s; j = (j + 1) % NE) { Ent t = tab[j]; tab[j].s = NULL; Ent *n = find(t.s, 1); *n = t; }
}
static Agg *agg(Ent *e) {
    NSString *k = [NSString stringWithFormat:@"%s %ux%u %.4s", e->site, e->w, e->h, (char *)&(uint32_t){ CFSwapInt32HostToBig(e->fmt) }];
    NSValue *v = aggs[k]; if (v) return v.pointerValue;
    if (naggs >= 256) return NULL;
    Agg *a = &aggPool[naggs++]; memset(a, 0, sizeof *a); snprintf(a->key, sizeof a->key, "%s", k.UTF8String); aggs[k] = [NSValue valueWithPointer:a]; return a;
}
@interface SurftrackDeath : NSObject { @public void *s; } @end
@implementation SurftrackDeath
- (void)dealloc {
    const double t = now_ms();
    os_unfair_lock_lock(&lk);
    Ent *e = find(s, 0);
    if (e) { Agg *a = e->a;
        if (a) { a->died++; a->alive--; const double life = t - e->t0; a->lifeSum += life; if (life > a->lifeMax) a->lifeMax = life; if (a->nl < 512) a->lives[a->nl++] = life;
                 a->q += e->q; a->qBusy += e->qBusy; a->holds += e->holds; a->holdMs += e->holdMs;
                 if (!e->sets) a->neverShown++; else a->shown++;
                 if (e->tSet && e->tUnset > e->tSet && a->nos < 512) a->onScreen[a->nos++] = e->tUnset - e->tSet;
                 if (e->tUnset) { a->unsetN++; if (a->nrb < 512) a->relBusy[a->nrb++] = e->lastBusyU > e->tUnset ? e->lastBusyU - e->tUnset : 0;
                     if (e->firstFreeU) { a->unsetFreeN++; if (a->nrf < 512) a->relFree[a->nrf++] = e->firstFreeU - e->tUnset; } }
                 if (e->q) { const double b = e->lastBusy > e->firstQ ? e->lastBusy - e->firstQ : 0; a->busyAfterQSum += b; a->busyN++; if (b > a->busyAfterQMax) a->busyAfterQMax = b; } }
        del(e); }
    os_unfair_lock_unlock(&lk);
    [super dealloc];
}
@end
static char kKey;
static void track(IOSurfaceRef s, void *ra) {
    if (!on || !s) return;
    const uint32_t w = (uint32_t)IOSurfaceGetWidth(s), h = (uint32_t)IOSurfaceGetHeight(s);
    if (w < 256 || h < 256) return;
    os_unfair_lock_lock(&lk);
    Ent *e = find(s, 0);
    if (e) { os_unfair_lock_unlock(&lk); return; }
    e = find(s, 1);
    if (e) { e->id = IOSurfaceGetID(s); e->w = w; e->h = h; e->fmt = IOSurfaceGetPixelFormat(s); e->t0 = now_ms(); site_of(ra, e->site, sizeof e->site);
             Agg *a = e->a = agg(e); if (a) { a->created++; a->alive++; } }
    os_unfair_lock_unlock(&lk);
    if (!e) return;
    SurftrackDeath *d = [SurftrackDeath new]; d->s = (void *)s;
    objc_setAssociatedObject((__bridge id)s, &kKey, d, OBJC_ASSOCIATION_RETAIN_NONATOMIC); [d release];
}
static IOSurfaceRef my_create(CFDictionaryRef p) { IOSurfaceRef s = IOSurfaceCreate(p); track(s, __builtin_return_address(0)); return s; }
static IOSurfaceRef my_lookup_port(mach_port_t p) { IOSurfaceRef s = IOSurfaceLookupFromMachPort(p); track(s, __builtin_return_address(0)); return s; }
static IOSurfaceRef my_lookup(IOSurfaceID i) { IOSurfaceRef s = IOSurfaceLookup(i); track(s, __builtin_return_address(0)); return s; }
static Boolean my_inuse(IOSurfaceRef s) {
    const Boolean r = IOSurfaceIsInUse(s);
    if (!on || !s) return r;
    const double t = now_ms(); char site[64]; site_of(__builtin_return_address(0), site, sizeof site);
    os_unfair_lock_lock(&lk);
    Ent *e = find(s, 0);
    if (e) { if (!e->q) { e->firstQ = t;
                 if (!e->name[0]) { CFTypeRef n = IOSurfaceCopyValue(s, kIOSurfaceName); if (n && CFGetTypeID(n) == CFStringGetTypeID()) CFStringGetCString(n, e->name, sizeof e->name, kCFStringEncodingUTF8); if (n) CFRelease(n); if (e->a && e->name[0]) memcpy(e->a->name, e->name, sizeof e->name); } }
             e->q++; if (r) { e->qBusy++; e->lastBusy = t; }
             if (e->tUnset) { if (r) e->lastBusyU = t; else if (!e->firstFreeU) e->firstFreeU = t; } }
    NSString *k = [NSString stringWithFormat:@"%s %s", site, r ? "busy" : "free"]; askers[k] = @(askers[k].unsignedLongLongValue + 1);
    os_unfair_lock_unlock(&lk);
    return r;
}
static void my_inc(IOSurfaceRef s) {
    IOSurfaceIncrementUseCount(s);
    if (!on) return;
    os_unfair_lock_lock(&lk); Ent *e = find(s, 0); if (e) { e->holds++; e->holdT = now_ms(); } os_unfair_lock_unlock(&lk);
}
static void my_dec(IOSurfaceRef s) {
    IOSurfaceDecrementUseCount(s);
    if (!on) return;
    os_unfair_lock_lock(&lk); Ent *e = find(s, 0); if (e && e->holdT) { e->holdMs += now_ms() - e->holdT; e->holdT = 0; } os_unfair_lock_unlock(&lk);
}
DYLD_INTERPOSE(my_create, IOSurfaceCreate)
DYLD_INTERPOSE(my_lookup_port, IOSurfaceLookupFromMachPort)
DYLD_INTERPOSE(my_lookup, IOSurfaceLookup)
DYLD_INTERPOSE(my_inuse, IOSurfaceIsInUse)
DYLD_INTERPOSE(my_inc, IOSurfaceIncrementUseCount)
DYLD_INTERPOSE(my_dec, IOSurfaceDecrementUseCount)
static void (*origSet)(id, SEL, id);
static void mySet(id self, SEL sel, id c) {
    if (on) {
        id old = ((id (*)(id, SEL))objc_msgSend)(self, sel_registerName("contents"));
        if (old != c) {
            const double t = now_ms(); const CFTypeID st = IOSurfaceGetTypeID();
            // surfaces that arrive by other routes (video frames from VideoToolbox/CoreVideo) start being followed when shown
            if (c && CFGetTypeID((__bridge CFTypeRef)c) == st) track((__bridge IOSurfaceRef)c, __builtin_return_address(0));
            os_unfair_lock_lock(&lk);
            if (old && CFGetTypeID((__bridge CFTypeRef)old) == st) { Ent *e = find((__bridge void *)old, 0); if (e) { e->tUnset = t; e->lastBusyU = 0; e->firstFreeU = 0; } }
            if (c && CFGetTypeID((__bridge CFTypeRef)c) == st) { Ent *e = find((__bridge void *)c, 0); if (e) { e->tSet = t; e->tUnset = 0; e->sets++; } }
            os_unfair_lock_unlock(&lk);
        }
    }
    origSet(self, sel, c);
}
static double med(double *v, unsigned n) { if (!n) return 0; extern int dcmp(const void *, const void *); qsort(v, n, sizeof *v, dcmp); return v[n / 2]; }
static double pct(double *v, unsigned n, double p) { return n ? v[(unsigned)(n * p) < n ? (unsigned)(n * p) : n - 1] : 0; }
int dcmp(const void *a, const void *b) { double x = *(double *)a, y = *(double *)b; return x < y ? -1 : x > y; }
static void report(void) {
    os_unfair_lock_lock(&lk);
    fprintf(stderr, "surftrack[%d] ---- per creator/size: created died alive | life med/max ms | IsInUse q busy, busy-after-first-q avg/max ms | plugin holds, avg hold ms\n", getpid());
    for (int i = 0; i < naggs; i++) { Agg *a = &aggPool[i]; if (!a->created && !a->died) continue;
        qsort(a->lives, a->nl, sizeof(double), dcmp);
        fprintf(stderr, "surftrack[%d] %s [%s]: %u %u %u | %.1f/%.1f | %llu %llu, %.2f/%.1f | %u, %.2f\n", getpid(), a->key, a->name, a->created, a->died, a->alive,
                a->nl ? a->lives[a->nl / 2] : 0.0, a->lifeMax, a->q, a->qBusy, a->busyN ? a->busyAfterQSum / a->busyN : 0.0, a->busyAfterQMax, a->holds, a->holds ? a->holdMs / a->holds : 0.0);
        fprintf(stderr, "surftrack[%d]     shown as layer contents %u, never shown %u | on screen med %.1f ms | after Chrome replaced it: still busy med %.1f p90 %.1f ms, first seen free med %.1f p90 %.1f ms (%u of %u seen free)\n", getpid(),
                a->shown, a->neverShown, med(a->onScreen, a->nos), med(a->relBusy, a->nrb), pct(a->relBusy, a->nrb, .9), med(a->relFree, a->nrf), pct(a->relFree, a->nrf, .9), a->unsetFreeN, a->unsetN);
        const unsigned al = a->alive; memset((char *)a + offsetof(Agg, created), 0, sizeof *a - offsetof(Agg, created)); a->alive = al; }
    for (NSString *k in [askers.allKeys sortedArrayUsingSelector:@selector(compare:)]) fprintf(stderr, "surftrack[%d]   IsInUse from %s %llu\n", getpid(), k.UTF8String, askers[k].unsignedLongLongValue);
    [askers removeAllObjects];
    os_unfair_lock_unlock(&lk);
}
__attribute__((constructor)) static void surftrack_init(void) {
    mach_timebase_info_data_t i; mach_timebase_info(&i); tb = (double)i.numer / i.denom;
    // Only the GPU process (the browser and renderers inherit the variable too).
    char **av = *_NSGetArgv(); int ac = *_NSGetArgc(), gpu = 0;
    for (int k = 0; k < ac; k++) if (!strcmp(av[k], "--type=gpu-process")) gpu = 1;
    if (!gpu && !getenv("SURFTRACK_ALL")) return;
    aggs = [NSMutableDictionary new]; askers = [NSMutableDictionary new]; on = 1;
    fprintf(stderr, "surftrack[%d]: installed\n", getpid());
    static dispatch_source_t t; t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), 5 * NSEC_PER_SEC, NSEC_PER_SEC);
    dispatch_source_set_event_handler(t, ^{ report(); }); dispatch_resume(t);
    static dispatch_source_t p; p = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_timer(p, DISPATCH_TIME_NOW, NSEC_PER_SEC / 20, NSEC_PER_SEC / 100);
    dispatch_source_set_event_handler(p, ^{ Class c = objc_getClass("CALayer"); if (!c) return;
        Method m = class_getInstanceMethod(c, sel_registerName("setContents:")); origSet = (void *)method_getImplementation(m); method_setImplementation(m, (IMP)mySet);
        fprintf(stderr, "surftrack[%d]: CALayer setContents: hooked\n", getpid()); dispatch_source_cancel(p); });
    dispatch_resume(p);
}
