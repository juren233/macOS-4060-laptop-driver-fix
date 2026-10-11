//
//  NVDSM: Lilu plugin that gives NullMoth's NVRM a working nv_acpi_dsm_method().
//
//  NullMoth's XNU port stubs nv_acpi_dsm_method() to NV_ERR_NOT_SUPPORTED, so RM never gets the
//  laptop's backlight method data (NBCI/NVHG _DSM GETBACKLIGHT) and GSP refuses
//  NV0073_CTRL_CMD_SPECIFIC_{GET,SET}_BACKLIGHT_BRIGHTNESS. This routes the stub to an implementation
//  that evaluates \_SB...PEGP._DSM like the Linux driver (kernel-open/nvidia/nv-acpi.c), but only
//  for an allowlist: NBCI/NVHG subfunction 0 (capabilities, masked to {0, GETBACKLIGHT}) and
//  GETBACKLIGHT (0x14). Every other GUID/subfunction still goes to the original stub, so RM sees no
//  other _DSM features (Optimus/JT, GPS, MUX, NVPCF) and behaves as before.
//
//  Boot args:  nvdsm=0  disable routing (stock behaviour)
//  Every capability query (subfunction 0) RM makes is also evaluated and logged (side-effect free per
//  the _DSM spec), but non-allowlisted GUIDs still get NV_ERR_NOT_SUPPORTED.
//  Log: `sysctl debug.nvdsm_log`, or kernel log lines starting with "NVDSM:".
//  The original stub is never called: its first instructions are RIP-relative (cmpb _t(%rip); jne rel8),
//  which a Lilu trampoline copies unrelocated. It only ever returns NV_ERR_NOT_SUPPORTED, so that is
//  returned directly instead.
//

#include <Headers/plugin_start.hpp>
#include <Headers/kern_api.hpp>
#include <Headers/kern_patcher.hpp>
#include <IOKit/IOLib.h>
#include <IOKit/acpi/IOACPIPlatformDevice.h>
#include <IOKit/acpi/IOACPIPlatformExpert.h>
#include <libkern/c++/OSData.h>
#include <libkern/c++/OSNumber.h>
#include <libkern/c++/OSArray.h>
#include <sys/sysctl.h>
#include <stdarg.h>
#include <sys/errno.h>
#include <kern/thread_call.h>
#include <IOKit/acpi/IOACPITypes.h>
#ifndef NVDSM_IODISPLAY
#define NVDSM_IODISPLAY 0   // 1 needs IOGraphicsFamily, which lives in the System KC: an OpenCore-injected kext cannot link it
#endif
#if NVDSM_IODISPLAY
// IODisplay::addParameterHandler() is exported by IOGraphicsFamily but declared private in the header.
#define private public
#include <IOKit/graphics/IODisplay.h>
#undef private
#endif

extern "C" void kprintf(const char *fmt, ...);

// Log: every line goes to kprintf (shows in the unified log like NVRM's "NVRM-xnu:" lines; IOLog from this
// kext does not) and into a buffer readable with `sysctl debug.nvdsm_log`.
static char gLog[16384];
static size_t gLogLen;
static IOLock *gLogLock;
static void dlog(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void dlog(const char *fmt, ...) {
	char line[256];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(line, sizeof(line), fmt, ap);
	va_end(ap);
	kprintf("NVDSM: %s", line);
	if (gLogLock) IOLockLock(gLogLock);
	size_t n = strnlen(line, sizeof(line));
	if (gLogLen + n + 2 < sizeof(gLog)) {
		memcpy(gLog + gLogLen, line, n);
		gLogLen += n;
		gLog[gLogLen++] = '\n';
		gLog[gLogLen] = 0;
	}
	if (gLogLock) IOLockUnlock(gLogLock);
}
static int sysctlLog(struct sysctl_oid *, void *, int, struct sysctl_req *req) {
	return SYSCTL_OUT(req, gLog, gLogLen + 1);
}
SYSCTL_PROC(_debug, OID_AUTO, nvdsm_log, CTLTYPE_STRING | CTLFLAG_RD | CTLFLAG_LOCKED, nullptr, 0, sysctlLog, "A", "NVDSM log");

typedef uint32_t NV_STATUS;
static constexpr NV_STATUS NV_OK                   = 0x00;
static constexpr NV_STATUS NV_ERR_BUFFER_TOO_SMALL = 0x02;
static constexpr NV_STATUS NV_ERR_NOT_SUPPORTED    = 0x56;
static constexpr NV_STATUS NV_ERR_OPERATING_SYSTEM = 0x59;

static constexpr uint32_t kMaxDsmParamSize   = 1024;   // NV_MAX_ACPI_DSM_PARAM_SIZE
static constexpr uint32_t kFuncAllSupport    = 0x00;   // NV_ACPI_ALL_FUNC_SUPPORT
static constexpr uint32_t kFuncGetBacklight  = 0x14;   // NV_NBCI_FUNC_GETBACKLIGHT == NVHG_FUNC_GETBACKLIGHT

// GUID bytes exactly as RM passes them (read from NVRM's _NBCI_DSM_GUID / _NVHG_DSM_GUID).
static const uint8_t kNBCI[16] = {0x75,0x0b,0xa5,0xd4,0xc7,0x65,0xf7,0x46,0xbf,0xb7,0x41,0x51,0x4c,0xea,0x02,0x44};
static const uint8_t kNVHG[16] = {0xa0,0xa0,0x95,0x9d,0x60,0x00,0x48,0x4d,0xb3,0x4d,0x7e,0x5f,0xea,0x12,0x9f,0xd4};

struct GuidName { uint8_t b0, b1, b2, b3; const char *name; };
static const GuidName kNames[] = {
	{0x75,0x0b,0xa5,0xd4,"NBCI"}, {0xa0,0xa0,0x95,0x9d,"NVHG"}, {0xf8,0xd8,0x86,0xa4,"NVOP"},
	{0x01,0x2d,0x13,0xa3,"GPS"},  {0x51,0xa3,0xec,0xcb,"JT"},   {0x00,0xa4,0x04,0x40,"MXM"},
	{0xa6,0x69,0x86,0x99,"NBSI"}, {0x7d,0x14,0xc6,0x81,"PCFG"}, {0xd0,0x37,0xc9,0xe5,"PEX"},
	{0xfd,0x88,0xdb,0x95,"SPB"},  {0x10,0x97,0xb4,0x36,"NVPCF"},
};
static const char *guidName(const uint8_t *g) {
	for (auto &n : kNames) if (g[0] == n.b0 && g[1] == n.b1 && g[2] == n.b2 && g[3] == n.b3) return n.name;
	return "?";
}

using dsm_t = NV_STATUS (*)(void *nv, uint8_t *guid, uint32_t rev, bool nvpcf, uint32_t sub,
                            void *in, uint16_t inSize, uint32_t *outStatus, void *out, uint16_t *pSize);
static uint32_t gMode = 1;
static bool (*gPreemptionEnabled)();
static IOACPIPlatformDevice *gAcpi;

static bool mayBlock() {
	if (!ml_get_interrupts_enabled()) return false;
	return gPreemptionEnabled ? gPreemptionEnabled() : true;
}

// The dGPU's ACPI node: the NVIDIA display-class IOPCIDevice's "acpi-device" (PEG1.PEGP here).
static void lcdSetup(IOACPIPlatformDevice *lcd);
static IOLock *gAcpiLock;

static IOACPIPlatformDevice *gpuAcpiLocked();
static void wmiScan();
static IOACPIPlatformDevice *gpuAcpi() {
	if (gAcpi) return gAcpi;
	if (gAcpiLock) IOLockLock(gAcpiLock);
	auto r = gpuAcpiLocked();
	if (gAcpiLock) IOLockUnlock(gAcpiLock);
	return r;
}
static IOACPIPlatformDevice *gpuAcpiLocked() {
	if (gAcpi) return gAcpi;
	OSDictionary *match = IOService::serviceMatching("IOPCIDevice");
	if (!match) return nullptr;
	OSIterator *it = IOService::getMatchingServices(match);
	match->release();
	if (!it) return nullptr;
	while (auto obj = it->getNextObject()) {
		auto dev = OSDynamicCast(IORegistryEntry, obj);
		if (!dev) continue;
		auto vid = OSDynamicCast(OSData, dev->getProperty("vendor-id"));
		auto cls = OSDynamicCast(OSData, dev->getProperty("class-code"));
		if (!vid || !cls || vid->getLength() < 2 || cls->getLength() < 4) continue;
		uint32_t v = 0, c = 0;
		memcpy(&v, vid->getBytesNoCopy(), 2);
		memcpy(&c, cls->getBytesNoCopy(), 4);
		if (v != 0x10de || (c >> 16) != 0x03) continue;
		auto acpi = OSDynamicCast(IOACPIPlatformDevice, dev->getProperty("acpi-device"));
		if (acpi) { acpi->retain(); gAcpi = acpi; break; }
	}
	it->release();
	if (gAcpi) {
		static const char *meth[] = {"_DSM", "_DOD", "_ROM"};
		for (auto m : meth) dlog("GPU ACPI %s: %s %s", gAcpi->getName(), m, gAcpi->validateObject(m) == kIOReturnSuccess ? "present" : "absent");
		if (auto kids = gAcpi->getChildIterator(gIOACPIPlane)) {
			while (auto k = OSDynamicCast(IOACPIPlatformDevice, kids->getNextObject())) {
				static const char *km[] = {"_BCL", "_BCM", "_BQC", "_DDC"};
				for (auto m : km) dlog("  child %s: %s %s", k->getName(), m, k->validateObject(m) == kIOReturnSuccess ? "present" : "absent");
				if (k->validateObject("_BCM") == kIOReturnSuccess && k->validateObject("_BCL") == kIOReturnSuccess)
					lcdSetup(k);
			}
			kids->release();
		}
	} else {
		dlog("no NVIDIA display IOPCIDevice with an acpi-device");
	}
	if (gAcpi) wmiScan();
	return gAcpi;
}

// ---- Panel backlight through the ACPI video methods of the dGPU's LCD child (_BCL/_BCM/_BQC) ----
// GSP answers NV0073 GET/SET_BACKLIGHT_BRIGHTNESS with NOT_SUPPORTED on this laptop even with the NBCI
// GETBACKLIGHT data, i.e. the panel's brightness is owned by the SBIOS, as Linux' acpi_video would drive it.
//   sysctl debug.nvdsm_bl_levels       "<ac> <battery> | level level ..." from _BCL
//   sysctl debug.nvdsm_bl_level  [=N]  read _BQC / write _BCM(N) (snapped to the nearest _BCL level)
//   sysctl debug.nvdsm_bl_pct    [=P]  same in percent of the _BCL range
// Both writable sysctls are CTLFLAG_ANYBODY, so the brightness can be set without root.
// Notify(LCD, 0x86 / 0x87) (brightness up/down hotkeys) steps one _BCL level, unless the firmware already
// moved the level itself.

static IOACPIPlatformDevice *gLcd;
static uint32_t gLevels[101];
static uint32_t gNumLevels, gBclAc, gBclBattery;
static uint32_t gLastSet = UINT32_MAX;
static thread_call_t gStepCall;
static IONotifier *gLcdNotifier;

static void displaySync();

static bool bclRead() {
	OSObject *res = nullptr;
	if (!gLcd || gLcd->evaluateObject("_BCL", &res) != kIOReturnSuccess || !res) return false;
	auto arr = OSDynamicCast(OSArray, res);
	uint32_t n = 0;
	if (arr && arr->getCount() >= 3) {
		auto ac = OSDynamicCast(OSNumber, arr->getObject(0)), bat = OSDynamicCast(OSNumber, arr->getObject(1));
		gBclAc = ac ? ac->unsigned32BitValue() : 0;
		gBclBattery = bat ? bat->unsigned32BitValue() : 0;
		for (unsigned i = 2; i < arr->getCount() && n < arrsize(gLevels); i++) {
			auto num = OSDynamicCast(OSNumber, arr->getObject(i));
			if (!num) continue;
			uint32_t v = num->unsigned32BitValue(), j = n;
			bool dup = false;
			for (uint32_t k = 0; k < n; k++) if (gLevels[k] == v) dup = true;
			if (dup) continue;
			while (j > 0 && gLevels[j - 1] > v) { gLevels[j] = gLevels[j - 1]; j--; }   // insertion sort, ascending
			gLevels[j] = v;
			n++;
		}
	}
	res->release();
	gNumLevels = n;
	return n > 0;
}

static bool bqcRead(uint32_t *v) {
	UInt32 x = 0;
	if (!gLcd || gLcd->evaluateInteger("_BQC", &x) != kIOReturnSuccess) return false;
	*v = x;
	return true;
}

static uint32_t snapLevel(uint32_t v) {
	uint32_t best = gLevels[0];
	for (uint32_t i = 0; i < gNumLevels; i++)
		if ((gLevels[i] > v ? gLevels[i] - v : v - gLevels[i]) < (best > v ? best - v : v - best)) best = gLevels[i];
	return best;
}

static IOReturn bcmWrite(uint32_t v) {
	if (!gLcd || !gNumLevels) return kIOReturnNotReady;
	v = snapLevel(v);
	OSNumber *n = OSNumber::withNumber(v, 32);
	if (!n) return kIOReturnNoMemory;
	OSObject *params[1] = { n };
	IOReturn r = gLcd->evaluateObject("_BCM", nullptr, params, 1);
	n->release();
	if (r == kIOReturnSuccess) { gLastSet = v; displaySync(); }
	uint32_t now = 0;
	bool q = bqcRead(&now);
	dlog("_BCM(%u) -> 0x%x, _BQC now %d", v, r, q ? (int)now : -1);
	return r;
}

static uint32_t currentLevel() {
	uint32_t v;
	if (bqcRead(&v)) return v;
	return gLastSet != UINT32_MAX ? gLastSet : (gNumLevels ? gLevels[gNumLevels - 1] : 0);
}

static void blRange(uint32_t *cur, uint32_t *lo, uint32_t *hi);
static IOReturn blWrite(uint32_t v);
static IOACPIPlatformDevice *gWmi;
static bool gKmsBlValid;   // NVKMS owns the backlight (v8): hotkeys go through macOS (BrightnessKeys), not _BCM
static IONotifier *gDd1fNotifier;

static void stepWork(thread_call_param_t p0, thread_call_param_t) {
	uint32_t code = (uint32_t)(uintptr_t)p0;
	if (gAcpiLock) IOLockLock(gAcpiLock);
	if (gWmi) {
		uint32_t cur, lo, hi;
		blRange(&cur, &lo, &hi);
		uint32_t step = (hi - lo) / 16 ? (hi - lo) / 16 : 1;
		if (code == 0x86) blWrite(cur + step > hi ? hi : cur + step);
		else if (code == 0x87) blWrite(cur > lo + step ? cur - step : lo);
		if (gAcpiLock) IOLockUnlock(gAcpiLock);
		return;
	}
	uint32_t cur = currentLevel();
	if (gLastSet != UINT32_MAX && cur != snapLevel(gLastSet)) {
		dlog("notify 0x%x: firmware already moved the level %u -> %u, not stepping", code, gLastSet, cur);
		gLastSet = cur;
	} else if (gNumLevels) {
		uint32_t idx = 0;
		for (uint32_t i = 0; i < gNumLevels; i++) if (gLevels[i] <= cur) idx = i;
		if (code == 0x86 && idx + 1 < gNumLevels) idx++;
		else if (code == 0x87 && idx > 0) idx--;
		bcmWrite(gLevels[idx]);
	}
	if (gAcpiLock) IOLockUnlock(gAcpiLock);
}

static IOReturn lcdNotify(void *target, void *, UInt32 type, IOService *, void *arg, vm_size_t) {
	if (type != kIOACPIMessageDeviceNotification) return kIOReturnSuccess;
	uint32_t code = arg ? *(uint32_t *)arg : 0;
	dlog("%s notify 0x%x", static_cast<IOService *>(target)->getName(), code);
	if ((code == 0x86 || code == 0x87) && gStepCall && !gKmsBlValid) thread_call_enter1(gStepCall, (thread_call_param_t)(uintptr_t)code);
	return kIOReturnSuccess;
}

static void lcdSetup(IOACPIPlatformDevice *lcd) {
	if (gLcd) return;
	lcd->retain();
	gLcd = lcd;
	if (!bclRead()) { dlog("LCD %s: _BCL unreadable", lcd->getName()); return; }
	char buf[200]; size_t o = 0;
	for (uint32_t i = 0; i < gNumLevels && o + 6 < sizeof(buf); i++) o += snprintf(buf + o, sizeof(buf) - o, "%u ", gLevels[i]);
	uint32_t cur = 0;
	bool q = bqcRead(&cur);
	dlog("LCD %s: _BCL ac %u battery %u, %u levels: %s; _BQC %d", lcd->getName(), gBclAc, gBclBattery, gNumLevels, buf, q ? (int)cur : -1);
	gStepCall = thread_call_allocate(stepWork, nullptr);
	gLcdNotifier = lcd->registerInterest(gIOGeneralInterest, lcdNotify, lcd, nullptr);
	dlog("LCD notify handler %s", gLcdNotifier ? "installed" : "NOT installed");
}

// ---- NVIDIA WMI EC backlight (what Linux' nvidia-wmi-ec-backlight drives) ----
// On MUX laptops running on the dGPU the SBIOS may hand the panel PWM to the EC and expose it through WMI GUID
// 603E9613-EF25-4338-A3D0-C46177516DB7: method 1 = level, 2 = source; args { mode (0 get, 1 set, 2 get max),
// val, ret, 3 x ignored }, the method returns the same 24-byte buffer with ret filled in. Every _WDG of every
// PNP0C14 device is logged, so the other WMI blocks (hotkey events) show up in debug.nvdsm_log too.
static const uint8_t kWmiBlGuid[16] = {0x13,0x96,0x3e,0x60,0x25,0xef,0x38,0x43,0xa3,0xd0,0xc4,0x61,0x77,0x51,0x6d,0xb7};
static char gWmiMethod[5];
static uint32_t gWmiMax, gWmiSource;
static bool gWmiScanned;
static IONotifier *gWmiNotifiers[8];
static uint32_t gNumWmiNotifiers;

struct WmiArgs { uint32_t mode, val, ret, ignored[3]; };

static bool wmiCall(uint32_t method, uint32_t mode, uint32_t val, uint32_t *ret) {
	if (!gWmi) return false;
	WmiArgs a {mode, val, 0, {0, 0, 0}};
	OSObject *params[3] = { OSNumber::withNumber(0ULL, 32), OSNumber::withNumber(method, 32), OSData::withBytes(&a, sizeof(a)) };
	OSObject *res = nullptr;
	IOReturn r = kIOReturnNoMemory;
	if (params[0] && params[1] && params[2]) r = gWmi->evaluateObject(gWmiMethod, &res, params, 3);
	for (auto o : params) if (o) o->release();
	bool ok = false;
	uint32_t v = 0;
	if (r == kIOReturnSuccess && res) {
		if (auto d = OSDynamicCast(OSData, res)) {
			if (d->getLength() >= 12) { memcpy(&v, (const uint8_t *)d->getBytesNoCopy() + 8, 4); ok = true; }
			else if (d->getLength() >= 4) { memcpy(&v, d->getBytesNoCopy(), 4); ok = true; }
		} else if (auto n = OSDynamicCast(OSNumber, res)) { v = n->unsigned32BitValue(); ok = true; }
	}
	if (res) res->release();
	if (ret) *ret = v;
	if (r != kIOReturnSuccess || !ok) dlog("WMI %s(method %u mode %u val %u) -> 0x%x%s", gWmiMethod, method, mode, val, r, ok ? "" : " (no usable result)");
	return r == kIOReturnSuccess && ok;
}

static IOReturn wmiNotify(void *target, void *, UInt32 type, IOService *, void *arg, vm_size_t) {
	if (type != kIOACPIMessageDeviceNotification) return kIOReturnSuccess;
	auto dev = (IOACPIPlatformDevice *)target;
	uint32_t code = arg ? *(uint32_t *)arg : 0;
	OSObject *res = nullptr;
	OSNumber *n = OSNumber::withNumber(code, 32);
	OSObject *params[1] = { n };
	IOReturn r = n ? dev->evaluateObject("_WED", &res, params, 1) : kIOReturnNoMemory;
	if (n) n->release();
	char hex[3 * 16 + 1] = "";
	if (auto d = OSDynamicCast(OSData, res)) {
		uint32_t len = d->getLength() < 16 ? d->getLength() : 16;
		for (uint32_t i = 0; i < len; i++) snprintf(hex + 3 * i, 4, "%02x ", ((const uint8_t *)d->getBytesNoCopy())[i]);
	} else if (auto num = OSDynamicCast(OSNumber, res)) snprintf(hex, sizeof(hex), "0x%llx", num->unsigned64BitValue());
	if (res) res->release();
	dlog("WMI %s notify 0x%x, _WED -> 0x%x %s", dev->getName(), code, r, hex);
	return kIOReturnSuccess;
}

static void wmiScan() {
	if (gWmiScanned) return;
	gWmiScanned = true;
	auto it = IORegistryIterator::iterateOver(gIOACPIPlane, kIORegistryIterateRecursively);
	if (!it) return;
	while (auto e = it->getNextObject()) {
		auto dev = OSDynamicCast(IOACPIPlatformDevice, e);
		// the brightness hotkeys (EC _Q11/_Q12) notify GFX0.DD1F instead of PEGP.LCD0 unless PSF0 bit 4 is set
		if (dev && !gDd1fNotifier && strcmp(dev->getName(), "DD1F") == 0) {
			gDd1fNotifier = dev->registerInterest(gIOGeneralInterest, lcdNotify, dev, nullptr);
			dlog("DD1F notify logger %s", gDd1fNotifier ? "installed" : "NOT installed");
		}
		if (!dev || dev->validateObject("_WDG") != kIOReturnSuccess) continue;
		OSObject *res = nullptr;
		if (dev->evaluateObject("_WDG", &res) != kIOReturnSuccess || !res) { dlog("WMI %s: _WDG unreadable", dev->getName()); continue; }
		auto d = OSDynamicCast(OSData, res);
		uint32_t n = d ? d->getLength() / 20 : 0;
		bool events = false;
		for (uint32_t i = 0; i < n; i++) {
			const uint8_t *g = (const uint8_t *)d->getBytesNoCopy() + 20 * i;
			uint8_t flags = g[19];
			dlog("WMI %s: %02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x id %c%c (0x%02x) inst %u flags 0x%x",
			     dev->getName(), g[3], g[2], g[1], g[0], g[5], g[4], g[7], g[6], g[8], g[9], g[10], g[11], g[12], g[13], g[14], g[15],
			     g[16] >= 0x20 && g[16] < 0x7f ? g[16] : '.', g[17] >= 0x20 && g[17] < 0x7f ? g[17] : '.', g[16], g[18], flags);
			if (flags & 0x8) events = true;
			if (!gWmi && !memcmp(g, kWmiBlGuid, 16) && (flags & 0x2)) {
				dev->retain();
				gWmi = dev;
				snprintf(gWmiMethod, sizeof(gWmiMethod), "WM%c%c", g[16], g[17]);
			}
		}
		res->release();
		if (events && gNumWmiNotifiers < arrsize(gWmiNotifiers))
			gWmiNotifiers[gNumWmiNotifiers++] = dev->registerInterest(gIOGeneralInterest, wmiNotify, dev, nullptr);
	}
	it->release();
	if (!gWmi) { dlog("WMI: no NVIDIA EC backlight GUID"); return; }
	uint32_t cur = 0;
	bool okS = wmiCall(2, 0, 0, &gWmiSource), okM = wmiCall(1, 2, 0, &gWmiMax), okC = wmiCall(1, 0, 0, &cur);
	dlog("WMI EC backlight on %s.%s: source %u%s (1 GPU, 2 EC, 3 AUX), max %u%s, level %u%s", gWmi->getName(), gWmiMethod,
	     gWmiSource, okS ? "" : "?", gWmiMax, okM ? "" : "?", cur, okC ? "" : "?");
	if (!okM || !gWmiMax) { gWmi->release(); gWmi = nullptr; }
}

// ---- ACPI tables (DSDT + SSDTs, concatenated as in memory) for offline disassembly: sysctl debug.nvdsm_acpi ----
static OSData *gTables;
// getACPITableData() is protected; reach it through a (never instantiated) subclass.
struct AcpiTables : public IOACPIPlatformExpert {
	static const OSData *get(IOACPIPlatformExpert *pe, const char *name, UInt32 i) { return static_cast<AcpiTables *>(pe)->getACPITableData(name, i); }
};
static int sysctlAcpi(struct sysctl_oid *, void *, int, struct sysctl_req *req) {
	if (!gTables) {
		auto pe = OSDynamicCast(IOACPIPlatformExpert, IOService::getPlatform());
		if (!pe) return ENODEV;
		auto all = OSData::withCapacity(256 * 1024);
		if (!all) return ENOMEM;
		if (auto t = AcpiTables::get(pe, "DSDT", 0)) all->appendBytes(t);
		for (UInt32 i = 0; i < 64; i++) {
			auto t = AcpiTables::get(pe, "SSDT", i);
			if (!t) break;
			all->appendBytes(t);
		}
		gTables = all;
	}
	return SYSCTL_OUT(req, gTables->getBytesNoCopy(), gTables->getLength());
}
SYSCTL_PROC(_debug, OID_AUTO, nvdsm_acpi, CTLTYPE_OPAQUE | CTLFLAG_RD | CTLFLAG_LOCKED, nullptr, 0, sysctlAcpi, "S", "DSDT + SSDTs");

// ---- backlight backends behind the sysctls: WMI EC (preferred) or the LCD's _BCL/_BCM ----
static bool blReady() {
	gpuAcpi();
	if (!gWmiScanned && mayBlock()) {
		if (gAcpiLock) IOLockLock(gAcpiLock);
		wmiScan();
		if (gAcpiLock) IOLockUnlock(gAcpiLock);
	}
	return gWmi || (gLcd && gNumLevels);
}

// Current level and range of the active backend. Caller holds gAcpiLock.
static void blRange(uint32_t *cur, uint32_t *lo, uint32_t *hi) {
	if (gWmi) {
		uint32_t v = 0;
		if (!wmiCall(1, 0, 0, &v)) v = gLastSet != UINT32_MAX ? gLastSet : gWmiMax;
		*cur = v; *lo = 0; *hi = gWmiMax;
		return;
	}
	*cur = currentLevel(); *lo = gLevels[0]; *hi = gLevels[gNumLevels - 1];
}

static IOReturn blWrite(uint32_t v) {
	if (!gWmi) return bcmWrite(v);
	if (v > gWmiMax) v = gWmiMax;
	uint32_t now = 0;
	bool ok = wmiCall(1, 1, v, nullptr);
	bool q = wmiCall(1, 0, 0, &now);
	if (ok) gLastSet = v;
	dlog("WMI set %u/%u -> %s, now %d", v, gWmiMax, ok ? "OK" : "FAILED", q ? (int)now : -1);
	return ok ? kIOReturnSuccess : kIOReturnError;
}

static int sysctlBlLevels(struct sysctl_oid *, void *, int, struct sysctl_req *req) {
	char buf[512]; size_t o = 0;
	buf[0] = 0;
	if (blReady()) {
		if (gWmi) {
			o += snprintf(buf, sizeof(buf), "wmi %u |", gWmiSource);
			for (uint32_t i = 0; i <= 20 && o + 8 < sizeof(buf); i++) o += snprintf(buf + o, sizeof(buf) - o, " %u", gWmiMax * i / 20);
		} else {
			o += snprintf(buf, sizeof(buf), "%u %u |", gBclAc, gBclBattery);
			for (uint32_t i = 0; i < gNumLevels && o + 6 < sizeof(buf); i++) o += snprintf(buf + o, sizeof(buf) - o, " %u", gLevels[i]);
		}
	}
	return SYSCTL_OUT(req, buf, strnlen(buf, sizeof(buf)) + 1);
}

static int sysctlBl(struct sysctl_oid *, void *arg1, int, struct sysctl_req *req) {
	bool pct = arg1 != nullptr;
	if (!blReady()) return ENODEV;
	if (gAcpiLock) IOLockLock(gAcpiLock);
	uint32_t cur, lo, hi;
	blRange(&cur, &lo, &hi);
	int out = pct ? (hi > lo ? (int)(((cur > lo ? cur - lo : 0) * 100 + (hi - lo) / 2) / (hi - lo)) : 100) : (int)cur;
	int in = out;
	int err = sysctl_handle_int(nullptr, &in, 0, req);
	if (!err && req->newptr && in != out) {
		if (in < 0) in = 0;
		uint32_t v = pct ? lo + (uint32_t)(((in > 100 ? 100 : in) * (hi - lo) + 50) / 100) : (uint32_t)in;
		err = blWrite(v) == kIOReturnSuccess ? 0 : EIO;
	}
	if (gAcpiLock) IOLockUnlock(gAcpiLock);
	return err;
}

SYSCTL_PROC(_debug, OID_AUTO, nvdsm_bl_levels, CTLTYPE_STRING | CTLFLAG_RD | CTLFLAG_LOCKED, nullptr, 0, sysctlBlLevels, "A", "backlight levels (WMI or ACPI _BCL)");
SYSCTL_PROC(_debug, OID_AUTO, nvdsm_bl_level, CTLTYPE_INT | CTLFLAG_RW | CTLFLAG_ANYBODY | CTLFLAG_LOCKED, nullptr, 0, sysctlBl, "I", "panel backlight, raw level");
SYSCTL_PROC(_debug, OID_AUTO, nvdsm_bl_pct, CTLTYPE_INT | CTLFLAG_RW | CTLFLAG_ANYBODY | CTLFLAG_LOCKED, (void *)1, 0, sysctlBl, "I", "panel backlight, percent");

#if NVDSM_IODISPLAY
// ---- macOS brightness API (IODisplay "brightness" parameter) ----
// NVRMFB publishes no display parameters, so DisplayServices / Control Center / the brightness keys see a
// display whose brightness cannot be changed. This parameter handler is attached to every IODisplay that
// appears and owns the standard "brightness" parameter (0..kUiMax); a set maps it onto the _BCL range and is
// carried out by _BCM on a thread call (IODisplay calls handlers with the framebuffer lock held).

static constexpr SInt32 kUiMax = 1024;
static thread_call_t gUiSetCall;
static volatile SInt32 gUiTarget = -1;

class NVDSMBrightness : public IODisplayParameterHandler {
	OSDeclareDefaultStructors(NVDSMBrightness)
	IODisplay *fDisplay {nullptr};
public:
	bool setDisplay(IODisplay *display) override { fDisplay = display; return display != nullptr; }
	bool doIntegerSet(OSDictionary *params, const OSSymbol *paramName, UInt32 value) override;
	bool doDataSet(const OSSymbol *, OSData *) override { return false; }
	bool doUpdate() override;
	void publish(SInt32 ui);
	IODisplay *display() { return fDisplay; }
};
OSDefineMetaClassAndStructors(NVDSMBrightness, IODisplayParameterHandler)

static NVDSMBrightness *gUiHandler;
static IONotifier *gDisplayNotifier;

static SInt32 levelToUi(uint32_t level) {
	if (!gNumLevels) return kUiMax;
	uint32_t lo = gLevels[0], hi = gLevels[gNumLevels - 1];
	if (hi <= lo) return kUiMax;
	if (level < lo) level = lo;
	if (level > hi) level = hi;
	return (SInt32)(((uint64_t)(level - lo) * kUiMax + (hi - lo) / 2) / (hi - lo));
}

static uint32_t uiToLevel(SInt32 ui) {
	uint32_t lo = gLevels[0], hi = gLevels[gNumLevels - 1];
	if (ui < 0) ui = 0;
	if (ui > kUiMax) ui = kUiMax;
	return lo + (uint32_t)(((uint64_t)ui * (hi - lo) + kUiMax / 2) / kUiMax);
}

void NVDSMBrightness::publish(SInt32 ui) {
	IODisplay *d = fDisplay;
	if (!d) return;
	OSObject *prop = d->copyProperty(gIODisplayParametersKey);
	OSDictionary *cur = OSDynamicCast(OSDictionary, prop);
	OSDictionary *dict = cur ? OSDictionary::withDictionary(cur) : OSDictionary::withCapacity(2);
	OSSafeReleaseNULL(prop);
	if (!dict) return;
	IODisplay::addParameter(dict, gIODisplayBrightnessKey, 0, kUiMax);
	IODisplay::setParameter(dict, gIODisplayBrightnessKey, ui);
	d->setProperty(gIODisplayParametersKey, dict);
	dict->release();
}

bool NVDSMBrightness::doUpdate() {
	if (!gNumLevels) return true;
	publish(levelToUi(gLastSet != UINT32_MAX ? gLastSet : gLevels[gNumLevels - 1]));
	return true;
}

bool NVDSMBrightness::doIntegerSet(OSDictionary *, const OSSymbol *paramName, UInt32 value) {
	if (paramName != gIODisplayBrightnessKey || !gNumLevels) return false;
	gUiTarget = (SInt32)value;
	if (gUiSetCall) thread_call_enter(gUiSetCall);
	return true;
}

static void uiSetWork(thread_call_param_t, thread_call_param_t) {
	SInt32 ui = gUiTarget;
	if (ui < 0) return;
	if (gAcpiLock) IOLockLock(gAcpiLock);
	uint32_t want = snapLevel(uiToLevel(ui));
	if (want != gLastSet) bcmWrite(want);
	if (gAcpiLock) IOLockUnlock(gAcpiLock);
}

// Keeps the published value in step with changes made by nvbl, the sysctls or the hotkeys.
static void displaySync() {
	if (gUiHandler && gUiHandler->display() && gLastSet != UINT32_MAX) gUiHandler->publish(levelToUi(gLastSet));
}

static bool displayPublished(void *, void *, IOService *service, IONotifier *) {
	auto display = OSDynamicCast(IODisplay, service);
	if (!display) return true;
	if (!blReady()) { dlog("IODisplay %s appeared but no ACPI backlight", display->getName()); return true; }
	if (!gUiSetCall) gUiSetCall = thread_call_allocate(uiSetWork, nullptr);
	auto h = new NVDSMBrightness;
	if (!h || !h->init()) { OSSafeReleaseNULL(h); return true; }
	if (gLastSet == UINT32_MAX) {
		uint32_t cur;
		gLastSet = bqcRead(&cur) ? snapLevel(cur) : gLevels[gNumLevels - 1];
	}
	bool ok = display->addParameterHandler(h);
	if (ok) {
		OSSafeReleaseNULL(gUiHandler);
		gUiHandler = h;
		h->retain();
		h->doUpdate();
	}
	h->release();
	dlog("IODisplay %s: brightness parameter handler %s (level %u -> ui %d/%d)", display->getName(), ok ? "attached" : "REFUSED", gLastSet, levelToUi(gLastSet), kUiMax);
	return true;
}

static void displayWatchStart() {
	OSDictionary *m = IOService::serviceMatching("IODisplay");
	if (!m) return;
	gDisplayNotifier = IOService::addMatchingNotification(gIOFirstPublishNotification, m, displayPublished, nullptr, nullptr, 0);
	m->release();
	dlog("IODisplay watch %s", gDisplayNotifier ? "installed" : "NOT installed");
}
#else
static void displaySync() {}
static void displayWatchStart() {}
#endif

// Same flattening as nv_acpi_extract_object(): integers are 4 bytes unless they need 8,
// buffers are copied whole, packages are concatenated.
static NV_STATUS extract(OSObject *o, uint8_t *buf, uint32_t cap, uint32_t *used) {
	*used = 0;
	if (!o) return NV_OK;
	if (auto n = OSDynamicCast(OSNumber, o)) {
		uint64_t v = n->unsigned64BitValue();
		uint32_t sz = (v >> 32) ? 8 : 4;
		*used = sz;
		if (cap < sz) return NV_ERR_BUFFER_TOO_SMALL;
		memcpy(buf, &v, sz);
		return NV_OK;
	}
	if (auto d = OSDynamicCast(OSData, o)) {
		*used = d->getLength();
		if (cap < *used) return NV_ERR_BUFFER_TOO_SMALL;
		if (*used) memcpy(buf, d->getBytesNoCopy(), *used);
		return NV_OK;
	}
	if (auto a = OSDynamicCast(OSArray, o)) {
		for (unsigned i = 0; i < a->getCount(); i++) {
			uint32_t el = 0;
			NV_STATUS st = extract(a->getObject(i), buf + *used, cap - *used, &el);
			if (st != NV_OK) return st;
			*used += el;
		}
		return NV_OK;
	}
	return NV_ERR_NOT_SUPPORTED;
}

static NV_STATUS evalDsm(const uint8_t *guid, uint32_t rev, uint32_t sub, const void *in, uint16_t inSize,
                         void *out, uint16_t *pSize) {
	auto acpi = gpuAcpi();
	if (!acpi) return NV_ERR_NOT_SUPPORTED;
	OSObject *params[4] = {
		OSData::withBytes(guid, 16),
		OSNumber::withNumber(rev, 32),
		OSNumber::withNumber(sub, 32),
		OSData::withBytes(in, inSize),
	};
	OSObject *res = nullptr;
	IOReturn r = kIOReturnNoMemory;
	if (params[0] && params[1] && params[2] && params[3])
		r = acpi->evaluateObject("_DSM", &res, params, 4);
	for (auto p : params) if (p) p->release();
	if (r != kIOReturnSuccess) {
		dlog("%s sub 0x%x: _DSM evaluate failed 0x%x", guidName(guid), sub, r);
		if (res) res->release();
		return NV_ERR_OPERATING_SYSTEM;
	}
	uint32_t used = 0;
	NV_STATUS st = extract(res, (uint8_t *)out, *pSize, &used);
	if (res) res->release();
	*pSize = (uint16_t)used;
	return st;
}

static void logResult(const char *tag, const uint8_t *guid, uint32_t sub, NV_STATUS st, const void *out, uint16_t size) {
	const uint8_t *b = (const uint8_t *)out;
	char hex[3 * 24 + 1]; hex[0] = 0;
	uint32_t n = size < 24 ? size : 24;
	for (uint32_t i = 0; i < n; i++) snprintf(hex + 3 * i, 4, "%02x ", b[i]);
	dlog("%s %s sub 0x%x -> st 0x%x size %u: %s%s", tag, guidName(guid), sub, st, size, hex, size > 24 ? "..." : "");
}

static uint32_t gCalls;

static NV_STATUS wrapDsm(void *nv, uint8_t *guid, uint32_t rev, bool nvpcf, uint32_t sub,
                         void *in, uint16_t inSize, uint32_t *outStatus, void *out, uint16_t *pSize) {
	uint32_t call = ++gCalls;
	if (!guid || !in || !out || !pSize || inSize > kMaxDsmParamSize || nvpcf) {
		dlog("#%u %s sub 0x%x nvpcf %u: not handled", call, guid ? guidName(guid) : "null", sub, nvpcf);
		return NV_ERR_NOT_SUPPORTED;
	}
	bool nbci = !memcmp(guid, kNBCI, 16), nvhg = !memcmp(guid, kNVHG, 16);
	bool allowed = (nbci || nvhg) && (sub == kFuncAllSupport || sub == kFuncGetBacklight);
	if (!mayBlock()) {
		dlog("#%u %s sub 0x%x called in atomic context, not evaluated", call, guidName(guid), sub);
		return NV_ERR_NOT_SUPPORTED;
	}

	if (!allowed) {
		if (sub == kFuncAllSupport) {
			uint8_t tmp[64]; uint16_t sz = sizeof(tmp);
			NV_STATUS st = evalDsm(guid, rev, sub, in, inSize, tmp, &sz);
			logResult("probe(not given to RM)", guid, sub, st, tmp, sz);
		} else {
			dlog("#%u %s rev 0x%x sub 0x%x in %u: not allowlisted", call, guidName(guid), rev, sub, inSize);
		}
		return NV_ERR_NOT_SUPPORTED;
	}

	// in and out are the same RM buffer: evalDsm copies the input into an OSData before writing out.
	uint16_t cap = *pSize;
	NV_STATUS st = evalDsm(guid, rev, sub, in, inSize, out, pSize);
	if (st == NV_OK && sub == kFuncAllSupport && *pSize >= 4) {
		uint32_t mask = 0;
		memcpy(&mask, out, 4);
		uint32_t keep = mask & ((1u << kFuncAllSupport) | (1u << kFuncGetBacklight));
		dlog("#%u %s rev 0x%x capabilities 0x%08x -> exposing 0x%08x", call, guidName(guid), rev, mask, keep);
		memcpy(out, &keep, 4);
		if (!(keep & (1u << kFuncGetBacklight))) {
			// Nothing useful on this GUID: report it the way the stub does.
			*pSize = cap;
			return NV_ERR_NOT_SUPPORTED;
		}
	}
	logResult("RM", guid, sub, st, out, *pSize);
	return st;
}

// nv_acpi_dod_method(): NullMoth's stub returns NOT_SUPPORTED, so RM's acpiMethodData.dodMethodData (handed to GSP)
// has no ACPI display IDs and GSP cannot tie the NBCI GETBACKLIGHT entry (ACPI id 0x8000a450) to the panel.
// Same contract as the Linux nv_acpi_dod_method(): *pSize in = buffer bytes, out = bytes of NvU32 ids written.
static NV_STATUS wrapDod(void *nv, uint32_t *out, uint32_t *pSize) {
	if (!out || !pSize) return NV_ERR_NOT_SUPPORTED;
	if (!mayBlock()) { dlog("_DOD called in atomic context, not evaluated"); return NV_ERR_NOT_SUPPORTED; }
	auto acpi = gpuAcpi();
	if (!acpi) return NV_ERR_NOT_SUPPORTED;
	OSObject *res = nullptr;
	IOReturn r = acpi->evaluateObject("_DOD", &res);
	auto arr = OSDynamicCast(OSArray, res);
	uint32_t cap = *pSize / 4, n = 0;
	NV_STATUS st = NV_OK;
	if (r != kIOReturnSuccess || !arr) st = 0xffff;   // NV_ERR_GENERIC
	else if (arr->getCount() > cap) st = 0xffff;
	else for (unsigned i = 0; i < arr->getCount(); i++) {
		auto num = OSDynamicCast(OSNumber, arr->getObject(i));
		if (!num) { st = 0xffff; break; }
		out[n++] = num->unsigned32BitValue();
	}
	if (res) res->release();
	if (st == NV_OK) *pSize = n * 4;
	char ids[96] = ""; size_t o = 0;
	for (uint32_t i = 0; i < n && o + 12 < sizeof(ids); i++) o += snprintf(ids + o, sizeof(ids) - o, "0x%08x ", out[i]);
	dlog("_DOD -> eval 0x%x, status 0x%x, %u id(s): %s", r, st, n, ids);
	return st;
}

// ---- NVKMS backlight (v8) ----
// Once GSP knows the panel (_DOD above), NVKMS's nvRmRegisterBacklight() finds the eDP backlight at device allocation
// and calls nvkms_register_backlight(gpu_id, display_id, pDispEvo, brightness) - a stub returning NULL in NullMoth.
// We keep (display_id, pDispEvo) and drive nvKmsGet/SetBacklight() (PERCENT100, RM control from NVKMS's own privileged
// client) under NVKMS's gKmsLock, the lock nvkms_ioctl_from_kapi holds around every NVKMS entry. A non-NULL cookie is
// returned so nvRmUnregisterBacklight() reports the device going away. NVRMFB reaches this through the resource
// "NVDSMBacklight" (OSData: NVDSMBacklightAPI) to back the IODisplay "brightness" parameter.
struct NVDSMBacklightAPI {
	uint32_t version;   // 1
	IOReturn (*get)(uint32_t *pct);
	IOReturn (*set)(uint32_t pct);
};
using kmsGetBl_t = uint8_t (*)(uint32_t displayId, void *drvPriv, uint32_t *brightness);
using kmsSetBl_t = uint8_t (*)(uint32_t displayId, void *drvPriv, uint32_t brightness);
static kmsGetBl_t gKmsGetBl;
static kmsSetBl_t gKmsSetBl;
static IOLock **gKmsLockPtr;
static struct { uint32_t gpuId, displayId; void *disp; } gKmsBl;

static void *wrapRegisterBl(uint32_t gpuId, uint32_t displayId, void *drvPriv, uint32_t brightness) {
	gKmsBl.gpuId = gpuId; gKmsBl.displayId = displayId; gKmsBl.disp = drvPriv;
	gKmsBlValid = drvPriv != nullptr;
	dlog("nvkms_register_backlight: gpu 0x%x display 0x%x brightness %u", gpuId, displayId, brightness);
	return &gKmsBl;
}

static void wrapUnregisterBl(void *bd) {
	if (bd == &gKmsBl) gKmsBlValid = false;
	dlog("nvkms_unregister_backlight %s", bd == &gKmsBl ? "(ours)" : "(unknown cookie)");
}

static IOReturn kmsBacklight(bool set, uint32_t *pct) {
	if (!gKmsGetBl || !gKmsSetBl || !gKmsLockPtr || !*gKmsLockPtr) return kIOReturnNotReady;
	if (!mayBlock()) return kIOReturnNotPermitted;
	IOLockLock(*gKmsLockPtr);
	IOReturn r = kIOReturnNotFound;
	if (gKmsBlValid) {
		uint32_t v = *pct > 100 ? 100 : *pct;
		bool ok = set ? gKmsSetBl(gKmsBl.displayId, gKmsBl.disp, v) : gKmsGetBl(gKmsBl.displayId, gKmsBl.disp, pct);
		r = ok ? kIOReturnSuccess : kIOReturnError;
	}
	IOLockUnlock(*gKmsLockPtr);
	return r;
}
static IOReturn kmsBlGet(uint32_t *pct) { return kmsBacklight(false, pct); }
static IOReturn kmsBlSet(uint32_t pct) { return kmsBacklight(true, &pct); }
static const NVDSMBacklightAPI kBlApi { 1, kmsBlGet, kmsBlSet };

static int sysctlKmsBl(struct sysctl_oid *, void *, int, struct sysctl_req *req) {
	uint32_t cur = 0;
	IOReturn r = kmsBlGet(&cur);
	if (r != kIOReturnSuccess) return r == kIOReturnNotFound ? ENODEV : EIO;
	int in = (int)cur;
	int err = sysctl_handle_int(nullptr, &in, 0, req);
	if (!err && req->newptr) err = kmsBlSet(in < 0 ? 0 : (uint32_t)in) == kIOReturnSuccess ? 0 : EIO;
	return err;
}
SYSCTL_PROC(_debug, OID_AUTO, nvdsm_kms_bl, CTLTYPE_INT | CTLFLAG_RW | CTLFLAG_ANYBODY | CTLFLAG_LOCKED, nullptr, 0, sysctlKmsBl, "I", "panel backlight percent via NVKMS");

static const char kNvrmPath[] = "/Library/Extensions/NVRM.kext/Contents/MacOS/NVRM";
static const char *kNvrmPaths[] = { kNvrmPath };
static KernelPatcher::KextInfo kextNVRM { "com.nullmoth.NVRM", kNvrmPaths, 1, {true}, {}, KernelPatcher::KextInfo::Unloaded };

static void pluginStart() {
	uint32_t mode = 1;
	if (lilu_get_boot_args("nvdsm", &mode, sizeof(mode))) gMode = mode;
	gLogLock = IOLockAlloc();
	gAcpiLock = IOLockAlloc();
	sysctl_register_oid(&sysctl__debug_nvdsm_log);
	sysctl_register_oid(&sysctl__debug_nvdsm_bl_levels);
	sysctl_register_oid(&sysctl__debug_nvdsm_bl_level);
	sysctl_register_oid(&sysctl__debug_nvdsm_bl_pct);
	sysctl_register_oid(&sysctl__debug_nvdsm_acpi);
	sysctl_register_oid(&sysctl__debug_nvdsm_kms_bl);
	dlog("start, mode %u", gMode);
	if (gMode == 0) return;
	displayWatchStart();

	lilu.onPatcherLoadForce([](void *, KernelPatcher &patcher) {
		gPreemptionEnabled = reinterpret_cast<bool (*)()>(patcher.solveSymbol(KernelPatcher::KernelID, "_preemption_enabled"));
		patcher.clearError();
		dlog("preemption_enabled %s", gPreemptionEnabled ? "resolved" : "NOT resolved");
	});

	lilu.onKextLoadForce(&kextNVRM, 1, [](void *, KernelPatcher &patcher, size_t index, mach_vm_address_t address, size_t size) {
		if (index != kextNVRM.loadIndex) return;
		KernelPatcher::RouteRequest req("_nv_acpi_dsm_method", wrapDsm);
		bool ok = patcher.routeMultiple(index, &req, 1, address, size);
		dlog("route _nv_acpi_dsm_method in NVRM: %s (err %d)", ok ? "OK" : "FAILED", patcher.getError());
		patcher.clearError();
		if (gMode >= 1) {
			KernelPatcher::RouteRequest dod("_nv_acpi_dod_method", wrapDod);
			ok = patcher.routeMultiple(index, &dod, 1, address, size);
			dlog("route _nv_acpi_dod_method in NVRM: %s (err %d)", ok ? "OK" : "FAILED", patcher.getError());
			patcher.clearError();
		}
		if (gMode >= 1) {
			gKmsGetBl = reinterpret_cast<kmsGetBl_t>(patcher.solveSymbol(index, "_nvKmsGetBacklight", address, size));
			patcher.clearError();
			gKmsSetBl = reinterpret_cast<kmsSetBl_t>(patcher.solveSymbol(index, "_nvKmsSetBacklight", address, size));
			patcher.clearError();
			gKmsLockPtr = reinterpret_cast<IOLock **>(patcher.solveSymbol(index, "__ZL8gKmsLock", address, size));
			patcher.clearError();
			dlog("NVKMS backlight symbols: get %s set %s gKmsLock %s", gKmsGetBl ? "ok" : "MISSING",
			     gKmsSetBl ? "ok" : "MISSING", gKmsLockPtr ? "ok" : "MISSING");
			if (gKmsGetBl && gKmsSetBl && gKmsLockPtr) {
				KernelPatcher::RouteRequest bl[] {
					{"_nvkms_register_backlight", wrapRegisterBl},
					{"_nvkms_unregister_backlight", wrapUnregisterBl},
				};
				ok = patcher.routeMultiple(index, bl, arrsize(bl), address, size);
				dlog("route nvkms_(un)register_backlight in NVRM: %s (err %d)", ok ? "OK" : "FAILED", patcher.getError());
				patcher.clearError();
				if (ok) {
					OSData *api = OSData::withBytes(&kBlApi, sizeof(kBlApi));
					if (api) { IOService::publishResource("NVDSMBacklight", api); api->release(); }
					dlog("resource NVDSMBacklight %s", api ? "published" : "NOT published");
				}
			}
		}
	});
}

static const char *bootargOff[] = { "-nvdsmoff" };
static const char *bootargDebug[] = { "-nvdsmdbg" };
static const char *bootargBeta[] = { "-nvdsmbeta" };

PluginConfiguration ADDPR(config) {
	xStringify(PRODUCT_NAME),
	parseModuleVersion(xStringify(MODULE_VERSION)),
	LiluAPI::AllowNormal | LiluAPI::AllowSafeMode,
	bootargOff, arrsize(bootargOff),
	bootargDebug, arrsize(bootargDebug),
	bootargBeta, arrsize(bootargBeta),
	KernelVersion::Sequoia,
	KernelVersion::Sequoia,
	pluginStart
};
