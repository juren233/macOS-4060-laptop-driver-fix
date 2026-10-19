// fcrun <translator dylib> <capture.ll> [reps] : replays one nvmtl_translate_fc call captured by fccap.dylib
// (<capture>.ll + <capture>.fc) and prints "<name> rc <rc> <bytes> B <ms> ms md5-ish <hash>" per rep.
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>
typedef int (*fc_fn)(const char *, const char *, const uint32_t *, const uint32_t *, const uint8_t *const *, size_t, uint8_t **, size_t *, char *, size_t);
typedef void (*free_fn)(uint8_t *, size_t);
static char *slurp(const char *p) { FILE *f = fopen(p, "rb"); if (!f) return NULL; fseek(f, 0, SEEK_END); long n = ftell(f); rewind(f);
    char *b = malloc(n + 1); if (fread(b, 1, n, f) != (size_t)n) { fclose(f); free(b); return NULL; } b[n] = 0; fclose(f); return b; }
int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: fcrun <dylib> <capture.ll> [reps] [out.spv]\n"); return 2; }
    int reps = argc > 3 ? atoi(argv[3]) : 1; if (reps < 1 || reps > 50) reps = 1;
    void *h = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL); if (!h) { fprintf(stderr, "dlopen: %s\n", dlerror()); return 1; }
    fc_fn fc = (fc_fn)dlsym(h, "nvmtl_translate_fc"); free_fn fr = (free_fn)dlsym(h, "nvmtl_translate_free");
    if (!fc) { fprintf(stderr, "no nvmtl_translate_fc\n"); return 1; }
    // as the plugin does at load: formatless storage-image reads/writes on (caps 3)
    void (*setcaps)(uint32_t) = (void (*)(uint32_t))dlsym(h, "nvmtl_translate_set_caps"); if (setcaps) setcaps(3u);
    char *ll = slurp(argv[2]); if (!ll) { perror(argv[2]); return 1; }
    char fp[4096]; snprintf(fp, sizeof fp, "%.*s.fc", (int)(strlen(argv[2]) - 3), argv[2]);
    FILE *f = fopen(fp, "r"); if (!f) { perror(fp); return 1; }
    char st[32] = {0}, kind[16] = {0}; if (fscanf(f, "%31s", st) != 1) return 1;
    // "<stage> plain": a capture of nvmtl_translate, replayed through it
    long pos = ftell(f); int plain = fscanf(f, "%15s", kind) == 1 && !strcmp(kind, "plain"); if (!plain) fseek(f, pos, SEEK_SET);
    typedef int (*plain_fn)(const char *, const char *, uint8_t **, size_t *, char *, size_t);
    plain_fn pl = (plain_fn)dlsym(h, "nvmtl_translate");
    uint32_t idx[256], sz[256]; uint8_t bytes[256][64]; const uint8_t *pay[256]; size_t n = 0;
    while (n < 256 && fscanf(f, "%u %u", &idx[n], &sz[n]) == 2) {
        if (sz[n] > 64) return 1;
        for (uint32_t b = 0; b < sz[n]; b++) { unsigned v; if (fscanf(f, "%x", &v) != 1) return 1; bytes[n][b] = (uint8_t)v; }
        pay[n] = bytes[n]; n++;
    }
    fclose(f);
    if (getenv("FCRUN_NOFC")) n = 0;   // the same module with no constant supplied: what specialization saves
    for (int r = 0; r < reps; r++) {
        uint8_t *out = NULL; size_t len = 0; char e[600] = {0};
        uint64_t t0 = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
        int rc = plain ? pl(ll, st, &out, &len, e, sizeof e) : fc(ll, st, idx, sz, pay, n, &out, &len, e, sizeof e);
        double ms = (clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - t0) / 1e6;
        uint64_t hsh = 1469598103934665603ULL; for (size_t i = 0; i < len; i++) { hsh ^= out[i]; hsh *= 1099511628211ULL; }
        printf("%s %s%s n %zu rc %d %zu B %.1f ms fnv %016llx %s\n", strrchr(argv[2], '/') ? strrchr(argv[2], '/') + 1 : argv[2], st, plain ? " plain" : "", n, rc, len, ms,
               (unsigned long long)hsh, rc ? e : "");
        fflush(stdout);
        if (!rc && r == 0 && argc > 4) { FILE *o = fopen(argv[4], "wb"); if (o) { fwrite(out, 1, len, o); fclose(o); } }
        if (!rc && out && fr) fr(out, len);
    }
    return 0;
}
