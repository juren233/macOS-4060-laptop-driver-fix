// BTLEFix: Intel AX211 Bluetooth on macOS 15 in bluetoothd's external-dongle mode.
//
// 1. bluetoothd sends LE Read Buffer Size [v2] (0x2060) whenever LE feature byte 3 is >= 0x10 (ISO host support and
//    up), without checking Supported Commands octet 41 bit 5. Intel AX211 firmware sets those LE feature bits but does
//    not implement v2 (octet 41 = 0xC8), the command fails and bluetoothd aborts HCI init ("Third Party USB Bluetooth
//    dongle failed initialization"). Linux checks the command bit; this patch makes bluetoothd take the v1 branch.
//    Same mechanism as BlueToolFixup: patch the code page when it is validated (cs_validate_page).
// 2. Replaces IntelBTPatcher (disable it: both route IOUSBHostDevice::deviceRequest): before the first LE Set Scan
//    Parameters (0x200B) or LE Set Extended Scan Parameters (0x2041) after a reset, send LE Set Random Address, which
//    Intel firmware needs before scanning with a random own address.
// 4. Connecting a headset took several clicks: bluetoothd sends Inquiry Cancel (0x0402) and Create Connection (0x0405)
//    back to back while its inquiry runs; Intel firmware has not left the inquiry yet and fails the page at once with
//    Command Disallowed (bluetoothd STATUS 712 = 700 + HCI 0x0C). So: send Inquiry Cancel first if an inquiry may still
//    be active, and hold a Create Connection until debug.btlefix_page_delay_ms (default 100, writable without root)
//    have passed since the last Inquiry Cancel.
// 3. HCI trace: every HCI command sent through deviceRequest is logged to kprintf ("BTLEFix:") and to
//    `sysctl debug.btlefix_log` (ring of the last lines). Events are NOT traced: wrapping IOUSBHostPipe::io completions
//    and reading the buffer there panicked ("IOGMD: not wired for the IODMACommand") - the descriptor is no longer
//    prepared when the completion runs.
#include <Headers/plugin_start.hpp>
#include <Headers/kern_api.hpp>
#include <Headers/kern_util.hpp>
#include <IOKit/IOLib.h>
#include <IOKit/IOMemoryDescriptor.h>
#include <IOKit/IOBufferMemoryDescriptor.h>
#include <IOKit/usb/IOUSBHostFamily.h>
#include <IOKit/usb/IOUSBHostIOSource.h>
#include <IOKit/usb/StandardUSB.h>
#include <sys/vnode.h>
#include <sys/sysctl.h>
#include <stdarg.h>

#define MODULE_SHORT "btlefix"

extern "C" void kprintf(const char *fmt, ...);

// ---- log ring: kprintf + sysctl debug.btlefix_log ----
static char gLog[32768];
static size_t gLogHead;      // next write position
static bool gLogWrapped;
static IOSimpleLock *gLogLock;

static void blog(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void blog(const char *fmt, ...) {
	char line[200];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(line, sizeof(line), fmt, ap);
	va_end(ap);
	kprintf("BTLEFix: %s\n", line);
	if (!gLogLock) return;
	size_t n = strnlen(line, sizeof(line));
	IOSimpleLockLock(gLogLock);
	for (size_t i = 0; i <= n; i++) {
		gLog[gLogHead++] = i < n ? line[i] : '\n';
		if (gLogHead == sizeof(gLog)) { gLogHead = 0; gLogWrapped = true; }
	}
	IOSimpleLockUnlock(gLogLock);
}

static int sysctlLog(struct sysctl_oid *, void *, int, struct sysctl_req *req) {
	static char out[sizeof(gLog) + 1];
	size_t n = 0;
	IOSimpleLockLock(gLogLock);
	if (gLogWrapped) { memcpy(out, gLog + gLogHead, sizeof(gLog) - gLogHead); n = sizeof(gLog) - gLogHead; }
	memcpy(out + n, gLog, gLogHead);
	n += gLogHead;
	IOSimpleLockUnlock(gLogLock);
	out[n] = 0;
	return SYSCTL_OUT(req, out, n + 1);
}
SYSCTL_PROC(_debug, OID_AUTO, btlefix_log, CTLTYPE_STRING | CTLFLAG_RD | CTLFLAG_LOCKED, nullptr, 0, sysctlLog, "A", "BTLEFix HCI trace");

static void hex(char *out, size_t cap, const uint8_t *b, size_t n) {
	size_t o = 0;
	out[0] = 0;
	for (size_t i = 0; i < n && o + 4 < cap; i++) o += snprintf(out + o, cap - o, "%02x ", b[i]);
}

// ---- 1. bluetoothd page patch ----
// cmpb $1, 0x49(%r14); jne +0x15; cmpb $0x10, 0x27(%r14); jae +0x1e   ->   ... ; nop nop
static const uint8_t kFind[]  = { 0x41, 0x80, 0x7E, 0x49, 0x01, 0x75, 0x15, 0x41, 0x80, 0x7E, 0x27, 0x10, 0x73, 0x1E };
static const uint8_t kRepl[]  = { 0x41, 0x80, 0x7E, 0x49, 0x01, 0x75, 0x15, 0x41, 0x80, 0x7E, 0x27, 0x10, 0x90, 0x90 };

static mach_vm_address_t orgValidate {};
static bool reported;

static void patchedValidatePage(vnode_t vp, memory_object_t pager, memory_object_offset_t off, const void *data,
                                int *validated, int *tainted, int *nx) {
	FunctionCast(patchedValidatePage, orgValidate)(vp, pager, off, data, validated, tainted, nx);
	char path[PATH_MAX]; int len = PATH_MAX;
	if (vn_getpath(vp, path, &len) == 0 && UNLIKELY(strcmp(path, "/usr/sbin/bluetoothd") == 0)) {
		if (KernelPatcher::findAndReplace(const_cast<void *>(data), PAGE_SIZE, kFind, sizeof kFind, kRepl, sizeof kRepl) && !reported) {
			reported = true;
			blog("bluetoothd: LE Read Buffer Size v2 branch disabled");
		}
	}
}

// ---- 2./3. HCI commands (deviceRequest) ----
using devReq_t = IOReturn (*)(void *, IOService *, StandardUSB::DeviceRequest &, void *, IOMemoryDescriptor *, unsigned int &,
                              IOUSBHostCompletion *, unsigned int);
static mach_vm_address_t orgDevReq {};
static bool gRandomAddrSent;
static IOBufferMemoryDescriptor *gRandomAddrMd;
// LE Set Random Address (0x2005), static random address (top two bits set), same value IntelBTPatcher uses.
static const uint8_t kRandomAddrHci[9] = {0x05, 0x20, 0x06, 0x94, 0x50, 0x64, 0xD0, 0x78, 0x6B};

// Inquiry Cancel (0x0402, no parameters). An inquiry ends by itself after Inquiry_Length x 1.28 s (Inquiry Complete
// events are not seen here), so it counts as active until then unless cancelled or reset.
static IOBufferMemoryDescriptor *gInqCancelMd;
static const uint8_t kInqCancelHci[3] = {0x02, 0x04, 0x00};
static uint64_t gInquiryEndNs;   // 0: no inquiry running
static uint64_t gInqCancelNs;    // when the last Inquiry Cancel was sent
static int gPageDelayMs = 100;
SYSCTL_INT(_debug, OID_AUTO, btlefix_page_delay_ms, CTLFLAG_RW | CTLFLAG_ANYBODY | CTLFLAG_LOCKED, &gPageDelayMs, 0,
           "ms between Inquiry Cancel and Create Connection");

static uint64_t nowNs() {
	uint64_t ns;
	absolutetime_to_nanoseconds(mach_absolute_time(), &ns);
	return ns;
}

static IOReturn injectHci(void *that, IOService *provider, const StandardUSB::DeviceRequest &request, IOBufferMemoryDescriptor *&md,
                          const uint8_t *cmd, size_t len, unsigned int timeout);

// Only the Intel Bluetooth device (idVendor 0x8087): UVC cameras etc. send the same class/interface requests.
static void *gBtDev, *gOtherDev;
static bool isIntelBt(void *dev) {
	if (dev == gBtDev) return true;
	if (dev == gOtherDev || !dev) return false;
	auto num = OSDynamicCast(OSNumber, static_cast<IORegistryEntry *>(dev)->getProperty("idVendor"));
	if (num && num->unsigned32BitValue() == 0x8087) { gBtDev = dev; return true; }
	gOtherDev = dev;
	return false;
}

static IOReturn patchedDevReq(void *that, IOService *provider, StandardUSB::DeviceRequest &request, void *data,
                              IOMemoryDescriptor *descriptor, unsigned int &length, IOUSBHostCompletion *completion,
                              unsigned int timeout) {
	uint8_t buf[64];
	size_t n = 0;
	// HCI commands are class requests to the interface, host to device, bRequest 0 (Intel uses 0 or 0xE0)
	bool hci = (request.bmRequestType & 0x7f) == 0x21 && request.wLength >= 3 && request.wLength <= 260 && isIntelBt(that);
	if (hci) {
		if (data) {
			n = request.wLength < sizeof(buf) ? request.wLength : sizeof(buf);
			memcpy(buf, data, n);
		} else if (descriptor && descriptor->getLength() >= 3) {
			if (descriptor->prepare(kIODirectionOut) == kIOReturnSuccess) {   // never read an unwired descriptor
				n = descriptor->readBytes(0, buf, descriptor->getLength() < sizeof(buf) ? descriptor->getLength() : sizeof(buf));
				descriptor->complete(kIODirectionOut);
			}
		}
	}
	if (n >= 3) {
		uint16_t op = (uint16_t)(buf[0] | buf[1] << 8);
		char h[3 * 24 + 1];
		hex(h, sizeof(h), buf + 3, n - 3 < 24 ? n - 3 : 24);
		blog("C %04x len %u: %s", op, buf[2], h);
		if (op == 0x0c03) { gRandomAddrSent = false; gInquiryEndNs = 0; }   // HCI_Reset: random address + inquiry gone
		if ((op == 0x200b || op == 0x2041) && !gRandomAddrSent) {
			IOReturn rr = injectHci(that, provider, request, gRandomAddrMd, kRandomAddrHci, sizeof(kRandomAddrHci), timeout);
			gRandomAddrSent = true;
			blog("C 2005 (injected before %04x): LE Set Random Address -> 0x%x", op, rr);
		}
		if (op == 0x0401 && n >= 7)   // LAP[3], Inquiry_Length (x 1.28 s), Num_Responses; +1 s margin
			gInquiryEndNs = nowNs() + (uint64_t)buf[6] * 1280000000ULL + 1000000000ULL;
		else if (op == 0x0402) {
			gInquiryEndNs = 0;
			gInqCancelNs = nowNs();
		} else if (op == 0x0405) {
			if (gInquiryEndNs && nowNs() < gInquiryEndNs) {
				IOReturn rr = injectHci(that, provider, request, gInqCancelMd, kInqCancelHci, sizeof(kInqCancelHci), timeout);
				gInquiryEndNs = 0;
				gInqCancelNs = nowNs();
				blog("C 0402 (injected before 0405): Inquiry Cancel -> 0x%x", rr);
			}
			int delayMs = gPageDelayMs;
			if (delayMs > 1000) delayMs = 1000;
			uint64_t since = gInqCancelNs ? nowNs() - gInqCancelNs : UINT64_MAX;
			if (delayMs > 0 && since < (uint64_t)delayMs * 1000000ULL && !ml_at_interrupt_context() && ml_get_interrupts_enabled()) {
				uint32_t waitMs = (uint32_t)(((uint64_t)delayMs * 1000000ULL - since + 999999ULL) / 1000000ULL);
				IOSleep(waitMs);
				blog("0405 held %u ms after Inquiry Cancel (%s)", waitMs, completion ? "async" : "sync");
			}
		}
	}
	return FunctionCast(patchedDevReq, orgDevReq)(that, provider, request, data, descriptor, length, completion, timeout);
}

// Send one extra HCI command synchronously on the same control endpoint, ahead of the one being sent.
static IOReturn injectHci(void *that, IOService *provider, const StandardUSB::DeviceRequest &request, IOBufferMemoryDescriptor *&md,
                          const uint8_t *cmd, size_t len, unsigned int timeout) {
	if (!md) md = IOBufferMemoryDescriptor::withBytes(cmd, len, kIODirectionOut);
	if (!md) return kIOReturnNoMemory;
	StandardUSB::DeviceRequest r = request;
	r.wLength = (uint16_t)len;
	unsigned int l = (unsigned int)len;
	md->prepare(kIODirectionOut);
	IOReturn rr = FunctionCast(patchedDevReq, orgDevReq)(that, provider, r, nullptr, md, l, nullptr, timeout);
	md->complete(kIODirectionOut);
	return rr;
}

static const char *kUsbPaths[] { "/System/Library/Extensions/IOUSBHostFamily.kext/Contents/MacOS/IOUSBHostFamily" };
static KernelPatcher::KextInfo kextUsb { "com.apple.iokit.IOUSBHostFamily", kUsbPaths, 1, {true, true}, {}, KernelPatcher::KextInfo::Unloaded };

static void pluginStart() {
	gLogLock = IOSimpleLockAlloc();
	sysctl_register_oid(&sysctl__debug_btlefix_log);
	sysctl_register_oid(&sysctl__debug_btlefix_page_delay_ms);
	blog("start");
	lilu.onPatcherLoadForce([](void *, KernelPatcher &patcher) {
		KernelPatcher::RouteRequest r("_cs_validate_page", patchedValidatePage, orgValidate);
		if (!patcher.routeMultipleLong(KernelPatcher::KernelID, &r, 1))
			blog("failed to route cs_validate_page");
		patcher.clearError();
	});
	lilu.onKextLoadForce(&kextUsb, 1, [](void *, KernelPatcher &patcher, size_t index, mach_vm_address_t address, size_t size) {
		if (index != kextUsb.loadIndex) return;
		KernelPatcher::RouteRequest req("__ZN15IOUSBHostDevice13deviceRequestEP9IOServiceRN11StandardUSB13DeviceRequestEPvP18IOMemoryDescriptorRjP19IOUSBHostCompletionj",
		                                patchedDevReq, orgDevReq);
		bool ok = patcher.routeMultiple(index, &req, 1, address, size);
		blog("route IOUSBHostDevice::deviceRequest: %s (err %d)", ok ? "OK" : "FAILED", patcher.getError());
		patcher.clearError();
	});
}

static const char *bootargOff[] { "-btlefixoff" };
static const char *bootargDebug[] { "-btlefixdbg" };
static const char *bootargBeta[] { "-btlefixbeta" };

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
