# NVIDIA RTX 4060 Laptop (Ada) on macOS — patches & fixes

[简体中文](README.md)

A collection of patches, byte-patch scripts and root-cause write-ups for running the
[NullMoth NVIDIA driver](https://github.com/nullmoth/nvidia-macos-driver) (the author now runs v1.15.0 kexts and user space) on a **Hackintosh (OpenCore) with macOS 15.8.1 — now upgraded to macOS 26.7.1 —
and an RTX 4060 Laptop dGPU** (Clevo chassis, i7-13620H, BOE 0B40 2560×1440@165 Hz panel, Intel AX211, ELAN0420 I²C touchpad, ALC256 audio).

**Not included:** any NullMoth/NVIDIA binary or firmware, your EFI / `config.plist`, ACPI dumps. Get the driver from upstream.
What *is* included: source diffs against upstream v1.9.0, v1.13.0, v1.14.2 and v1.15.0, the macOS 26 upgrade kit (`tahoe/`), assertion-based binary patch scripts, kext/Lilu sources, install/rollback
scripts, regression test programs, and the analysis behind each fix.

> ⚠️ This modifies kernel extensions, system GPU plugins, OpenCore config and ACPI. Back up your EFI and keep a bootable fallback.
> Provided as is, no warranty. Machine-specific values (ESP device/UUID, panel IDs, binary hashes/offsets) must be adapted — scripts that
> touch the ESP refuse to run unless `ESP_UUID` (the partition UUID of your OpenCore ESP) is exported; they look the disk up by that UUID every time, because disk numbers move between boots (seen on macOS 26). See [docs/applying.md](docs/applying.md) (Chinese).

## Versions and applicability

**The author's machine now:** macOS **26.7.1** (upgraded from 15.8.1, SMBIOS still iMacPro1,1) + NullMoth **v1.15.0** kexts and user space + this repo's 1.15.0 patch set.
The older combination (v1.9.0 kexts + v1.9.0 / v1.13.0 / v1.14.2 user-space patches on macOS 15) is kept in its directories.

| Layer | Which version | Notes |
|---|---|---|
| Plugin NVMTLDriver, translator | `patches/nullmoth-1.15.0/0001`, `0002` (recommended); older `nullmoth-1.14.2/`, `nullmoth-1.13.0/`, `nullmoth-1.9.0/0001`, `0002` | Pick one set, do not stack. Fixes 26–29 are in 1.14.2 and later; the VideoToolbox fix to 29 and fix 30 only in 1.15.0 |
| Kexts NVRM/NVAccel/NVRMFB | **1.15.0**: NVRM via `kexts/patch-nvrm-115.py`, NVRMFB via `patches/nullmoth-1.15.0/0003`, stock NVAccel/NVRMAGDC; old 1.9.0 baseline: `patches/nullmoth-1.9.0/0003–0006` | 1.15.0 ships its own backlight and cursor-only commits (NVRMFB part of 17, 21); binary patches assert every byte |
| NVK (`libvulkan_nouveau`) | Stock 1.15.0, no patches needed; 1.9.0: `codec-vulkan/vulkan/` | NVK parts of 5 and 27 are upstream now |
| NVDEC / NVENC byte patches | Against 1.9.0 binaries (the author still uses these patched builds with 1.15.0) | Scripts assert the expected bytes and refuse to write on mismatch |
| macOS 26 | `tahoe/` | Upgrade, rescue, audio, AC power: fixes 32–34 |

**Pick fixes for your machine** (numbers refer to the table below):

| Your situation | Applicable fixes |
|---|---|
| Any NullMoth-supported NVIDIA GPU on macOS 15 / 26 (user space, hardware independent) | 3, 4, 6, 7, 8, 9, 10, 11, 12, 13, 16, 22, 23, 25, 26 (plugin part), 27, 28, 29, 30 |
| macOS issues unrelated to the driver | 20 (CrossOver/Wine), 31 (WeType input method) |
| Needs a specific NullMoth build (byte patches / offsets are version bound) | 2, 5 (NVK part), 14, 15, 27 (NVK part) |
| Ada (RTX 40) only: NVDEC/NVENC t2d layout | 14, 15 |
| Depends on your panel and mainboard | 1 (HiDPI: panel ID, refresh rate), 17 (brightness: `_DSM`/`_DOD` paths in your DSDT) |
| Same hardware only | 18 (Intel AX211), 19 (ELAN0420 I²C touchpad), 24 (ALC256 codec; the layout depends on the machine) |
| Upgrading to macOS 26 | 32 (dropped models like iMacPro1,1 + a patched driver), 33 (codecs that need AppleHDA), 34 (DSDT `_PSR` relying on Windows-only methods) |
| Kext, higher risk | 21 (cursor-only commits, preventive; built into 1.15.0), NVRMFB part of 26 (no CPU clear of fresh VRAM) |

Suggested order: user-space first (plugin, translator) and live with it; then byte patches as needed; kexts last; read fix 32 before upgrading to macOS 26. Do not copy the machine-specific items (1, 17, 18, 19, 33, 34) blindly.

## Fixes

| # | Symptom | Root cause | Fix |
|---|---------|-----------|-----|
| 1 | No HiDPI / can't reach 165 Hz | NVKMS hides window scaling on dGPUs; IMP accepts ≤1.4× downscale at 165 Hz | 26-byte NVRM head-scaler patch + display override → 1792×1008 HiDPI @165 Hz |
| 2 | Dock stops presenting after login | Zero-copy flip hot-switched 60 s after boot | NVRM `IOSleep(60000)→0` |
| 3 | Black blocks / ghost text / square window corners | WindowServer layer-cache renders into *linear* shared IOSurface VRAM come out wrong; stale-upload races | `NVMTL_SURF_SHARE_MINPX` private tiled images + consistency patches; after the later fixes the author is back on `MINPX=0` (all shared VRAM) with no black blocks |
| 4 | WindowServer 75–90 % CPU | Sync CPU copy + fence wait per IOSurface change | Async surface-in (GPU reading the surface pages directly is off by default: it races Chrome) |
| 5 | Chrome falls back to software compositing | ANGLE `disableMetalOnNvidia`; GPU sandbox denies `/dev/null` write & `hw.pagesize` | env override + 2-byte NVK patch + `hw.memsize` rewrite (stock 1.15.0 NVK needs neither) |
| 6 | Chrome/Electron flicker | `waitUntilScheduled` / scheduled handlers fire before GPU completion | Scheduled handlers run at completion (the `waitUntilScheduled` wait turned out unnecessary and is off on the author's machine, see 26) |
| 7 | Occasional blank Chrome window | WebGL shader translate fails (`get_num_samples`) → GPU process restart | Spec-constant sample count (translator + plugin) |
| 8 | Green video previews, diagonal tearing | Plugin never held IOSurface use counts | Hold/release use count per command buffer |
| 9 | Graphite missing geometry | Translator dropped all vertex outputs when the return type was a freshly minted struct | Fall back to `type_def_of` |
| 10 | Slow Chrome scrolling | ~1 ms per pass into linear window RT | Tiled render shadow (13.6 → 3.2 ms/frame) |
| 11 | WindowServer misses 165 Hz frame budget | Self-bind guard copies the 28 MB framebuffer before each sampling draw | End pass→barrier→restart→sample self, no copy |
| 12 | Steam/CEF UI flicker | Apple GL-on-Metal MSAA pass with all-zero sample positions was rejected | Fall back to the standard sample pattern (upstream's equivalent fallback in the 1.14.2 set) |
| 13 | Flat-colour tiles in Core Image Lanczos (screenshot previews) | Translator emitted pointer-taking helpers before their callers, losing a constant offset | Callers-first topological reorder (replaced by upstream's equivalent fix in the 1.14.2 set) |
| 14 | 16-px stripes in H.264 decode; H.264 hardware decode slow / CPU heavy | NVDEC detile mode 1 (Blackwell) vs Ada t2d GOB; since 1.13 the plugin loads `libnvdec_h264_t2d.dylib`, which was never installed; byte-per-iteration detile and a spinning wait | 1-byte patch; install under the t2d name; 8-byte detile (4K 26.8 → 12.6 ms/frame) + sleeping wait (CPU 4K 8.0 → 3.7 ms/frame) |
| 15 | UU Remote host: stuck / garbled / slow | NVENC NotSync flag, bw8/bw16 vs t2d layout, slow BAR zeroing, no rate control | H.264 binary patches |
| 16 | UU Remote as controller crashes | Viewport depth outside [0,1] → NVK assert | Clamp znear/zfar |
| 17 | No brightness slider / Fn keys / battery | `_DSM`/`_DOD` stubbed in NVRM; EC0 hidden by OC SSDT | NVDSM (Lilu) + NVRMFB built-in panel (upstream in 1.15.0; NVDSM then leaves the backlight registration to NVRM) + enable real EC0 |
| 18 | Wi-Fi / Bluetooth (AX211) | No Sequoia AirportItlwm; bluetoothd LE quirks; some boots Wi-Fi never came up (firmware ALIVE delayed by IO80211 parking ioctls in the shared gate, no retry) | AirportItlwm-Sequoia + init-recovery patch (15 s ALIVE budget, 3 attempts, watchdog re-init — `patches/itlwm/`), BTLEFix (Lilu); on macOS 26 the AirportItlwm Tahoe build and BTLEFix 1.0.6 (26 bluetoothd pattern) |
| 19 | Touchpad dead | VoodooI2C missing ADL-P PCI ID; VoodooGPIO TigerLakeLP class not built / wrong start chain | 3 patches + PS2 key SSDT |
| 20 | CrossOver/Wine killed by `EXC_GUARD` | `amfi_get_out_of_my_way` makes every process "platform" → immovable task port | boot-arg `ipc_control_port_options=0` |
| 21 | Rare flash of a stale frame on mouse movement (preventive, not reproduced locally) | NVRMFB cursor commits re-submitted the primary surface, racing the zero-copy flip | Cursor-only commits (ported from upstream 1.13.0; 1.15.0 NVRMFB has it built in) |
| 22 | Memoji / SceneKit character meshes shatter | SceneKit skinning kernels use compute `stage_in`, which the plugin did not implement | Compute stage_in via an MSL gather kernel (8/16/32-bit formats, BGRA, constant step) — `patches/nullmoth-1.13.0/per-fix/compute-stage-in.patch` |
| 23 | Photo Booth preview black (photos fine); compute / Core Image writes into a CAMetalLayer vanish | A `framebufferOnly=NO` drawable has usage `Unknown(0)`: Apple drivers read it as "all usages", the plugin read "none" → ShaderWrite refused | Read 0 as ShaderRead, ShaderWrite, RenderTarget (`NVMTL_UNKNOWN_USAGE=0` turns it off) — `per-fix/unknown-usage-all.patch`, `hidpi/catest/drawable-writes.swift` |
| 24 | No built-in microphone / speakers | AppleALC missing; codec is a Realtek ALC256 (subsystem `1558:25E1`) | AppleALC + `alcid=11`, script edits the ESP `config.plist` — `audio/` (macOS 26 also needs fix 33) |
| 25 | Claude desktop Terminal pane shows no text (xterm.js WebGL); WebGL pages with `sampler2D u[N]` arrays draw nothing | **Translator** had no sampler-array lowering and kept only element 0 of texture arrays; **plugin** descriptor-slot mask marked only the first slot of an array | Translator lowers the arrays to descriptor arrays and resolves element pointers; plugin marks all `count` slots. ⚠ every dylib put in GPUBundles must be ad-hoc signed or WindowServer's library validation rejects it → crash loop — `patches/nullmoth-1.13.0/per-fix/sampler-array-{plugin,translator}.patch`, `hidpi/catest/sarray.m`, `hidpi/tests/lv-test.sh` |
| 26 | Bilibili 4K video with heavy danmaku drops frames (worse with smart-mask danmaku) | New 12 MB staging buffer per video frame; `waitUntilScheduled` waited for GPU completion; submission blocked behind the previous frame's publish; a new IOSurface per frame (import + CPU clear of fresh VRAM) | Staging reuse, return on submit, eager submit-ahead, render-shadow park, NVRMFB skips the clear when the grant samples zero (200 danmaku 86–92 → 165 fps, video drops 15% → 0). Smart mask halving WindowServer's on-screen rate is Chrome's design, see docs — `patches/nullmoth-1.14.2/per-fix/`, `patches/nullmoth-{1.9.0/0006,1.15.0/0003}`, `hidpi/catest/danmaku/` |
| 27 | Firefox has no hardware acceleration | Firefox's GPU sandbox denies even reading `/dev/null`, and `hw.pagesize` | Backport of upstream 1.14.5/1.14.6: a pipe as the placeholder fd, memory size via `host_info`; NVK drops our `hw.memsize` rewrite (swap both together) — `per-fix/upstream-sandbox-unity-backport.patch`, `codec-vulkan/vulkan/mk-nomem-190.py` |
| 28 | Unity-style apps hang | The app commits and waits inside `@synchronized(commandBuffer/queue)`; the plugin took the same lock on completion | Backport of upstream 1.14.5: the plugin uses its own class locks — `hidpi/catest/unitylock.m` |
| 29 | WebGL with many draws (Aquarium) is slow | A new descriptor set per draw; release builds still evaluated trace arguments; texture-sampling fragment shaders read buffers through descriptors | Reuse the descriptor set when only the bytes ring moved (dynamic-offset address table); lazy trace arguments; **translator** merges the remaining buffers onto the address table (3.13 → 1.56 µs/draw, 5000 fish 41 → 73 fps). The reuse once left VideoToolbox two-pass scaling blank (Photos/Preview thumbnails); fixed in the 1.15.0 set — `per-fix/{nvtrace-release,descriptor-table-reuse,translator-table-merge}.patch`, `nullmoth-1.15.0/per-fix/vt-storage-descriptor-reuse.patch` |
| 30 | Dock badge numbers only visible while the Dock is magnified | Core Animation creates mipmapped textures with `newTiledTextureWithBytesNoCopy`; the buffer holds level 0 only and the driver must build the rest — the plugin left levels 1+ empty | Generate the mip chain after the upload and after every re-upload — `patches/nullmoth-1.15.0/per-fix/tiled-mips.patch`, `hidpi/catest/tiledmips.m` |
| 31 | WeType (WeChat input method) dead after boot in apps started at login | Those apps ask `imklaunchagent` for the input method's endpoint before WeType has registered and cache "no endpoint" | LaunchAgent starts WeType at login with `open -g` (not `-j`: hidden launch has no candidate window) — `tools/wetype/` |
| 32 | Upgrading to macOS 26 with a dropped model, a patched driver, and a way back | 26 refuses iMacPro1,1; the installer must run without the driver; NullMoth needs its macOS 26 NVAccel; disk numbers move between boots | Keep iMacPro1,1 + RestrictEvents + `-no_compat_check revpatch=sbvmm`; park the driver before updating, the first 26 boot swaps NVAccel and rebuilds the kernel collection; rescue config on the ESP + a Limine recovery entry; scripts find the ESP by partition UUID — `tahoe/` |
| 33 | No built-in speakers/microphone on macOS 26 | 26 removed AppleHDA; once put back, `kernelmanagerd` never answers its resource requests and the driver waits for ever | AppleHDA from the 15.7.9 KDK in `/Library/Apple/System/Library/Extensions` + `kmutil -b`; BTLEFix 1.0.6 answers `OSKextRequestResource` — `tahoe/audio/` |
| 34 | macOS 26 says battery power while plugged in; FileVault conversion stays paused | DSDT `AC._PSR` calls Windows-only methods and fails under macOS; APFS pauses conversion on battery | `SSDT-ACPSR` with its own `_PSR` (returns `ACFG`) + ACPI rename `_PSR → XPSR` — `tahoe/power/` |

Details (Chinese): [docs/fixes.md](docs/fixes.md) · Pitfalls: [docs/pitfalls.md](docs/pitfalls.md).

Guards: `nvguard/` keeps the driver files patched after a NullMoth reinstall; `efiguard/` keeps the fixes that live on the OpenCore ESP (kexts, `alcid`, boot-args incl. the macOS 26 ones), finds the ESP by partition UUID, stays out while the rescue config is active, and can be rehearsed on a copy of the ESP. A Photo Booth preview that is *upside down* while FaceTime/QuickTime are fine is not a driver bug — see docs/fixes.md ("excluded" section).

## Licensing

Patches to NullMoth plugin/kexts: PolyForm Noncommercial 1.0.0 (non-commercial use only). Translator patches: LGPL-3.0-or-later.
Lilu plugins and everything else the author wrote: GPL-3.0 (see [LICENSE](LICENSE)). Patch files keep the license of the upstream project they modify. See [NOTICE.md](NOTICE.md). Not affiliated with NullMoth Systems, NVIDIA or Apple.
