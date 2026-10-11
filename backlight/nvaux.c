// DisplayPort AUX access to the panel through RM (NVRM user client selector 1 = RM escape).
//   nvaux                      list displays (supported / connected / type) and the eDP backlight DPCD block
//   nvaux r <dpy> <addr> [n]   read n (<=16) DPCD bytes
//   nvaux w <dpy> <addr> b..   write DPCD bytes
//   nvaux bl                   eDP AUX backlight: caps + current brightness
//   nvaux bl <1-100>           set brightness through DPCD 0x722/0x723 (panel must be in DPCD or PWMxDPCD mode)
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <IOKit/IOKitLib.h>
#include "nvtypes.h"
#include "nvos.h"
#include "nv_escape.h"
#include "class/cl0000.h"
#include "class/cl0080.h"
#include "class/cl2080.h"
#include "class/cl0073.h"
#include "ctrl/ctrl0000/ctrl0000gpu.h"
#include "ctrl/ctrl0073/ctrl0073system.h"
#include "ctrl/ctrl0073/ctrl0073specific.h"
#include "ctrl/ctrl0073/ctrl0073dp.h"

static io_connect_t gConn;
static NvHandle hClient, hDevice = 0xd0000001, hSub = 0xd0000002, hDisp = 0xd0000003;

static int esc(NvU32 cmd, void *p, NvU32 sz) {
    uint64_t in = cmd; size_t out = sz;
    kern_return_t kr = IOConnectCallMethod(gConn, 1, &in, 1, p, sz, NULL, NULL, p, &out);
    return kr == KERN_SUCCESS ? 0 : (int)kr;
}
static NvU32 rmAlloc(NvHandle parent, NvHandle *obj, NvU32 cls, void *params, NvU32 psz) {
    NVOS21_PARAMETERS p; memset(&p, 0, sizeof p);
    p.hRoot = parent ? hClient : 0; p.hObjectParent = parent; p.hObjectNew = obj ? *obj : 0;
    p.hClass = cls; p.pAllocParms = (NvP64)(uintptr_t)params; p.paramsSize = psz;
    int r = esc(NV_ESC_RM_ALLOC, &p, sizeof p);
    if (r) return 0xffff0000u | (NvU32)r;
    if (obj && !*obj) *obj = p.hObjectNew;
    return p.status;
}
static NvU32 rmCtrl(NvHandle obj, NvU32 cmd, void *params, NvU32 psz) {
    NVOS54_PARAMETERS p; memset(&p, 0, sizeof p);
    p.hClient = hClient; p.hObject = obj; p.cmd = cmd; p.params = (NvP64)(uintptr_t)params; p.paramsSize = psz;
    int r = esc(NV_ESC_RM_CONTROL, &p, sizeof p);
    return r ? (0xffff0000u | (NvU32)r) : p.status;
}

static NvU32 aux(NvU32 dpy, int write, NvU32 addr, NvU8 *data, NvU32 n, NvU32 *got, NvU32 *reply) {
    NvU32 st = 0;
    for (int tries = 0; tries < 8; tries++) {
        NV0073_CTRL_DP_AUXCH_CTRL_PARAMS a; memset(&a, 0, sizeof a);
        a.displayId = dpy; a.cmd = (1u << 3) | (write ? 0 : 1); a.addr = addr; a.size = n - 1;
        if (write) memcpy(a.data, data, n);
        st = rmCtrl(hDisp, NV0073_CTRL_CMD_DP_AUXCH_CTRL, &a, sizeof a);
        *reply = a.replyType; *got = a.size;
        if (st == 0 && a.replyType == 0) { if (!write) memcpy(data, a.data, n); return 0; }
        if (a.replyType != 2) break;   // only DEFER is worth retrying
    }
    return st ? st : 0xeeee0000u | *reply;
}
static int dpcdRead(NvU32 dpy, NvU32 addr, NvU8 *b, NvU32 n) {
    NvU32 got, rep, st = aux(dpy, 0, addr, b, n, &got, &rep);
    if (st) { fprintf(stderr, "AUX read dpy 0x%x 0x%05x: status 0x%x reply %u\n", dpy, addr, st, rep); return -1; }
    return (int)got;
}
static int dpcdWrite(NvU32 dpy, NvU32 addr, NvU8 *b, NvU32 n) {
    NvU32 got, rep, st = aux(dpy, 1, addr, b, n, &got, &rep);
    if (st) { fprintf(stderr, "AUX write dpy 0x%x 0x%05x: status 0x%x reply %u\n", dpy, addr, st, rep); return -1; }
    return 0;
}
static void dump(NvU32 dpy, NvU32 addr, NvU32 n) {
    NvU8 b[16] = {0};
    int got = dpcdRead(dpy, addr, b, n);
    if (got < 0) return;
    printf("  0x%05x:", addr);
    for (int i = 0; i < got; i++) printf(" %02x", b[i]);
    printf("\n");
}

static NvU32 findEdp(NvU32 connected) {
    for (int bit = 0; bit < 32; bit++) {
        NvU32 m = 1u << bit;
        if (!(connected & m)) continue;
        NvU8 r;
        if (dpcdRead(m, 0x700, &r, 1) == 1 && r) return m;   // eDP revision register is only non-zero on eDP sinks
    }
    return 0;
}

// DPCD 0x701 EDP_GENERAL_CAP_1: bit0 TCON backlight adjust, bit1 BL pin enable, bit2 BL AUX enable.
// 0x702 EDP_BACKLIGHT_ADJUSTMENT_CAP: bit0 PWM pin, bit1 AUX set, bit2 16-bit, bit3 AUX*PWM product.
// 0x721 BL_MODE_SET bits 1:0: 0 PWM pin, 1 preset, 2 DPCD, 3 product of PWM pin and DPCD.
static int backlight(NvU32 dpy, int argc, char **argv) {
    NvU8 cap[2] = {0}, mode = 0, br[2] = {0};
    if (dpcdRead(dpy, 0x701, cap, 2) < 0 || dpcdRead(dpy, 0x721, &mode, 1) < 0) return 1;
    int wide = cap[1] & 0x04;
    static const char *modes[] = { "PWM pin", "preset", "DPCD", "PWM pin x DPCD" };
    printf("eDP 0x%x: GEN_CAP_1 0x%02x  BL_ADJUST_CAP 0x%02x (pwm %d aux %d 16bit %d product %d)  BL_MODE_SET 0x%02x (%s)\n",
           dpy, cap[0], cap[1], cap[1] & 1, !!(cap[1] & 2), !!wide, !!(cap[1] & 8), mode, modes[mode & 3]);
    if (dpcdRead(dpy, 0x722, br, 2) < 0) return 1;
    unsigned max = wide ? 0xffff : 0xff, cur = wide ? (unsigned)br[0] << 8 | br[1] : br[0];
    printf("  BRIGHTNESS 0x722/0x723 = %02x %02x -> %u%%\n", br[0], br[1], (cur * 100 + max / 2) / max);
    if (argc < 3) return 0;
    if ((mode & 3) < 2) { fprintf(stderr, "panel is not in a DPCD brightness mode\n"); return 2; }
    int pct = atoi(argv[2]); if (pct < 1) pct = 1; if (pct > 100) pct = 100;   // never 0: some TCONs blank completely
    unsigned v = max * (unsigned)pct / 100;
    NvU8 w[2] = { (NvU8)(wide ? v >> 8 : v), (NvU8)(v & 0xff) };
    if (dpcdWrite(dpy, 0x722, w, wide ? 2 : 1)) return 1;
    dpcdRead(dpy, 0x722, br, 2);
    printf("  set %d%% -> 0x722/0x723 = %02x %02x\n", pct, br[0], br[1]);
    return 0;
}

int main(int argc, char **argv) {
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("NVRM"));
    if (!svc) { fprintf(stderr, "no NVRM service\n"); return 1; }
    kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &gConn);
    IOObjectRelease(svc);
    if (kr) { fprintf(stderr, "IOServiceOpen -> 0x%x\n", kr); return 1; }

    NvU32 st;
    if ((st = rmAlloc(0, &hClient, NV01_ROOT_CLIENT, NULL, 0))) { fprintf(stderr, "alloc client -> 0x%x\n", st); return 1; }
    NV0000_CTRL_GPU_GET_ATTACHED_IDS_PARAMS ids; memset(&ids, 0, sizeof ids);
    if ((st = rmCtrl(hClient, NV0000_CTRL_CMD_GPU_GET_ATTACHED_IDS, &ids, sizeof ids))) { fprintf(stderr, "attached ids -> 0x%x\n", st); return 1; }
    NV0000_CTRL_GPU_GET_ID_INFO_V2_PARAMS info; memset(&info, 0, sizeof info); info.gpuId = ids.gpuIds[0];
    if ((st = rmCtrl(hClient, NV0000_CTRL_CMD_GPU_GET_ID_INFO_V2, &info, sizeof info))) { fprintf(stderr, "id info -> 0x%x\n", st); return 1; }
    NV0080_ALLOC_PARAMETERS a80; memset(&a80, 0, sizeof a80); a80.deviceId = info.deviceInstance; a80.hClientShare = hClient;
    NV2080_ALLOC_PARAMETERS a20; memset(&a20, 0, sizeof a20); a20.subDeviceId = info.subDeviceInstance;
    if ((st = rmAlloc(hClient, &hDevice, NV01_DEVICE_0, &a80, sizeof a80))) { fprintf(stderr, "alloc device -> 0x%x\n", st); return 1; }
    if ((st = rmAlloc(hDevice, &hSub, NV20_SUBDEVICE_0, &a20, sizeof a20))) { fprintf(stderr, "alloc subdevice -> 0x%x\n", st); return 1; }
    if ((st = rmAlloc(hDevice, &hDisp, NV04_DISPLAY_COMMON, NULL, 0))) { fprintf(stderr, "alloc display common -> 0x%x\n", st); return 1; }

    NV0073_CTRL_SYSTEM_GET_SUPPORTED_PARAMS sup; memset(&sup, 0, sizeof sup);
    NV0073_CTRL_SYSTEM_GET_CONNECT_STATE_PARAMS con; memset(&con, 0, sizeof con);
    rmCtrl(hDisp, NV0073_CTRL_CMD_SYSTEM_GET_SUPPORTED, &sup, sizeof sup);
    con.displayMask = sup.displayMask;
    rmCtrl(hDisp, NV0073_CTRL_CMD_SYSTEM_GET_CONNECT_STATE, &con, sizeof con);

    int rc = 0;
    if (argc < 2) {
        printf("supported 0x%08x connected 0x%08x\n", sup.displayMask, con.displayMask);
        for (int bit = 0; bit < 32; bit++) {
            NvU32 m = 1u << bit;
            if (!(con.displayMask & m)) continue;
            NV0073_CTRL_SPECIFIC_GET_TYPE_PARAMS t; memset(&t, 0, sizeof t); t.displayId = m;
            rmCtrl(hDisp, NV0073_CTRL_CMD_SPECIFIC_GET_TYPE, &t, sizeof t);
            printf("dpy 0x%08x: type %u subtype... (DPCD rev, eDP block)\n", m, t.displayType);
            dump(m, 0x000, 16);
            dump(m, 0x700, 16);
            dump(m, 0x720, 8);
        }
    } else if (!strcmp(argv[1], "r") && argc >= 4) {
        NvU32 n = argc > 4 ? (NvU32)strtoul(argv[4], NULL, 0) : 1; if (n < 1) n = 1; if (n > 16) n = 16;
        dump((NvU32)strtoul(argv[2], NULL, 0), (NvU32)strtoul(argv[3], NULL, 0), n);
    } else if (!strcmp(argv[1], "w") && argc >= 5) {
        NvU8 b[16]; NvU32 n = 0;
        for (int i = 4; i < argc && n < 16; i++) b[n++] = (NvU8)strtoul(argv[i], NULL, 0);
        rc = dpcdWrite((NvU32)strtoul(argv[2], NULL, 0), (NvU32)strtoul(argv[3], NULL, 0), b, n) ? 1 : 0;
    } else if (!strcmp(argv[1], "bl")) {
        NvU32 e = findEdp(con.displayMask);
        if (!e) { fprintf(stderr, "no eDP sink found among connected 0x%08x\n", con.displayMask); rc = 1; }
        else rc = backlight(e, argc, argv);
    } else if (!strcmp(argv[1], "rmbl")) {
        // RM's own backlight controls (GSP brightc): get for every brightness type, optional set (type 1, percent)
        for (int bit = 0; bit < 32; bit++) {
            NvU32 m = 1u << bit;
            if (!(con.displayMask & m)) continue;
            for (NvU8 type = 0; type <= 3; type++) {
                NV0073_CTRL_SPECIFIC_BACKLIGHT_BRIGHTNESS_PARAMS b; memset(&b, 0, sizeof b);
                b.displayId = m; b.brightnessType = type;
                st = rmCtrl(hDisp, NV0073_CTRL_CMD_SPECIFIC_GET_BACKLIGHT_BRIGHTNESS, &b, sizeof b);
                printf("dpy 0x%x GET type %u -> status 0x%x brightness %u\n", m, type, st, b.brightness);
            }
            if (argc > 2) {
                NV0073_CTRL_SPECIFIC_BACKLIGHT_BRIGHTNESS_PARAMS b; memset(&b, 0, sizeof b);
                b.displayId = m; b.brightness = (NvU32)atoi(argv[2]); b.brightnessType = NV0073_CTRL_SPECIFIC_BACKLIGHT_BRIGHTNESS_TYPE_PERCENT100;
                st = rmCtrl(hDisp, NV0073_CTRL_CMD_SPECIFIC_SET_BACKLIGHT_BRIGHTNESS, &b, sizeof b);
                printf("dpy 0x%x SET %u -> status 0x%x\n", m, b.brightness, st);
            }
        }
    } else { fprintf(stderr, "usage: nvaux [r dpy addr [n] | w dpy addr bytes.. | bl [pct] | rmbl [pct]]\n"); rc = 1; }

    NVOS00_PARAMETERS f; memset(&f, 0, sizeof f); f.hRoot = hClient; f.hObjectParent = hClient; f.hObjectOld = hClient;
    esc(NV_ESC_RM_FREE, &f, sizeof f);
    IOServiceClose(gConn);
    return rc;
}
