// schedwhy: DYLD_INSERT_LIBRARIES diagnostic for the installed NVMTL plugin (read-only, no behaviour change).
// Swizzles -[NVMTLCommandBuffer nvmtlSubmitAhead / nvmtlAdvancePart / waitUntilScheduled] and counts, every 5 s on stderr:
//  - why the submit-ahead pass stopped at a buffer (wait not promised, empty last part, worker hold, host-pointer buffer, ...)
//  - waitUntilScheduled calls that had to wait, their time, and the stop reason last seen on that buffer's queue.
// build: clang -arch x86_64 -dynamiclib -fno-objc-arc -O1 -o schedwhy.dylib schedwhy.m -framework Foundation && codesign -f -s - schedwhy.dylib
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <os/lock.h>
#import <mach/mach_time.h>
#import <stdatomic.h>
enum { R_STATE, R_HOLD, R_NULL, R_WAIT, R_NOCB, R_EMPTYLAST, R_HOSTPTR, R_OTHER, R_NONE, R_N };
static const char *kR[R_N] = { "state", "worker-hold", "null-part", "wait-unpromised", "no-cmdbuf", "empty-last-part", "host-ptr", "cap/other", "none" };
static ptrdiff_t o_parts, o_nextSubmit, o_nextPart, o_committed, o_done, o_err, o_sched, o_queue;
static ptrdiff_t p_wait, p_enc, p_res, p_surf, p_scratch, p_cmd, p_value, b_host;
static Class cPart, cBuf, cCB;
static _Atomic unsigned long long stops[R_N], aheadCalls, advCalls;
static _Atomic unsigned long long wN, wBlocked, wNs[R_N], wCnt[R_N], wOver1[R_N], wOver4[R_N], wSelf[R_N], partsHist[8], waitPos[4];
static __unsafe_unretained id workerCb;
static struct { void *q; int reason; void *cb; } qtab[16];
static os_unfair_lock qlock = OS_UNFAIR_LOCK_INIT;
static double tb;
#define IV(obj, off, T) (*(T *)((char *)(__bridge void *)(obj) + (off)))
static ptrdiff_t ivo(Class c, const char *n) { Ivar v = class_getInstanceVariable(c, n); if (!v) { fprintf(stderr, "schedwhy: no ivar %s\n", n); return -1; } return ivar_getOffset(v); }
static void qset(void *q, int r, void *cb) {
    os_unfair_lock_lock(&qlock);
    int k = -1; for (int i = 0; i < 16; i++) if (qtab[i].q == q || (!qtab[i].q && k < 0)) { k = i; if (qtab[i].q == q) break; }
    if (k >= 0) { qtab[k].q = q; qtab[k].reason = r; qtab[k].cb = cb; }
    os_unfair_lock_unlock(&qlock);
}
static int qget(void *q, void **cb) {
    int r = R_NONE; os_unfair_lock_lock(&qlock);
    for (int i = 0; i < 16; i++) if (qtab[i].q == q) { r = qtab[i].reason; *cb = qtab[i].cb; break; }
    os_unfair_lock_unlock(&qlock); return r;
}
static int classify(id self) {
    if (IV(self, o_done, BOOL) || IV(self, o_err, id) || !IV(self, o_committed, BOOL)) return R_STATE;
    if (self == workerCb) return R_HOLD;
    NSArray *parts = IV(self, o_parts, __unsafe_unretained NSArray *);
    NSUInteger ns = IV(self, o_nextSubmit, NSUInteger), np = IV(self, o_nextPart, NSUInteger);
    if (ns < np) ns = np;
    if (ns >= parts.count) return R_OTHER;
    id part = parts[ns];
    if (![part isKindOfClass:cPart]) return R_NULL;
    if (IV(part, p_wait, __unsafe_unretained id)) return R_WAIT;
    if (!IV(part, p_cmd, void *)) return R_NOCB;
    if (!IV(part, p_enc, unsigned) && ![IV(part, p_res, __unsafe_unretained NSSet *) count] && ![IV(part, p_surf, __unsafe_unretained NSSet *) count]
        && ![IV(part, p_scratch, __unsafe_unretained NSArray *) count]) return ns + 1 >= parts.count ? R_EMPTYLAST : R_OTHER;
    for (id r in IV(part, p_res, __unsafe_unretained NSSet *)) if ([r isKindOfClass:cBuf] && IV(r, b_host, void *)) return R_HOSTPTR;
    return R_OTHER;
}
static BOOL (*origAhead)(id, SEL); static BOOL (*origAdv)(id, SEL); static void (*origWUS)(id, SEL);
static BOOL myAhead(id self, SEL s) {
    atomic_fetch_add(&aheadCalls, 1);
    const BOOL r = origAhead(self, s);
    if (!r) { int k = classify(self); atomic_fetch_add(&stops[k], 1); qset((__bridge void *)IV(self, o_queue, __unsafe_unretained id), k, (__bridge void *)self); }
    return r;
}
static BOOL myAdv(id self, SEL s) {
    atomic_fetch_add(&advCalls, 1);
    @synchronized (cCB) { workerCb = self; }
    const BOOL r = origAdv(self, s);
    @synchronized (cCB) { workerCb = nil; }
    return r;
}
static void myWUS(id self, SEL s) {
    atomic_fetch_add(&wN, 1);
    const BOOL already = IV(self, o_sched, BOOL);
    void *bcb = NULL; int reason = R_NONE;
    NSUInteger np = 0, nparts = 0;
    if (!already) {
        reason = qget((__bridge void *)IV(self, o_queue, __unsafe_unretained id), &bcb);
        @synchronized (cCB) { NSArray *parts = IV(self, o_parts, __unsafe_unretained NSArray *); nparts = parts.count; np = IV(self, o_nextPart, NSUInteger); }
    }
    const uint64_t t0 = mach_absolute_time();
    origWUS(self, s);
    if (already) return;
    const double ns = (mach_absolute_time() - t0) * tb;
    atomic_fetch_add(&wBlocked, 1); atomic_fetch_add(&wNs[reason], (unsigned long long)ns); atomic_fetch_add(&wCnt[reason], 1);
    if (ns > 1e6) atomic_fetch_add(&wOver1[reason], 1);
    if (ns > 4e6) atomic_fetch_add(&wOver4[reason], 1);
    if (bcb == (__bridge void *)self) atomic_fetch_add(&wSelf[reason], 1);
    atomic_fetch_add(&partsHist[nparts < 7 ? nparts : 7], 1);
    atomic_fetch_add(&waitPos[np < 3 ? np : 3], 1);
}
static void report(void) {
    fprintf(stderr, "schedwhy[%d]: ahead calls %llu, worker advance calls %llu | stops:", getpid(), aheadCalls, advCalls);
    for (int i = 0; i < R_N; i++) if (stops[i]) fprintf(stderr, " %s %llu", kR[i], stops[i]);
    fprintf(stderr, "\nschedwhy[%d]: waitUntilScheduled %llu, not yet scheduled at entry %llu; by queue's last stop reason:", getpid(), wN, wBlocked);
    for (int i = 0; i < R_N; i++) if (wCnt[i]) fprintf(stderr, " [%s n %llu total %.1f ms >1ms %llu >4ms %llu waited-buffer-itself %llu]", kR[i], wCnt[i], wNs[i] / 1e6, wOver1[i], wOver4[i], wSelf[i]);
    fprintf(stderr, "\nschedwhy[%d]: waited buffers by part count 0..7+:", getpid());
    for (int i = 0; i < 8; i++) fprintf(stderr, " %llu", partsHist[i]);
    fprintf(stderr, " | worker at part 0/1/2/3+: %llu %llu %llu %llu\n", waitPos[0], waitPos[1], waitPos[2], waitPos[3]);
}
static BOOL install(void) {
    Class cb = objc_getClass("NVMTLCommandBuffer"); cPart = objc_getClass("NVMTLSubmissionPart"); cBuf = objc_getClass("NVMTLBuffer");
    if (!cb || !cPart || !cBuf) return NO;
    o_parts = ivo(cb, "_parts"); o_nextSubmit = ivo(cb, "_nextSubmit"); o_nextPart = ivo(cb, "_nextPart"); o_committed = ivo(cb, "_committed");
    o_done = ivo(cb, "_executionDone"); o_err = ivo(cb, "_cbError"); o_sched = ivo(cb, "_wasScheduled"); o_queue = ivo(cb, "_queue");
    p_wait = ivo(cPart, "waitEvent"); p_enc = ivo(cPart, "encoders"); p_res = ivo(cPart, "resources"); p_surf = ivo(cPart, "surfaces");
    p_scratch = ivo(cPart, "scratch"); p_cmd = ivo(cPart, "commands"); p_value = ivo(cPart, "value"); b_host = ivo(cBuf, "_hostPtr");
    if (o_parts < 0 || o_nextSubmit < 0 || o_nextPart < 0 || o_committed < 0 || o_done < 0 || o_err < 0 || o_sched < 0 || o_queue < 0 || p_wait < 0
        || p_enc < 0 || p_res < 0 || p_surf < 0 || p_scratch < 0 || p_cmd < 0 || b_host < 0) { fprintf(stderr, "schedwhy: layout mismatch, not installed\n"); return YES; }
    Method a = class_getInstanceMethod(cb, sel_registerName("nvmtlSubmitAhead")), v = class_getInstanceMethod(cb, sel_registerName("nvmtlAdvancePart")),
           w = class_getInstanceMethod(cb, sel_registerName("waitUntilScheduled"));
    if (!a || !v || !w) { fprintf(stderr, "schedwhy: methods missing, not installed\n"); return YES; }
    origAhead = (void *)method_getImplementation(a); origAdv = (void *)method_getImplementation(v); origWUS = (void *)method_getImplementation(w);
    cCB = cb; method_setImplementation(a, (IMP)myAhead); method_setImplementation(v, (IMP)myAdv); method_setImplementation(w, (IMP)myWUS);
    atexit(report);
    fprintf(stderr, "schedwhy[%d]: installed\n", getpid());
    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), 5 * NSEC_PER_SEC, NSEC_PER_SEC);
    dispatch_source_set_event_handler(t, ^{ if (wN) report(); }); dispatch_resume(t);
    static id keep; keep = t;
    return YES;
}
__attribute__((constructor)) static void schedwhy_init(void) {
    mach_timebase_info_data_t i; mach_timebase_info(&i); tb = (double)i.numer / i.denom;
    // Only Chrome's GPU process (and test binaries): the plugin loads lazily, so poll for its classes.
    __block int tries = 0;
    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_timer(t, DISPATCH_TIME_NOW, NSEC_PER_SEC / 20, NSEC_PER_SEC / 100);
    static id keep; keep = t;
    dispatch_source_set_event_handler(t, ^{ if (install() || ++tries > 20 * 120) dispatch_source_cancel(keep); });
    dispatch_resume(t);
}
