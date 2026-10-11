// Asks NVKMS (through NVRM's user client, selector 4 = nvkms ioctl) whether this device supports headSurface.
#include <stdio.h>
#include <string.h>
#include <IOKit/IOKitLib.h>
#include "nvkms-api.h"
static int kms(io_connect_t c, uint32_t cmd, void *p, size_t sz) {
    uint64_t in = cmd; size_t out = sz;
    kern_return_t kr = IOConnectCallMethod(c, 4, &in, 1, p, sz, NULL, NULL, p, &out);
    return kr == KERN_SUCCESS ? 0 : (int)kr;
}
int main(void) {
    io_service_t s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("NVRM"));
    if (!s) { printf("no NVRM service\n"); return 1; }
    io_connect_t c = 0; kern_return_t kr = IOServiceOpen(s, mach_task_self(), 1, &c);
    if (kr) { printf("IOServiceOpen -> 0x%x\n", kr); return 1; }
    struct NvKmsAllocDeviceParams ad; memset(&ad, 0, sizeof ad);
    strncpy(ad.request.versionString, "610.57.04", sizeof ad.request.versionString - 1);
    ad.request.deviceId.rmDeviceId = 0;
    int r = kms(c, NVKMS_IOCTL_ALLOC_DEVICE, &ad, sizeof ad);
    printf("ALLOC_DEVICE rc %d status %d supportsHeadSurface %u supportsSwapGroups %u supportsWarpAndBlend %u\n",
           r, ad.reply.status, ad.reply.supportsHeadSurface, ad.reply.supportsSwapGroups, ad.reply.supportsWarpAndBlend);
    if (!r && ad.reply.status == NVKMS_ALLOC_DEVICE_STATUS_SUCCESS) {
        struct NvKmsFreeDeviceParams fd; memset(&fd, 0, sizeof fd); fd.request.deviceHandle = ad.reply.deviceHandle;
        printf("FREE_DEVICE rc %d\n", kms(c, NVKMS_IOCTL_FREE_DEVICE, &fd, sizeof fd));
    }
    IOServiceClose(c);
    return 0;
}
