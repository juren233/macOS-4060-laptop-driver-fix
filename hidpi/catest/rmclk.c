// rmclk: read-only RM client - current P-state and the PMU's GPC / DRAM clock samples (20 ms apart), for "is the GPU boosting?".
//   rmclk [SECONDS]   prints every new clock sample for SECONDS (default 5); run a GPU load (gpuclock) alongside.
// Talks to NVAccel's user client like NVK's nvrm_xnu shim (ctl node, SEL_ESC); only GET controls are issued.
// Build (OGKM = NVIDIA open-gpu-kernel-modules 610.57.04, the RM NullMoth runs): clang -O2 -I$OGKM/src/common/sdk/nvidia/inc
//   -I$OGKM/src/nvidia/arch/nvalloc/unix/include -I$OGKM/src/common/inc -framework IOKit rmclk.c -o rmclk && codesign -s - rmclk
#include <IOKit/IOKitLib.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include "nvtypes.h"
#include "nvos.h"
#include "nv-ioctl.h"
#include "nv_escape.h"
#include "nv-gpu-info.h"
#include "class/cl0000.h"
#include "class/cl0080.h"
#include "class/cl2080.h"
#include "ctrl/ctrl0000/ctrl0000gpu.h"
#include "ctrl/ctrl2080/ctrl2080perf.h"
#include "ctrl/ctrl2080/ctrl2080clk.h"
enum { SEL_ESC = 1, SEL_BINDFD = 3 };
static io_connect_t conn;
static int esc(uint32_t cmd, void *p, uint32_t size) {
    uint64_t in = cmd; size_t out = size;
    kern_return_t kr = IOConnectCallMethod(conn, SEL_ESC, &in, 1, p, size, NULL, NULL, p, &out);
    if (kr) fprintf(stderr, "esc 0x%x -> 0x%x\n", cmd, kr);
    return kr ? -1 : 0;
}
static NvHandle hClient;
static NvU32 alloc(NvHandle parent, NvHandle *h, NvU32 cls, void *params) {
    NVOS21_PARAMETERS p = { .hRoot = hClient, .hObjectParent = parent, .hObjectNew = *h, .hClass = cls, .pAllocParms = params };
    if (esc(NV_ESC_RM_ALLOC, &p, sizeof p)) return NV_ERR_GENERIC;
    *h = p.hObjectNew; return p.status;
}
static NvU32 ctrl(NvHandle h, NvU32 cmd, void *params, NvU32 size) {
    NVOS54_PARAMETERS p = { .hClient = hClient, .hObject = h, .cmd = cmd, .params = params, .paramsSize = size };
    if (esc(NV_ESC_RM_CONTROL, &p, sizeof p)) return NV_ERR_GENERIC;
    return p.status;
}
int main(int argc, char **argv) {
    const double S = argc > 1 ? atof(argv[1]) : 5;
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("NVAccel"));
    if (!svc || IOServiceOpen(svc, mach_task_self(), 0x4E560000u, &conn)) { printf("cannot open NVAccel ctl\n"); return 1; }
    int fd = open("/dev/null", O_RDWR); uint64_t fin = (uint64_t)fd; IOConnectCallScalarMethod(conn, SEL_BINDFD, &fin, 1, NULL, NULL);
    static nv_ioctl_card_info_t ci[NV_MAX_GPUS];
    if (esc(NV_ESC_CARD_INFO, ci, sizeof ci)) return 1;
    int g = -1; for (int i = 0; i < NV_MAX_GPUS; i++) if (ci[i].valid) { g = i; break; }
    if (g < 0) { printf("no GPU\n"); return 1; }
    NvU32 st = alloc(0, &hClient, NV01_ROOT_CLIENT, NULL); if (st) { printf("root client 0x%x\n", st); return 1; }
    NV0000_CTRL_GPU_GET_ID_INFO_V2_PARAMS id = { .gpuId = ci[g].gpu_id };
    if ((st = ctrl(hClient, NV0000_CTRL_CMD_GPU_GET_ID_INFO_V2, &id, sizeof id))) { printf("id info 0x%x\n", st); return 1; }
    NV0080_ALLOC_PARAMETERS a0 = { .deviceId = id.deviceInstance, .hClientShare = hClient }; NV2080_ALLOC_PARAMETERS a2 = { .subDeviceId = id.subDeviceInstance };
    NvHandle hDev = 0, hSub = 0;
    if ((st = alloc(hClient, &hDev, NV01_DEVICE_0, &a0)) || (st = alloc(hDev, &hSub, NV20_SUBDEVICE_0, &a2))) { printf("device/subdevice 0x%x\n", st); return 1; }
    NV2080_CTRL_PERF_GET_CURRENT_PSTATE_PARAMS ps = { 0 };
    st = ctrl(hSub, NV2080_CTRL_CMD_PERF_GET_CURRENT_PSTATE, &ps, sizeof ps);
    int pn = -1; for (int b = 0; b < 16; b++) if (ps.currPstate == (1u << b)) pn = b;
    printf("rmclk: GPU 0x%x  current P-state: status 0x%x  P%d (mask 0x%x)\n", ci[g].pci_info.device_id, st, pn, ps.currPstate);
    static NV2080_CTRL_CLK_PMUMON_CLK_DOMAINS_GET_SAMPLES_PARAMS cs;
    cs.super.retrievalMode = NV2080_CTRL_PMUMON_RETRIEVAL_MODE_ALL_SAMPLES;
    unsigned shown = 0; const int ticks = (int)(S * 10);
    for (int t = 0; t <= ticks; t++) {
        st = ctrl(hSub, NV2080_CTRL_CMD_CLK_PMUMON_CLK_DOMAINS_GET_SAMPLES, &cs, sizeof cs);
        if (st) { printf("rmclk: PMUMON clock samples: status 0x%x (not available)\n", st); break; }
        for (NvU32 i = 0; i < cs.super.numSamples; i++, shown++)
            if (shown % 5 == 0) printf("  gpc %4u MHz  active-gpc %4u MHz  dram %5u MHz  nvd %4u MHz\n", cs.samples[i].gpcClkFreqKHz / 1000,
                   cs.samples[i].activeGpcClkFreqKHz / 1000, cs.samples[i].dramClkFreqKHz / 1000, cs.samples[i].nvdClkFreqKHz / 1000);
        usleep(100000);
    }
    st = ctrl(hSub, NV2080_CTRL_CMD_PERF_GET_CURRENT_PSTATE, &ps, sizeof ps);
    pn = -1; for (int b = 0; b < 16; b++) if (ps.currPstate == (1u << b)) pn = b;
    printf("rmclk: P-state at the end: P%d (status 0x%x), %u clock samples\n", pn, st, shown);
    NVOS00_PARAMETERS fr = { .hRoot = hClient, .hObjectParent = hClient, .hObjectOld = hClient }; esc(NV_ESC_RM_FREE, &fr, sizeof fr);
    return 0;
}
