// BTLEFix: Intel AX211 Bluetooth on macOS 15 / 26 in bluetoothd's external-dongle mode (+ the macOS 26 AppleHDA resource shim, 5.).
//
// 1. bluetoothd sends LE Read Buffer Size [v2] (0x2060) whenever LE feature byte 3 is >= 0x10 (ISO host support and
//    up), without checking Supported Commands octet 41 bit 5. Intel AX211 firmware sets those LE feature bits but does
//    not implement v2 (octet 41 = 0xC8), the command fails and bluetoothd aborts HCI init ("Third Party USB Bluetooth
//    dongle failed initialization"). Linux checks the command bit; this patch makes bluetoothd take the v1 branch.
//    Together with the BlueToolFixup bluetoothd/BlueTool patches, it is applied only to the process-private copy of
//    the executable pages after exec, before user code runs. The file-backed UBC pages are never modified.
// 2. Replaces IntelBTPatcher (disable it: both route IOUSBHostDevice::deviceRequest): before the first LE Set Scan
//    Parameters (0x200B) or LE Set Extended Scan Parameters (0x2041) after a reset, send LE Set Random Address, which
//    Intel firmware needs before scanning with a random own address.
// 3. HCI trace: every HCI command sent through deviceRequest is logged to kprintf ("BTLEFix:") and to
//    `sysctl debug.btlefix_log` (ring of the last lines). Events are NOT traced: wrapping IOUSBHostPipe::io completions
//    and reading the buffer there panicked ("IOGMD: not wired for the IODMACommand") - the descriptor is no longer
//    prepared when the completion runs.
// 4. Connecting a headset took several clicks: bluetoothd sends Inquiry Cancel (0x0402) and Create Connection (0x0405)
//    back to back while its inquiry runs; Intel firmware has not left the inquiry yet and fails the page at once with
//    Command Disallowed (bluetoothd STATUS 712 = 700 + HCI 0x0C). So: send Inquiry Cancel first if an inquiry may still
//    be active, and hold a Create Connection until debug.btlefix_page_delay_ms (default 100, writable without root)
//    have passed since the last Inquiry Cancel.
// 5. macOS 26 built-in audio (AppleHDA out of the OS image, loaded from the auxiliary kernel collection): AppleHDADriver::startAction
//    calls OSKextRequestResource("com.apple.driver.AppleHDA", "layoutN.xml.zlib" / "Platforms.xml.zlib") and waits on a semaphore
//    for the callback. kernelmanagerd refuses ("Cannot insert Kext com.apple.driver.AppleHDA ... into a restricted lookup table")
//    and never answers, so the driver hangs for ever and there is no built-in audio. Answer the request ourselves: read the file
//    from the kext bundle and call the callback (AppleALC routes that callback and substitutes its own layout/platform data).
#include <Headers/plugin_start.hpp>
#include <Headers/kern_api.hpp>
#include <Headers/kern_util.hpp>
#include <IOKit/IOLib.h>
#include <IOKit/IOMemoryDescriptor.h>
#include <IOKit/IOBufferMemoryDescriptor.h>
#include <IOKit/IOLocks.h>
#include <IOKit/usb/IOUSBHostFamily.h>
#include <IOKit/usb/IOUSBHostIOSource.h>
#include <IOKit/usb/StandardUSB.h>
#include <libkern/OSKextLib.h>
#include <Headers/kern_file.hpp>
#include <Headers/kern_devinfo.hpp>
#include <kern/cs_blobs.h>
#include <mach-o/fat.h>
#include <mach-o/loader.h>
#include <sys/errno.h>
#include <sys/kauth.h>
#include <sys/proc.h>
#include <sys/vnode.h>
#include <sys/sysctl.h>
#include <sys/uio.h>
#include <stdarg.h>

#define MODULE_SHORT "btlefix"

extern "C" void kprintf(const char *fmt, ...);
extern "C" void *get_bsdtask_info(task_t task);
extern "C" vnode_t proc_getexecutablevnode(proc_t proc);

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

// ---- 1. process-private bluetoothd/BlueTool patches ----
// cmpb $1, 0x69(%r14); jne +0x15; cmpb $0x10, 0x27(%r14); jae +0x1e   ->   ... ; nop nop
static const uint8_t kLeFind26[] = { 0x41, 0x80, 0x7E, 0x69, 0x01, 0x75, 0x15, 0x41, 0x80, 0x7E, 0x27, 0x10, 0x73, 0x1E };
static const uint8_t kLeRepl26[] = { 0x41, 0x80, 0x7E, 0x69, 0x01, 0x75, 0x15, 0x41, 0x80, 0x7E, 0x27, 0x10, 0x90, 0x90 };

// BlueToolFixup patterns. They are copied here because BlueToolFixup must be disabled with -btlfxoff.
static const uint8_t kVendorFind[] = { 0x81, 0xFA, 0x5C, 0x0A, 0x00, 0x00, 0x74 };
static const uint8_t kVendorRepl[] = { 0x81, 0xFA, 0x5C, 0x0A, 0x00, 0x00, 0xEB };
static const uint8_t kChipsetFind[] = { 0x81, 0xF9, 0xCF, 0x07, 0x00, 0x00, 0x72 };
static const uint8_t kChipsetRepl[] = { 0x81, 0xF9, 0xCF, 0x07, 0x00, 0x00, 0xEB };
static const uint8_t kChipset154Find[] = { 0x81, 0xF9, 0x6F, 0x17, 0x00, 0x00, 0x77, 0x30 };
static const uint8_t kChipset154Repl[] = { 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90 };
static const uint8_t kBoardIdFind[] = "Mac-F60DEB81FF30ACF6";
static const uint8_t kBlueToolPathFind[] = "/etc/bluetool/SkipBluetoothAutomaticFirmwareUpdate";
static const uint8_t kBlueToolPathRepl[] = "/System/Library/CoreServices/boot.efi";

static char gBoardId[48];
static uint16_t gBoardIdLen;
static bool gPatchBoardId;
static bool gCowEnabled = true;
static bool gCowReady;
static IOLock *gCowLock;
static IOSimpleLock *gCowStatusLock;
static char gCowStatus[512] = "not triggered";

static mach_vm_address_t orgTaskSetMainThreadQos {};

using tGetBsdTaskInfo = proc_t (*)(task_t);
using tProcGetExecutableVnode = vnode_t (*)(proc_t);
using tProcBestName = char *(*)(proc_t);
using tProcPid = int (*)(proc_t);
using tProcCsflags = int (*)(proc_t, uint64_t *);
using tGetTaskMap = vm_map_t (*)(task_t);
using tGetMapMin = mach_vm_offset_t (*)(vm_map_t);
using tVmMapReadUser = kern_return_t (*)(vm_map_t, mach_vm_address_t, void *, vm_size_t);
using tVmMapWriteUser = kern_return_t (*)(vm_map_t, const void *, mach_vm_address_t, vm_size_t);
using tMachVmProtect = kern_return_t (*)(vm_map_t, mach_vm_address_t, mach_vm_size_t, boolean_t, vm_prot_t);
using tVmMapCheckProtection = boolean_t (*)(vm_map_t, vm_map_offset_t, vm_map_offset_t, vm_prot_t);
using tCsProcessEnforcement = boolean_t (*)(proc_t);

static tGetBsdTaskInfo gGetBsdTaskInfo {};
static tProcGetExecutableVnode gProcGetExecutableVnode {};
static tProcBestName gProcBestName {};
static tProcPid gProcPid {};
static tProcCsflags gProcCsflags {};
static tGetTaskMap gGetTaskMap {};
static tGetMapMin gGetMapMin {};
static tVmMapReadUser gVmMapReadUser {};
static tVmMapWriteUser gVmMapWriteUser {};
static tMachVmProtect gMachVmProtect {};
static tVmMapCheckProtection gVmMapCheckProtection {};
static tCsProcessEnforcement gCsProcessEnforcement {};

enum SiteClass : uint8_t {
	SiteCode,
	SitePath,
	SiteBoard,
	SiteClassCount
};

struct PatchSpec {
	const char *name;
	const uint8_t *find;
	uint16_t findLen;
	const uint8_t *repl;
	uint16_t replLen;
	uint16_t expected;
	SiteClass cls;
};

struct PatchSite {
	uint32_t imageOffset;
	uint16_t findLen;
	uint16_t replLen;
	SiteClass cls;
	uint8_t find[64];
	uint8_t repl[64];
};

struct FileCache {
	bool valid;
	bool hasRef;
	vnode_t vpRef;
	uint64_t fileId;
	uint64_t fileSize;
	uint32_t fsId;
	struct timespec mtime;
	uint8_t uuid[16];
	PatchSite sites[16];
	uint16_t siteCount;
	uint16_t expected[SiteClassCount];
	uint16_t ruleFailures;
	char detail[160];
};

struct FileStats {
	uint64_t fileId;
	uint64_t fileSize;
	uint32_t fsId;
	struct timespec mtime;
};

struct ThinInfo {
	uint32_t cputype;
	uint64_t textFileOff;
	uint64_t textFileSize;
	uint64_t textVmAddr;
	uint64_t headerVmAddr;
	uint8_t uuid[16];
	bool haveText;
	bool haveUuid;
	bool haveBase;
};

static constexpr size_t kHeaderMax = 64 * 1024;
static constexpr size_t kScanChunk = 64 * 1024;
static constexpr size_t kScanOverlap = 64;
static constexpr uint32_t kCpuTypeX86_64 = 0x01000007;
static constexpr size_t kMaxRuleHits = 32;

static uint8_t gHeaderBuf[kHeaderMax];
static uint8_t gImageHeaderBuf[kHeaderMax];
static uint8_t gScanBuf[kScanChunk + kScanOverlap];
static FileCache gFileCaches[2];

static uint32_t readBE32(const uint8_t *p) {
	return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
}

static uint32_t readLE32(const uint8_t *p) {
	return (uint32_t)p[3] << 24 | (uint32_t)p[2] << 16 | (uint32_t)p[1] << 8 | p[0];
}

static uint64_t readLE64(const uint8_t *p) {
	return (uint64_t)readLE32(p + 4) << 32 | readLE32(p);
}

static void setCowStatus(const char *fmt, ...) {
	char line[sizeof(gCowStatus)];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(line, sizeof(line), fmt, ap);
	va_end(ap);

	if (gCowStatusLock) IOSimpleLockLock(gCowStatusLock);
	strlcpy(gCowStatus, line, sizeof(gCowStatus));
	if (gCowStatusLock) IOSimpleLockUnlock(gCowStatusLock);
}

static int sysctlCow(struct sysctl_oid *, void *, int, struct sysctl_req *req) {
	char out[sizeof(gCowStatus)];
	if (gCowStatusLock) IOSimpleLockLock(gCowStatusLock);
	strlcpy(out, gCowStatus, sizeof(out));
	if (gCowStatusLock) IOSimpleLockUnlock(gCowStatusLock);
	return SYSCTL_OUT(req, out, strlen(out) + 1);
}
SYSCTL_PROC(_debug, OID_AUTO, btlefix_cow, CTLTYPE_STRING | CTLFLAG_RD | CTLFLAG_LOCKED, nullptr, 0, sysctlCow, "A",
            "BTLEFix private-page patch status");

static int vnodeStats(vnode_t vp, FileStats &st) {
	vnode_attr va;
	VATTR_INIT(&va);
	VATTR_WANTED(&va, va_data_size);
	VATTR_WANTED(&va, va_fileid);
	VATTR_WANTED(&va, va_fsid);
	VATTR_WANTED(&va, va_modify_time);

	vfs_context_t ctx = vfs_context_create(nullptr);
	if (!ctx) return ENOMEM;
	int err = vnode_getattr(vp, &va, ctx);
	vfs_context_rele(ctx);
	if (err) return err;

	st.fileSize = va.va_data_size;
	st.fileId = va.va_fileid;
	st.fsId = va.va_fsid;
	st.mtime = va.va_modify_time;
	return 0;
}

static int readVnode(vnode_t vp, off_t off, void *buf, size_t len, proc_t) {
	if (len > INT_MAX) return EINVAL;
	int resid = 0;
	int err = vn_rdwr(UIO_READ, vp, static_cast<caddr_t>(buf), (int)len, off, UIO_SYSSPACE, 0,
	                  kauth_cred_get(), &resid, current_proc());
	if (err) return err;
	return resid == 0 ? 0 : EIO;
}

static bool parseThin(const uint8_t *buf, size_t size, ThinInfo &info) {
	if (size < 32 || readLE32(buf) != MH_MAGIC_64) return false;
	info.cputype = readLE32(buf + 4);
	uint32_t ncmds = readLE32(buf + 16);
	uint32_t sizeofcmds = readLE32(buf + 20);
	if (ncmds == 0 || ncmds > 4096 || sizeofcmds > size - 32) return false;

	size_t off = 32;
	size_t end = 32 + sizeofcmds;
	for (uint32_t i = 0; i < ncmds; i++) {
		if (off + 8 > end) return false;
		uint32_t cmd = readLE32(buf + off);
		uint32_t cmdsize = readLE32(buf + off + 4);
		if (cmdsize < 8 || off + cmdsize > end) return false;

		if (cmd == LC_UUID && cmdsize >= 24) {
			memcpy(info.uuid, buf + off + 8, sizeof(info.uuid));
			info.haveUuid = true;
		} else if (cmd == LC_SEGMENT_64 && cmdsize >= 72) {
			const uint8_t *seg = buf + off;
			uint64_t vmaddr = readLE64(seg + 24);
			uint64_t fileoff = readLE64(seg + 40);
			uint64_t filesize = readLE64(seg + 48);
			if (strncmp(reinterpret_cast<const char *>(seg + 8), "__TEXT", 16) == 0) {
				info.textVmAddr = vmaddr;
				info.textFileOff = fileoff;
				info.textFileSize = filesize;
				info.haveText = true;
			}
			if (!info.haveBase && fileoff == 0 && filesize > 0) {
				info.headerVmAddr = vmaddr;
				info.haveBase = true;
			}
		}
		off += cmdsize;
	}

	if (!info.haveBase && info.haveText) {
		info.headerVmAddr = info.textVmAddr;
		info.haveBase = true;
	}
	return info.haveText && info.haveUuid && info.haveBase && info.textFileSize > 0 &&
	       info.textVmAddr >= info.headerVmAddr;
}

static bool parseFileLayout(vnode_t vp, const FileStats &st, proc_t proc, ThinInfo &info, char *detail,
                            size_t detailSize) {
	size_t headerSize = st.fileSize < kHeaderMax ? (size_t)st.fileSize : kHeaderMax;
	if (headerSize < 8 || readVnode(vp, 0, gHeaderBuf, headerSize, proc) != 0) {
		snprintf(detail, detailSize, "cannot read file header");
		return false;
	}

	uint64_t sliceOff = 0;
	uint64_t sliceSize = st.fileSize;
	if (readBE32(gHeaderBuf) == FAT_MAGIC) {
		uint32_t count = readBE32(gHeaderBuf + 4);
		if (count == 0 || count > 64 || 8 + (size_t)count * 20 > headerSize) {
			snprintf(detail, detailSize, "invalid FAT header");
			return false;
		}
		bool found = false;
		for (uint32_t i = 0; i < count; i++) {
			const uint8_t *arch = gHeaderBuf + 8 + (size_t)i * 20;
			uint32_t cputype = readBE32(arch);
			uint64_t off = readBE32(arch + 8);
			uint64_t size = readBE32(arch + 12);
			if (cputype == kCpuTypeX86_64 && size > 0 && off + size <= st.fileSize) {
				sliceOff = off;
				sliceSize = size;
				found = true;
				break;
			}
		}
		if (!found) {
			snprintf(detail, detailSize, "no x86_64 slice");
			return false;
		}
	} else if (readLE32(gHeaderBuf) != MH_MAGIC_64) {
		snprintf(detail, detailSize, "not a Mach-O file");
		return false;
	}

	size_t sliceHeaderSize = sliceSize < kHeaderMax ? (size_t)sliceSize : kHeaderMax;
	if (sliceHeaderSize < 32 || readVnode(vp, (off_t)sliceOff, gHeaderBuf, sliceHeaderSize, proc) != 0) {
		snprintf(detail, detailSize, "cannot read x86_64 slice header");
		return false;
	}
	if (!parseThin(gHeaderBuf, sliceHeaderSize, info) || info.cputype != kCpuTypeX86_64) {
		snprintf(detail, detailSize, "invalid x86_64 Mach-O header");
		return false;
	}
	if (info.textFileOff > sliceSize || info.textFileSize > sliceSize - info.textFileOff) {
		snprintf(detail, detailSize, "invalid __TEXT slice range");
		return false;
	}
	if (sliceOff > st.fileSize || info.textFileOff > st.fileSize - sliceOff ||
	    info.textFileSize > st.fileSize - sliceOff - info.textFileOff) {
		snprintf(detail, detailSize, "invalid __TEXT range");
		return false;
	}
	info.textFileOff += sliceOff;
	return true;
}

struct RuleHits {
	uint32_t offsets[kMaxRuleHits];
	size_t count;
	bool overflow;
};

static bool scanRules(vnode_t vp, const ThinInfo &info, const PatchSpec *rules, size_t ruleCount, proc_t proc,
                      RuleHits *hits, char *detail, size_t detailSize) {
	size_t maxFind = 1;
	for (size_t i = 0; i < ruleCount; i++)
		if (rules[i].findLen > maxFind) maxFind = rules[i].findLen;
	if (maxFind > kScanOverlap) {
		snprintf(detail, detailSize, "patch pattern too long");
		return false;
	}

	uint64_t done = 0;
	while (done < info.textFileSize) {
		size_t nominal = (size_t)((info.textFileSize - done) < kScanChunk ? info.textFileSize - done : kScanChunk);
		size_t readLen = nominal;
		if (readLen + maxFind - 1 < sizeof(gScanBuf)) readLen += maxFind - 1;
		if (info.textFileSize - done < readLen) readLen = (size_t)(info.textFileSize - done);
		if (readVnode(vp, (off_t)(info.textFileOff + done), gScanBuf, readLen, proc) != 0) {
			snprintf(detail, detailSize, "cannot read __TEXT");
			return false;
		}

		for (size_t r = 0; r < ruleCount; r++) {
			const PatchSpec &rule = rules[r];
			if (rule.expected == 0) continue;
			for (size_t i = 0; i < nominal && i + rule.findLen <= readLen; i++) {
				if (memcmp(gScanBuf + i, rule.find, rule.findLen) != 0) continue;
				if (hits[r].count >= kMaxRuleHits) {
					hits[r].overflow = true;
					continue;
				}
				uint64_t abs = info.textFileOff + done + i;
				if (abs < info.textFileOff) continue;
				uint64_t delta = info.textVmAddr - info.headerVmAddr;
				uint64_t rel = delta + (abs - info.textFileOff);
				if (rel > UINT32_MAX) {
					hits[r].overflow = true;
					continue;
				}
				hits[r].offsets[hits[r].count++] = (uint32_t)rel;
			}
		}
		done += nominal;
	}
	return true;
}

static void releaseFileCache(FileCache &cache) {
	if (cache.hasRef && cache.vpRef) vnode_rele(cache.vpRef);
	memset(&cache, 0, sizeof(cache));
}

static bool matchesCache(const FileCache &cache, vnode_t vp, const FileStats &st) {
	return cache.valid && cache.vpRef == vp && cache.fileId == st.fileId && cache.fileSize == st.fileSize &&
	       cache.fsId == st.fsId && cache.mtime.tv_sec == st.mtime.tv_sec &&
	       cache.mtime.tv_nsec == st.mtime.tv_nsec;
}

static size_t addSites(const PatchSpec *rules, size_t ruleCount, const RuleHits *hits, FileCache &cache,
                       char *detail, size_t detailSize) {
	size_t added = 0;
	for (size_t r = 0; r < ruleCount; r++) {
		const PatchSpec &rule = rules[r];
		if (rule.expected == 0) continue;
		cache.expected[rule.cls] += rule.expected;
		if (hits[r].overflow || hits[r].count != rule.expected) {
			cache.ruleFailures++;
			if (!detail[0])
				snprintf(detail, detailSize, "%s expected %u found %zu", rule.name, rule.expected, hits[r].count);
			continue;
		}
		for (size_t i = 0; i < hits[r].count; i++) {
			if (cache.siteCount >= arrsize(cache.sites) || rule.findLen > sizeof(PatchSite::find) ||
			    rule.replLen > sizeof(PatchSite::repl)) {
				cache.ruleFailures++;
				if (!detail[0]) snprintf(detail, detailSize, "%s site storage exhausted", rule.name);
				continue;
			}
			PatchSite &site = cache.sites[cache.siteCount++];
			site.imageOffset = hits[r].offsets[i];
			site.findLen = rule.findLen;
			site.replLen = rule.replLen;
			site.cls = rule.cls;
			memcpy(site.find, rule.find, rule.findLen);
			memcpy(site.repl, rule.repl, rule.replLen);
			added++;
		}
	}
	return added;
}

static bool buildFileCache(FileCache &cache, vnode_t vp, const FileStats &st, proc_t proc, bool bluetoothd,
                           char *detail, size_t detailSize) {
	releaseFileCache(cache);

	ThinInfo info {};
	if (!parseFileLayout(vp, st, proc, info, detail, detailSize)) return false;

	PatchSpec rules[8];
	size_t ruleCount = 0;
	if (bluetoothd) {
		rules[ruleCount++] = { "vendor", kVendorFind, sizeof(kVendorFind), kVendorRepl, sizeof(kVendorRepl), 1, SiteCode };
		rules[ruleCount++] = { "chipset", kChipsetFind, sizeof(kChipsetFind), kChipsetRepl, sizeof(kChipsetRepl), 3, SiteCode };
		rules[ruleCount++] = { "chipset15.4", kChipset154Find, sizeof(kChipset154Find), kChipset154Repl,
		                       sizeof(kChipset154Repl), 1, SiteCode };
		rules[ruleCount++] = { "le-v2", kLeFind26, sizeof(kLeFind26), kLeRepl26, sizeof(kLeRepl26), 1, SiteCode };
	} else {
		rules[ruleCount++] = { "BlueTool-path", kBlueToolPathFind, sizeof(kBlueToolPathFind), kBlueToolPathRepl,
		                       sizeof(kBlueToolPathRepl), 1, SitePath };
	}
	if (gPatchBoardId && gBoardIdLen)
		rules[ruleCount++] = { "board-id", kBoardIdFind, sizeof(kBoardIdFind), (const uint8_t *)gBoardId,
		                       gBoardIdLen, 1, SiteBoard };

	RuleHits hits[arrsize(rules)] {};
	if (!scanRules(vp, info, rules, ruleCount, proc, hits, detail, detailSize)) return false;

	memcpy(cache.uuid, info.uuid, sizeof(cache.uuid));
	cache.fileId = st.fileId;
	cache.fileSize = st.fileSize;
	cache.fsId = st.fsId;
	cache.mtime = st.mtime;
	addSites(rules, ruleCount, hits, cache, detail, detailSize);
	if (detail[0]) strlcpy(cache.detail, detail, sizeof(cache.detail));
	cache.valid = true;

	if (vnode_ref(vp) == 0) {
		cache.vpRef = vp;
		cache.hasRef = true;
	}
	return true;
}

static vm_prot_t pageProtection(vm_map_t map, mach_vm_address_t page) {
	vm_prot_t prot = VM_PROT_NONE;
	if (!gVmMapCheckProtection) return prot;
	if (gVmMapCheckProtection(map, page, page + PAGE_SIZE, VM_PROT_READ)) prot |= VM_PROT_READ;
	if (gVmMapCheckProtection(map, page, page + PAGE_SIZE, VM_PROT_WRITE)) prot |= VM_PROT_WRITE;
	if (gVmMapCheckProtection(map, page, page + PAGE_SIZE, VM_PROT_EXECUTE)) prot |= VM_PROT_EXECUTE;
	return prot;
}

enum PatchResult : int {
	PatchFailed = -1,
	PatchSkipped = 0,
	PatchApplied = 1,
	PatchAlready = 2
};

static PatchResult patchOne(vm_map_t map, mach_vm_address_t imageBase, const PatchSite &site, char *detail,
                            size_t detailSize) {
	mach_vm_address_t target = imageBase + site.imageOffset;
	if (target < imageBase) {
		snprintf(detail, detailSize, "address overflow");
		return PatchFailed;
	}
	mach_vm_address_t page = target & ~(mach_vm_address_t)(PAGE_SIZE - 1);
	if ((target & (PAGE_SIZE - 1)) + site.findLen > PAGE_SIZE) {
		snprintf(detail, detailSize, "patch crosses a page");
		return PatchFailed;
	}

	uint8_t current[64] {};
	kern_return_t kr = gVmMapReadUser(map, target, current, site.findLen);
	if (kr != KERN_SUCCESS) {
		snprintf(detail, detailSize, "read user memory failed 0x%x", kr);
		return PatchFailed;
	}
	if (memcmp(current, site.repl, site.replLen) == 0) return PatchAlready;
	if (memcmp(current, site.find, site.findLen) != 0) return PatchSkipped;

	vm_prot_t origProt = pageProtection(map, page);
	if (origProt == VM_PROT_NONE) origProt = VM_PROT_READ | VM_PROT_EXECUTE;
	vm_prot_t writeProt = (origProt & ~VM_PROT_EXECUTE) | VM_PROT_WRITE | VM_PROT_COPY;
	if ((writeProt & VM_PROT_READ) == 0) writeProt |= VM_PROT_READ;

	kr = gMachVmProtect(map, page, PAGE_SIZE, FALSE, writeProt);
	if (kr != KERN_SUCCESS) {
		snprintf(detail, detailSize, "COW protect failed 0x%x", kr);
		return PatchFailed;
	}
	kr = gVmMapWriteUser(map, site.repl, target, site.replLen);
	if (kr != KERN_SUCCESS) {
		gMachVmProtect(map, page, PAGE_SIZE, FALSE, origProt);
		snprintf(detail, detailSize, "write user memory failed 0x%x", kr);
		return PatchFailed;
	}

	uint8_t verify[64] {};
	kr = gVmMapReadUser(map, target, verify, site.replLen);
	bool verifyOk = kr == KERN_SUCCESS && memcmp(verify, site.repl, site.replLen) == 0;
	kern_return_t restore = gMachVmProtect(map, page, PAGE_SIZE, FALSE, origProt);
	if (!verifyOk) {
		snprintf(detail, detailSize, "read-back failed");
		return PatchFailed;
	}
	if (restore != KERN_SUCCESS) {
		snprintf(detail, detailSize, "protection restore failed 0x%x", restore);
		return PatchFailed;
	}
	return PatchApplied;
}

enum CandidateProcess : uint8_t {
	CandidateNone,
	CandidateBluetoothd,
	CandidateBlueTool
};

static CandidateProcess candidateProcess(const char *name) {
	if (!name) return CandidateNone;
	if (strcmp(name, "bluetoothd") == 0) return CandidateBluetoothd;
	if (strcmp(name, "BlueTool") == 0) return CandidateBlueTool;
	return CandidateNone;
}

static vnode_t lookupExecutable(const char *path, int *error) {
	vnode_t vp = NULLVP;
	vfs_context_t ctx = vfs_context_create(nullptr);
	if (!ctx) {
		*error = ENOMEM;
		return NULLVP;
	}
	*error = vnode_lookup(path, 0, &vp, ctx);
	vfs_context_rele(ctx);
	return vp;
}

static void patchedTaskSetMainThreadQos(task_t task, thread_t mainThread) {
	FunctionCast(patchedTaskSetMainThreadQos, orgTaskSetMainThreadQos)(task, mainThread);

	if (!gCowEnabled || !gCowReady || !gCowLock || !gGetBsdTaskInfo || !gProcGetExecutableVnode)
		return;

	proc_t proc = gGetBsdTaskInfo(task);
	if (!proc) return;
	CandidateProcess candidate = candidateProcess(gProcBestName(proc));
	if (candidate == CandidateNone) return;

	int pid = gProcPid(proc);
	IOLockLock(gCowLock);

	vnode_t vp = gProcGetExecutableVnode(proc);
	const char *expectedPath =
	    candidate == CandidateBluetoothd ? "/usr/sbin/bluetoothd" : "/usr/sbin/BlueTool";
	const char *exe = candidate == CandidateBluetoothd ? "bluetoothd" : "BlueTool";
	bool fallback = false;
	char path[PATH_MAX];
	int pathLen = PATH_MAX;
	if (vp) {
		if (vn_getpath(vp, path, &pathLen) != 0 || strcmp(path, expectedPath) != 0) {
			vnode_put(vp);
			vp = NULLVP;
		}
	}
	if (!vp) {
		int lookupErr = 0;
		vp = lookupExecutable(expectedPath, &lookupErr);
		fallback = true;
		if (!vp) {
			setCowStatus("%s pid %d: cannot open %s (%d)", exe, pid, expectedPath, lookupErr);
			blog("cow: %s pid %d: cannot open %s (%d)", exe, pid, expectedPath, lookupErr);
			IOLockUnlock(gCowLock);
			return;
		}
		pathLen = PATH_MAX;
		if (vn_getpath(vp, path, &pathLen) != 0 || strcmp(path, expectedPath) != 0) {
			setCowStatus("%s pid %d: executable path changed", exe, pid);
			blog("cow: %s pid %d: executable path changed", exe, pid);
			vnode_put(vp);
			IOLockUnlock(gCowLock);
			return;
		}
	}
	bool bluetoothd = candidate == CandidateBluetoothd;
	if (fallback) blog("cow: %s pid %d: used vnode_lookup fallback", exe, pid);

	FileStats st {};
	int statErr = vnodeStats(vp, st);
	if (statErr) {
		setCowStatus("%s pid %d: stat failed %d", exe, pid, statErr);
		blog("cow: %s pid %d: stat failed %d", exe, pid, statErr);
		vnode_put(vp);
		IOLockUnlock(gCowLock);
		return;
	}

	FileCache &cache = gFileCaches[bluetoothd ? 0 : 1];
	bool rebuilt = false;
	if (!matchesCache(cache, vp, st)) {
		char detail[sizeof(cache.detail)] {};
		rebuilt = true;
		if (!buildFileCache(cache, vp, st, proc, bluetoothd, detail, sizeof(detail))) {
			setCowStatus("%s pid %d: scan failed: %s", exe, pid, detail[0] ? detail : "unknown");
			blog("cow: %s pid %d: scan failed: %s", exe, pid, detail[0] ? detail : "unknown");
			vnode_put(vp);
			IOLockUnlock(gCowLock);
			return;
		}
	}
	if (rebuilt) blog("cow: %s scan: %u sites, %u rule misses", exe, cache.siteCount, cache.ruleFailures);

	if (cache.ruleFailures) {
		blog("cow: %s pid %d: pattern mismatch, patching valid sites: %s", exe, pid,
		     cache.detail[0] ? cache.detail : "unknown");
	}

	vm_map_t map = gGetTaskMap(task);
	if (!map) {
		setCowStatus("%s pid %d: no task map", exe, pid);
		blog("cow: %s pid %d: no task map", exe, pid);
		vnode_put(vp);
		IOLockUnlock(gCowLock);
		return;
	}
	mach_vm_address_t imageBase = gGetMapMin(map);
	size_t imageHeaderSize = kHeaderMax;
	kern_return_t kr = gVmMapReadUser(map, imageBase, gImageHeaderBuf, imageHeaderSize);
	ThinInfo imageInfo {};
	if (kr != KERN_SUCCESS || !parseThin(gImageHeaderBuf, imageHeaderSize, imageInfo) ||
	    imageInfo.cputype != kCpuTypeX86_64) {
		setCowStatus("%s pid %d: image header unreadable (0x%x)", exe, pid, kr);
		blog("cow: %s pid %d: image header unreadable (0x%x)", exe, pid, kr);
		vnode_put(vp);
		IOLockUnlock(gCowLock);
		return;
	}
	if (memcmp(cache.uuid, imageInfo.uuid, sizeof(cache.uuid)) != 0) {
		setCowStatus("%s pid %d: UUID mismatch (file/image)", exe, pid);
		blog("cow: %s pid %d: UUID mismatch (file/image)", exe, pid);
		vnode_put(vp);
		IOLockUnlock(gCowLock);
		return;
	}

	uint64_t csflags = 0;
	int csErr = gProcCsflags ? gProcCsflags(proc, &csflags) : -1;
	if (gCsProcessEnforcement && gCsProcessEnforcement(proc)) {
		setCowStatus("%s pid %d: blocked by code-signing enforcement, csflags 0x%llx", exe, pid,
		             (unsigned long long)csflags);
		blog("cow: %s pid %d: blocked by code-signing enforcement, csflags 0x%llx", exe, pid,
		     (unsigned long long)csflags);
		vnode_put(vp);
		IOLockUnlock(gCowLock);
		return;
	}

	uint16_t applied[SiteClassCount] {};
	uint16_t already[SiteClassCount] {};
	uint16_t skipped[SiteClassCount] {};
	uint16_t failed[SiteClassCount] {};
	char firstError[96] {};

	for (uint16_t i = 0; i < cache.siteCount; i++) {
		const PatchSite &site = cache.sites[i];
		char err[64] {};
		PatchResult result = patchOne(map, imageBase, site, err, sizeof(err));
		if (result == PatchApplied) applied[site.cls]++;
		else if (result == PatchAlready) already[site.cls]++;
		else if (result == PatchSkipped) skipped[site.cls]++;
		else {
			failed[site.cls]++;
			if (!firstError[0]) snprintf(firstError, sizeof(firstError), "%s", err);
		}
	}

	unsigned skippedTotal = 0, failedTotal = 0;
	for (size_t i = 0; i < SiteClassCount; i++) {
		skippedTotal += skipped[i];
		failedTotal += failed[i];
	}

	if (bluetoothd) {
		setCowStatus("%s pid %d: code %u/%u patched, board %u/%u, %u skipped, %u already, %u failed%s%s, uuid ok, "
		             "csflags 0x%llx%s, rule misses %u",
		             exe, pid, applied[SiteCode], cache.expected[SiteCode], applied[SiteBoard],
		             cache.expected[SiteBoard], skippedTotal, (unsigned)(already[SiteCode] + already[SiteBoard]),
		             failedTotal, firstError[0] ? ": " : "", firstError, (unsigned long long)csflags,
		             csErr ? " (unreadable)" : "", cache.ruleFailures);
	} else {
		setCowStatus("%s pid %d: path %u/%u patched, board %u/%u, %u skipped, %u already, %u failed%s%s, uuid ok, "
		             "csflags 0x%llx%s, rule misses %u",
		             exe, pid, applied[SitePath], cache.expected[SitePath], applied[SiteBoard],
		             cache.expected[SiteBoard], skippedTotal, (unsigned)(already[SitePath] + already[SiteBoard]),
		             failedTotal, firstError[0] ? ": " : "", firstError, (unsigned long long)csflags,
		             csErr ? " (unreadable)" : "", cache.ruleFailures);
	}
	blog("cow: %s", gCowStatus);

	vnode_put(vp);
	IOLockUnlock(gCowLock);
}


// ---- 5. AppleHDA resource requests ----
static mach_vm_address_t orgRequestResource {};
static const char *kHdaDirs[] {
	"/Library/Apple/System/Library/Extensions/AppleHDA.kext/Contents/Resources/",
	"/Library/Extensions/AppleHDA.kext/Contents/Resources/",
};

static bool hdaResourceNameOk(const char *n) {
	if (!n || !n[0] || strlen(n) > 40) return false;
	for (const char *c = n; *c; c++) {
		if (*c == '/' || *c == '\\' || (*c == '.' && c[1] == '.')) return false;
	}
	return strncmp(n, "layout", 6) == 0 || strncmp(n, "Platforms", 9) == 0;
}

static OSReturn patchedRequestResource(const char *kextId, const char *name, OSKextRequestResourceCallback cb, void *ctx,
                                       OSKextRequestTag *tagOut) {
	if (kextId && cb && strcmp(kextId, "com.apple.driver.AppleHDA") == 0 && hdaResourceNameOk(name)) {
		uint8_t *buf = nullptr;
		size_t size = 0;
		char path[256];
		for (size_t i = 0; i < arrsize(kHdaDirs) && !buf; i++) {
			snprintf(path, sizeof(path), "%s%s", kHdaDirs[i], name);
			buf = FileIO::readFileToBuffer(path, size);
		}
		blog("AppleHDA resource %s: %s (%lu bytes)", name, buf ? "served from the bundle" : "not found", (unsigned long)size);
		if (tagOut) *tagOut = kOSKextRequestTagInvalid;
		if (buf) cb(kOSKextRequestTagInvalid, kOSReturnSuccess, buf, (uint32_t)size, ctx);
		else cb(kOSKextRequestTagInvalid, kOSKextReturnNotFound, nullptr, 0, ctx);
		if (buf) Buffer::deleter(buf);
		return kOSReturnSuccess;
	}
	return FunctionCast(patchedRequestResource, orgRequestResource)(kextId, name, cb, ctx, tagOut);
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
	gCowStatusLock = IOSimpleLockAlloc();
	gCowLock = IOLockAlloc();
	sysctl_register_oid(&sysctl__debug_btlefix_log);
	sysctl_register_oid(&sysctl__debug_btlefix_page_delay_ms);
	sysctl_register_oid(&sysctl__debug_btlefix_cow);
	blog("start");

	if (getKernelVersion() < KernelVersion::Tahoe) {
		gCowEnabled = false;
		setCowStatus("disabled: private-page patches require macOS 26");
		blog("cow: disabled on this kernel version");
	}
	int cowArg = 1;
	if (lilu_get_boot_args("btlefix_cow", &cowArg, sizeof(cowArg)) && cowArg == 0) {
		gCowEnabled = false;
		setCowStatus("disabled by btlefix_cow=0");
		blog("cow: disabled by btlefix_cow=0");
	}
	if (!gCowLock) {
		gCowEnabled = false;
		setCowStatus("disabled: cannot allocate patch lock");
		blog("cow: cannot allocate patch lock");
	}

	lilu.onPatcherLoadForce([](void *, KernelPatcher &patcher) {
		if (checkKernelArgument("-btlfxboardid")) {
			const char *board = BaseDeviceInfo::get().boardIdentifier;
			if (board && strlen(board) + 1 == sizeof(kBoardIdFind)) {
				strlcpy(gBoardId, board, sizeof(gBoardId));
				gBoardIdLen = (uint16_t)(strlen(gBoardId) + 1);
				gPatchBoardId = true;
				blog("cow: board-id patch %s", gBoardId);
			} else {
				blog("cow: board-id patch disabled, board id '%s' is not 20 bytes", board ? board : "");
			}
		}

		if (gCowEnabled) {
			bool symbolsOk = true;
			auto resolve = [&](const char *name) -> mach_vm_address_t {
				mach_vm_address_t addr = patcher.solveSymbol(KernelPatcher::KernelID, name);
				if (!addr) {
					blog("cow: missing kernel symbol %s", name);
					symbolsOk = false;
				}
				patcher.clearError();
				return addr;
			};

			gGetBsdTaskInfo = reinterpret_cast<tGetBsdTaskInfo>(resolve("_get_bsdtask_info"));
			gProcGetExecutableVnode =
			    reinterpret_cast<tProcGetExecutableVnode>(resolve("_proc_getexecutablevnode"));
			gProcBestName = reinterpret_cast<tProcBestName>(resolve("_proc_best_name"));
			gProcPid = reinterpret_cast<tProcPid>(resolve("_proc_pid"));
			gProcCsflags = reinterpret_cast<tProcCsflags>(resolve("_proc_csflags"));
			gGetTaskMap = reinterpret_cast<tGetTaskMap>(resolve("_get_task_map"));
			gGetMapMin = reinterpret_cast<tGetMapMin>(resolve("_get_map_min"));
			gVmMapReadUser = reinterpret_cast<tVmMapReadUser>(resolve("_vm_map_read_user"));
			gVmMapWriteUser = reinterpret_cast<tVmMapWriteUser>(resolve("_vm_map_write_user"));
			gMachVmProtect = reinterpret_cast<tMachVmProtect>(resolve("_mach_vm_protect"));
			gVmMapCheckProtection =
			    reinterpret_cast<tVmMapCheckProtection>(resolve("_vm_map_check_protection"));
			gCsProcessEnforcement =
			    reinterpret_cast<tCsProcessEnforcement>(resolve("_cs_process_enforcement"));

			if (symbolsOk) {
				KernelPatcher::RouteRequest qos("_task_set_main_thread_qos", patchedTaskSetMainThreadQos,
				                                orgTaskSetMainThreadQos);
				if (patcher.routeMultipleLong(KernelPatcher::KernelID, &qos, 1)) {
					gCowReady = true;
					blog("cow: hooked task_set_main_thread_qos");
				} else {
					setCowStatus("disabled: cannot hook task_set_main_thread_qos");
					blog("cow: cannot hook task_set_main_thread_qos");
				}
			} else {
				setCowStatus("disabled: required kernel symbols are missing");
			}
		}
		patcher.clearError();

		KernelPatcher::RouteRequest rr("__ZN6OSKext15requestResourceEPKcS1_PFvjiPKvjPvES4_Pj", patchedRequestResource, orgRequestResource);
		if (!patcher.routeMultipleLong(KernelPatcher::KernelID, &rr, 1))
			blog("failed to route OSKext::requestResource");
		else
			blog("routed OSKext::requestResource");
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
	KernelVersion::Tahoe,   // macOS 26 (in use on 26.7.1)
	pluginStart
};
