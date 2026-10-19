// fccap.dylib: DYLD_INSERT_LIBRARIES shim. Wraps the translator's nvmtl_translate_fc as the plugin dlsym()s it and, with
// FCCAP_DIR=<dir>, writes every call's input as <dir>/<n>.ll + <n>.fc (stage line, then "idx size hexbytes" per constant)
// and prints the call's wall time to stderr. Capture only: the call itself goes to the real translator unchanged.
// FCCAP_XLATE=<dylib>: the plugin's dlopen of libnvmtl_translate.dylib opens that build instead (test a staged translator
// in one process without installing it).
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <stdatomic.h>
typedef int (*fc_fn)(const char *, const char *, const uint32_t *, const uint32_t *, const uint8_t *const *, size_t, uint8_t **, size_t *, char *, size_t);
typedef int (*plain_fn)(const char *, const char *, uint8_t **, size_t *, char *, size_t);
static fc_fn real_fc; static plain_fn real_plain; static _Atomic unsigned seq;
static int hook_fc(const char *ll, const char *st, const uint32_t *idx, const uint32_t *sz, const uint8_t *const *pay, size_t n,
                   uint8_t **out, size_t *olen, char *e, size_t elen) {
    const char *d = getenv("FCCAP_DIR"); unsigned k = atomic_fetch_add(&seq, 1);
    if (d && *d) {
        char p[1024]; snprintf(p, sizeof p, "%s/%d-%u.ll", d, getpid(), k); FILE *f = fopen(p, "wb");
        if (f) { fwrite(ll, 1, strlen(ll), f); fclose(f); }
        snprintf(p, sizeof p, "%s/%d-%u.fc", d, getpid(), k); f = fopen(p, "w");
        if (f) { fprintf(f, "%s\n", st); for (size_t i = 0; i < n; i++) { fprintf(f, "%u %u", idx[i], sz[i]);
                 for (uint32_t b = 0; b < sz[i]; b++) fprintf(f, " %02x", pay[i][b]); fprintf(f, "\n"); } fclose(f); }
    }
    uint64_t t0 = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
    int rc = real_fc(ll, st, idx, sz, pay, n, out, olen, e, elen);
    fprintf(stderr, "fccap: call %u %s n %zu rc %d %zu B %.1f ms\n", k, st, n, rc, rc ? 0 : *olen,
            (clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - t0) / 1e6);
    return rc;
}
// nvmtl_translate (no function constants): written as <n>.ll + <n>.fc with the single line "<stage> plain"
static int hook_plain(const char *ll, const char *st, uint8_t **out, size_t *olen, char *e, size_t elen) {
    const char *d = getenv("FCCAP_DIR"); unsigned k = atomic_fetch_add(&seq, 1);
    if (d && *d) {
        char p[1024]; snprintf(p, sizeof p, "%s/%d-%u.ll", d, getpid(), k); FILE *f = fopen(p, "wb");
        if (f) { fwrite(ll, 1, strlen(ll), f); fclose(f); }
        snprintf(p, sizeof p, "%s/%d-%u.fc", d, getpid(), k); f = fopen(p, "w");
        if (f) { fprintf(f, "%s plain\n", st); fclose(f); }
    }
    uint64_t t0 = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
    int rc = real_plain(ll, st, out, olen, e, elen);
    if (getenv("FCCAP_VERBOSE")) fprintf(stderr, "fccap: call %u %s plain rc %d %zu B %.1f ms\n", k, st, rc, rc ? 0 : *olen,
            (clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - t0) / 1e6);
    return rc;
}
static void *my_dlsym(void *h, const char *s) {
    void *r = dlsym(h, s);
    if (r && s && !strcmp(s, "nvmtl_translate_fc")) { real_fc = (fc_fn)r; return (void *)hook_fc; }
    if (r && s && !strcmp(s, "nvmtl_translate")) { real_plain = (plain_fn)r; return (void *)hook_plain; }
    return r;
}
static void *my_dlopen(const char *path, int mode) {
    const char *x = getenv("FCCAP_XLATE");
    if (x && *x && path) { size_t n = strlen(path), k = strlen("/libnvmtl_translate.dylib");
        if (n >= k && !strcmp(path + n - k, "/libnvmtl_translate.dylib")) { fprintf(stderr, "fccap: translator %s\n", x); path = x; } }
    return dlopen(path, mode);
}
__attribute__((used, section("__DATA,__interpose"))) static struct { void *n, *o; } ip[] = {
    { (void *)my_dlsym, (void *)dlsym }, { (void *)my_dlopen, (void *)dlopen } };
