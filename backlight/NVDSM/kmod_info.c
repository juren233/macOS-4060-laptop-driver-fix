#include <mach/mach_types.h>
extern kern_return_t _start(kmod_info_t *, void *);
extern kern_return_t _stop(kmod_info_t *, void *);
extern kern_return_t NVDSM_kern_start(kmod_info_t *, void *);
extern kern_return_t NVDSM_kern_stop(kmod_info_t *, void *);
__attribute__((visibility("default"))) KMOD_EXPLICIT_DECL(local.juren.NVDSM, "1.0.0", _start, _stop)
__private_extern__ kmod_start_func_t *_realmain = NVDSM_kern_start;
__private_extern__ kmod_stop_func_t *_antimain = NVDSM_kern_stop;
__private_extern__ int _kext_apple_cc = __APPLE_CC__;
