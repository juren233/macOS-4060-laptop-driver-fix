# NVIDIA RTX 4060 Laptop (Ada) on macOS — patches & fixes

[简体中文](README.md)

A collection of patches, byte-patch scripts and root-cause write-ups for running the
[NullMoth NVIDIA driver](https://github.com/nullmoth/nvidia-macos-driver) (v1.9.0) on a **Hackintosh (OpenCore) with macOS 15.8.1
and an RTX 4060 Laptop dGPU** (Clevo chassis, i7-13620H, BOE 0B40 2560×1440@165 Hz panel, Intel AX211, ELAN0420 I²C touchpad, ALC256 audio).

**Not included:** any NullMoth/NVIDIA binary or firmware, your EFI / `config.plist`, ACPI dumps. Get the driver from upstream.
What *is* included: source diffs against upstream v1.9.0 and v1.13.0, assertion-based binary patch scripts, kext/Lilu sources, install/rollback
scripts, regression test programs, and the analysis behind each fix.

> ⚠️ This modifies kernel extensions, system GPU plugins, OpenCore config and ACPI. Back up your EFI and keep a bootable fallback.
> Provided as is, no warranty. Machine-specific values (ESP device/UUID, panel IDs, binary hashes/offsets) must be adapted — scripts that
> touch the ESP refuse to run unless `ESP_DEV` and `ESP_UUID` are exported. See [docs/applying.md](docs/applying.md) (Chinese).

## Versions and applicability

**Tested combination:** NullMoth **v1.9.0** kexts and binaries + this repo's patches; for the plugin and translator you can use either the v1.9.0 or the v1.13.0 patch set (the author runs the latter).

| Layer | Which version | Notes |
|---|---|---|
| Plugin NVMTLDriver, translator | `patches/nullmoth-1.13.0/` (recommended) or `patches/nullmoth-1.9.0/0001`, `0002` | Pick one set, do not stack. The 1.13.0 set drops what upstream absorbed |
| Kexts NVRM/NVAccel/NVRMFB | **1.9.0** baseline (`patches/nullmoth-1.9.0/0003–0005`) | NVRM core source is unchanged 1.9.0→1.13.0, but binary-patch offsets must still be checked against your own package |
| NVK / NVDEC / NVENC byte patches | Against 1.9.0 binaries | Scripts assert the expected bytes and refuse to write on mismatch |

**Pick fixes for your machine** (numbers refer to the table below):

| Your situation | Applicable fixes |
|---|---|
| Any NullMoth-supported NVIDIA GPU on macOS 15 (user space, hardware independent) | 3, 4, 6, 7, 8, 9, 10, 11, 12, 13, 16, 20, 22, 23 |
| Needs a specific NullMoth build (byte patches / offsets are version bound) | 2, 5 (NVK part), 14, 15 |
| Ada (RTX 40) only: NVDEC/NVENC t2d layout | 14, 15 |
| Depends on your panel and mainboard | 1 (HiDPI: panel ID, refresh rate), 17 (brightness: `_DSM`/`_DOD` paths in your DSDT) |
| Same hardware only | 18 (Intel AX211), 19 (ELAN0420 I²C touchpad), 24 (ALC256 codec; the layout depends on the machine) |
| Kext, preventive, higher risk | 21 (cursor-only commits) |

Suggested order: user-space first (plugin, translator) and live with it; then byte patches as needed; kexts last. Do not copy the machine-specific items (1, 17, 18, 19) blindly.

## Fixes

| # | Symptom | Root cause | Fix |
|---|---------|-----------|-----|
| 1 | No HiDPI / can't reach 165 Hz | NVKMS hides window scaling on dGPUs; IMP accepts ≤1.4× downscale at 165 Hz | 26-byte NVRM head-scaler patch + display override → 1792×1008 HiDPI @165 Hz |
| 2 | Dock stops presenting after login | Zero-copy flip hot-switched 60 s after boot | NVRM `IOSleep(60000)→0` |
| 3 | Black blocks / ghost text / square window corners | WindowServer layer-cache renders into *linear* shared IOSurface VRAM come out wrong; stale-upload races | `NVMTL_SURF_SHARE_MINPX` private tiled images + consistency patches |
| 4 | WindowServer 75–90 % CPU | Sync CPU copy + fence wait per IOSurface change | Async surface-in with host-pointer import |
| 5 | Chrome falls back to software compositing | ANGLE `disableMetalOnNvidia`; GPU sandbox denies `/dev/null` write & `hw.pagesize` | env override + 2-byte NVK patch + `hw.memsize` rewrite |
| 6 | Chrome/Electron flicker | `waitUntilScheduled` / scheduled handlers fire before GPU completion | Wait/run at completion |
| 7 | Occasional blank Chrome window | WebGL shader translate fails (`get_num_samples`) → GPU process restart | Spec-constant sample count (translator + plugin) |
| 8 | Green video previews, diagonal tearing | Plugin never held IOSurface use counts | Hold/release use count per command buffer |
| 9 | Graphite missing geometry | Translator dropped all vertex outputs when the return type was a freshly minted struct | Fall back to `type_def_of` |
| 10 | Slow Chrome scrolling | ~1 ms per pass into linear window RT | Tiled render shadow (13.6 → 3.2 ms/frame) |
| 11 | WindowServer misses 165 Hz frame budget | Self-bind guard copies the 28 MB framebuffer before each sampling draw | End pass→barrier→restart→sample self, no copy |
| 12 | Steam/CEF UI flicker | Apple GL-on-Metal MSAA pass with all-zero sample positions was rejected | Fall back to the standard sample pattern |
| 13 | Flat-colour tiles in Core Image Lanczos (screenshot previews) | Translator emitted pointer-taking helpers before their callers, losing a constant offset | Callers-first topological reorder |
| 14 | 16-px stripes in H.264 decode | NVDEC detile mode 1 (Blackwell) vs Ada t2d GOB | 1-byte patch |
| 15 | UU Remote host: stuck / garbled / slow | NVENC NotSync flag, bw8/bw16 vs t2d layout, slow BAR zeroing, no rate control | H.264 binary patches |
| 16 | UU Remote as controller crashes | Viewport depth outside [0,1] → NVK assert | Clamp znear/zfar |
| 17 | No brightness slider / Fn keys / battery | `_DSM`/`_DOD` stubbed in NVRM; EC0 hidden by OC SSDT | NVDSM (Lilu) + NVRMFB built-in panel + enable real EC0 |
| 18 | Wi-Fi / Bluetooth (AX211) | No Sequoia AirportItlwm; bluetoothd LE quirks; some boots Wi-Fi never came up (firmware ALIVE delayed by IO80211 parking ioctls in the shared gate, no retry) | AirportItlwm-Sequoia + init-recovery patch (15 s ALIVE budget, 3 attempts, watchdog re-init — `patches/itlwm/`), BTLEFix (Lilu) |
| 19 | Touchpad dead | VoodooI2C missing ADL-P PCI ID; VoodooGPIO TigerLakeLP class not built / wrong start chain | 3 patches + PS2 key SSDT |
| 20 | CrossOver/Wine killed by `EXC_GUARD` | `amfi_get_out_of_my_way` makes every process "platform" → immovable task port | boot-arg `ipc_control_port_options=0` |
| 21 | Rare flash of a stale frame on mouse movement (preventive, not reproduced locally) | NVRMFB cursor commits re-submitted the primary surface, racing the zero-copy flip | Cursor-only commits (ported from upstream 1.13.0) |
| 22 | Memoji / SceneKit character meshes shatter | SceneKit skinning kernels use compute `stage_in`, which the plugin did not implement | Compute stage_in via an MSL gather kernel (8/16/32-bit formats, BGRA, constant step) — `patches/nullmoth-1.13.0/per-fix/compute-stage-in.patch` |
| 23 | Photo Booth preview black (photos fine); compute / Core Image writes into a CAMetalLayer vanish | A `framebufferOnly=NO` drawable has usage `Unknown(0)`: Apple drivers read it as "all usages", the plugin read "none" → ShaderWrite refused | Read 0 as ShaderRead, ShaderWrite, RenderTarget (`NVMTL_UNKNOWN_USAGE=0` turns it off) — `per-fix/unknown-usage-all.patch`, `hidpi/catest/drawable-writes.swift` |
| 24 | No built-in microphone / speakers | AppleALC missing; codec is a Realtek ALC256 (subsystem `1558:25E1`) | AppleALC + `alcid=11`, script edits the ESP `config.plist` — `audio/` |

Details (Chinese): [docs/fixes.md](docs/fixes.md) · Pitfalls: [docs/pitfalls.md](docs/pitfalls.md).

Guards: `nvguard/` keeps the driver files patched after a NullMoth reinstall; `efiguard/` keeps the fixes that live on the OpenCore ESP (kexts, `alcid`, boot-args) and can be rehearsed on a copy of the ESP. A Photo Booth preview that is *upside down* while FaceTime/QuickTime are fine is not a driver bug — see docs/fixes.md ("excluded" section).

## Licensing

Patches to NullMoth plugin/kexts: PolyForm Noncommercial 1.0.0 (non-commercial use only). Translator patches: LGPL-3.0-or-later.
Lilu plugins and everything else the author wrote: GPL-3.0 (see [LICENSE](LICENSE)). Patch files keep the license of the upstream project they modify. See [NOTICE.md](NOTICE.md). Not affiliated with NullMoth Systems, NVIDIA or Apple.
