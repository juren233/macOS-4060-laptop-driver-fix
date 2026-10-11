// Internal-panel backlight through NVKMS (NVRM user client selector 4 = nvkms ioctl).
//   nvbl            list dpys that expose NV_KMS_DPY_ATTRIBUTE_BACKLIGHT_BRIGHTNESS (range + current)
//   nvbl get        print current brightness of the first backlight dpy
//   nvbl set N      set brightness (clamped to the reported range)
//   nvbl +N | -N    step up/down
// When NVKMS has no backlight dpy (GSP refuses NV0073 GET/SET_BACKLIGHT_BRIGHTNESS, as on this Clevo where
// the SBIOS owns the panel), the same commands use the ACPI _BCL/_BCM/_BQC sysctls published by NVDSM.kext;
// values are then percent of the _BCL range, and +N/-N always move at least one _BCL level.
#include <stdio.h>
#include <sys/sysctl.h>
#include <stdlib.h>
#include <string.h>
#include <IOKit/IOKitLib.h>
#include "nvkms-api.h"
#include "nv_dpy_id.h"

static io_connect_t gConn;
static int kms(uint32_t cmd, void *p, size_t sz) {
    uint64_t in = cmd; size_t out = sz;
    kern_return_t kr = IOConnectCallMethod(gConn, 4, &in, 1, p, sz, NULL, NULL, p, &out);
    return kr == KERN_SUCCESS ? 0 : (int)kr;
}

static int acpi_levels(unsigned *lv, int max) {
    char buf[512]; size_t len = sizeof buf;
    if (sysctlbyname("debug.nvdsm_bl_levels", buf, &len, NULL, 0) || !buf[0]) return 0;
    char *p = strchr(buf, '|');
    int n = 0;
    while (p && n < max) { char *e; unsigned long v = strtoul(p + 1, &e, 10); if (e == p + 1) break; lv[n++] = (unsigned)v; p = e; }
    return n;
}
static int acpi_get(const char *name, int *v) { size_t len = sizeof *v; return sysctlbyname(name, v, &len, NULL, 0); }
static int acpi_set(const char *name, int v) { return sysctlbyname(name, NULL, NULL, &v, sizeof v); }

static int acpi_main(int argc, char **argv, int list) {
    unsigned lv[128]; int n = acpi_levels(lv, 128), raw = 0, pct = 0;
    if (n <= 0) { fprintf(stderr, "no NVKMS backlight and no ACPI backlight (NVDSM.kext loaded? sysctl debug.nvdsm_bl_levels)\n"); return 2; }
    if (acpi_get("debug.nvdsm_bl_level", &raw) || acpi_get("debug.nvdsm_bl_pct", &pct)) { perror("sysctl debug.nvdsm_bl_*"); return 1; }
    if (list) {
        printf("ACPI backlight (LCD _BCL/_BCM/_BQC): %d levels %u..%u, current level %d = %d%%\n", n, lv[0], lv[n - 1], raw, pct);
        return 0;
    }
    if (!strcmp(argv[1], "get")) { printf("%d\n", pct); return 0; }
    int target;
    if (!strcmp(argv[1], "set") && argc > 2) {
        if (acpi_set("debug.nvdsm_bl_pct", atoi(argv[2]))) { perror("set"); return 1; }
    } else if (argv[1][0] == '+' || argv[1][0] == '-') {
        int d = atoi(argv[1]);
        target = pct + d;
        if (acpi_set("debug.nvdsm_bl_pct", target < 0 ? 0 : target > 100 ? 100 : target)) { perror("set"); return 1; }
        int now = raw;
        acpi_get("debug.nvdsm_bl_level", &now);
        if (now == raw && d) {   // snapped back to the same level: take the neighbouring one
            int i = 0;
            while (i < n && (int)lv[i] != raw) i++;
            if (i < n && d > 0 && i + 1 < n) acpi_set("debug.nvdsm_bl_level", (int)lv[i + 1]);
            if (i < n && d < 0 && i > 0) acpi_set("debug.nvdsm_bl_level", (int)lv[i - 1]);
        }
    } else { fprintf(stderr, "usage: nvbl [get | set N | +N | -N]\n"); return 1; }
    acpi_get("debug.nvdsm_bl_pct", &pct);
    printf("%d\n", pct);
    return 0;
}

struct bl { NvKmsDeviceHandle dev; NvKmsDispHandle disp; NVDpyId dpy; NvS64 min, max; NvBool writable; };

static int getval(const struct bl *b, NvS64 *v) {
    struct NvKmsGetDpyAttributeParams g; memset(&g, 0, sizeof g);
    g.request.deviceHandle = b->dev; g.request.dispHandle = b->disp; g.request.dpyId = b->dpy;
    g.request.attribute = NV_KMS_DPY_ATTRIBUTE_BACKLIGHT_BRIGHTNESS;
    int r = kms(NVKMS_IOCTL_GET_DPY_ATTRIBUTE, &g, sizeof g);
    if (!r) *v = g.reply.value;
    return r;
}
static int setval(const struct bl *b, NvS64 v) {
    struct NvKmsSetDpyAttributeParams s; memset(&s, 0, sizeof s);
    s.request.deviceHandle = b->dev; s.request.dispHandle = b->disp; s.request.dpyId = b->dpy;
    s.request.attribute = NV_KMS_DPY_ATTRIBUTE_BACKLIGHT_BRIGHTNESS; s.request.value = v;
    return kms(NVKMS_IOCTL_SET_DPY_ATTRIBUTE, &s, sizeof s);
}

int main(int argc, char **argv) {
    int list = argc < 2;
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("NVRM"));
    if (!svc) { fprintf(stderr, "no NVRM service\n"); return 1; }
    kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 1, &gConn);
    IOObjectRelease(svc);
    if (kr) { fprintf(stderr, "IOServiceOpen -> 0x%x\n", kr); return 1; }

    struct NvKmsAllocDeviceParams ad; memset(&ad, 0, sizeof ad);
    strncpy(ad.request.versionString, "610.57.04", sizeof ad.request.versionString - 1);
    int r = kms(NVKMS_IOCTL_ALLOC_DEVICE, &ad, sizeof ad);
    if (r || ad.reply.status != NVKMS_ALLOC_DEVICE_STATUS_SUCCESS) { fprintf(stderr, "ALLOC_DEVICE rc 0x%x status %d\n", r, ad.reply.status); return 1; }

    struct bl found = {0}; int have = 0, rc = 1;
    for (NvU32 d = 0; d < ad.reply.numDisps && !have; d++) {
        struct NvKmsQueryDispParams q; memset(&q, 0, sizeof q);
        q.request.deviceHandle = ad.reply.deviceHandle; q.request.dispHandle = ad.reply.dispHandles[d];
        if ((r = kms(NVKMS_IOCTL_QUERY_DISP, &q, sizeof q))) { fprintf(stderr, "QUERY_DISP rc 0x%x\n", r); continue; }
        if (list) printf("disp %u: validDpys 0x%08x bootDpys 0x%08x connectors %u\n", d,
                         nvDpyIdListToNvU32(q.reply.validDpys), nvDpyIdListToNvU32(q.reply.bootDpys), q.reply.numConnectors);
        for (int bit = 0; bit < 32; bit++) {
            NvU32 m = 1u << bit;
            if (!(nvDpyIdListToNvU32(q.reply.validDpys) & m)) continue;
            struct NvKmsGetDpyAttributeValidValuesParams vv; memset(&vv, 0, sizeof vv);
            vv.request.deviceHandle = ad.reply.deviceHandle; vv.request.dispHandle = ad.reply.dispHandles[d];
            vv.request.dpyId = nvNvU32ToDpyId(m); vv.request.attribute = NV_KMS_DPY_ATTRIBUTE_BACKLIGHT_BRIGHTNESS;
            r = kms(NVKMS_IOCTL_GET_DPY_ATTRIBUTE_VALID_VALUES, &vv, sizeof vv);
            if (r) {
                // NVKMS marks a dpy as having a backlight only during QUERY_DPY_DYNAMIC_DATA. If RM answers a
                // direct GET now (e.g. NVDSM gave it the _DSM backlight data), re-run that query once and retry.
                struct bl probe = { ad.reply.deviceHandle, ad.reply.dispHandles[d], nvNvU32ToDpyId(m), 0, 0, 0 };
                NvS64 tmp;
                if (getval(&probe, &tmp) == 0) {
                    static struct NvKmsQueryDpyDynamicDataParams dyn; memset(&dyn, 0, sizeof dyn);
                    dyn.request.deviceHandle = probe.dev; dyn.request.dispHandle = probe.disp; dyn.request.dpyId = probe.dpy;
                    int dr = kms(NVKMS_IOCTL_QUERY_DPY_DYNAMIC_DATA, &dyn, sizeof dyn);
                    if (list) printf("  dpy 0x%08x: RM answers GET (%lld); re-queried dynamic data (rc 0x%x)\n", m, (long long)tmp, dr);
                    r = kms(NVKMS_IOCTL_GET_DPY_ATTRIBUTE_VALID_VALUES, &vv, sizeof vv);
                }
            }
            if (r) { if (list) printf("  dpy 0x%08x: no backlight (rc 0x%x)\n", m, r); continue; }
            struct bl b = { ad.reply.deviceHandle, ad.reply.dispHandles[d], nvNvU32ToDpyId(m),
                            vv.reply.common.u.range.min, vv.reply.common.u.range.max, vv.reply.common.writable };
            NvS64 cur = -1; int gr = getval(&b, &cur);
            if (list) printf("  dpy 0x%08x: BACKLIGHT readable %u writable %u type %d range [%lld,%lld] current %lld (get rc 0x%x)\n",
                             m, vv.reply.common.readable, vv.reply.common.writable, vv.reply.common.type,
                             (long long)b.min, (long long)b.max, (long long)cur, gr);
            if (!have && vv.reply.common.writable) { found = b; have = 1; }
        }
    }
    if (!have) { rc = acpi_main(argc, argv, list); goto out; }
    if (list) { rc = 0; goto out; }

    NvS64 cur = 0, v;
    if ((r = getval(&found, &cur))) { fprintf(stderr, "GET rc 0x%x\n", r); goto out; }
    if (!strcmp(argv[1], "get")) { printf("%lld\n", (long long)cur); rc = 0; goto out; }
    if (!strcmp(argv[1], "set") && argc > 2) v = strtoll(argv[2], NULL, 10);
    else if (argv[1][0] == '+' || argv[1][0] == '-') v = cur + strtoll(argv[1], NULL, 10);
    else { fprintf(stderr, "usage: nvbl [get | set N | +N | -N]\n"); goto out; }
    if (v < found.min) v = found.min;
    if (v > found.max) v = found.max;
    if ((r = setval(&found, v))) { fprintf(stderr, "SET %lld rc 0x%x\n", (long long)v, r); goto out; }
    getval(&found, &cur);
    printf("%lld\n", (long long)cur); rc = 0;
out:;
    struct NvKmsFreeDeviceParams fd; memset(&fd, 0, sizeof fd); fd.request.deviceHandle = ad.reply.deviceHandle;
    kms(NVKMS_IOCTL_FREE_DEVICE, &fd, sizeof fd);
    IOServiceClose(gConn);
    return rc;
}
