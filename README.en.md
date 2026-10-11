# NVIDIA RTX 4060 Laptop (Ada) on macOS — patches & fixes

[简体中文](README.md)

A collection of patches, byte-patch scripts and root-cause write-ups for running the
[NullMoth NVIDIA driver](https://github.com/nullmoth/nvidia-macos-driver) (v1.9.0) on a **Hackintosh (OpenCore) with macOS 15.8.1
and an RTX 4060 Laptop dGPU** (Clevo chassis, i7-13620H, BOE 0B40 2560×1440@165 Hz panel, Intel AX211, ELAN0420 I²C touchpad).

**Not included:** any NullMoth/NVIDIA binary or firmware, your EFI / `config.plist`, ACPI dumps. Get the driver from upstream.
What *is* included: source diffs against upstream v1.9.0, assertion-based binary patch scripts, kext/Lilu sources, install/rollback
scripts, regression test programs, and the analysis behind each fix.

> ⚠️ This modifies kernel extensions, system GPU plugins, OpenCore config and ACPI. Back up your EFI and keep a bootable fallback.
> Provided as is, no warranty. Machine-specific values (ESP device/UUID, panel IDs, binary hashes/offsets) must be adapted — scripts that
> touch the ESP refuse to run unless `ESP_DEV` and `ESP_UUID` are exported. See [docs/applying.md](docs/applying.md) (Chinese).

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
| 18 | Wi-Fi / Bluetooth (AX211) | No Sequoia AirportItlwm; bluetoothd LE quirks | AirportItlwm-Sequoia, BTLEFix (Lilu) |
| 19 | Touchpad dead | VoodooI2C missing ADL-P PCI ID; VoodooGPIO TigerLakeLP class not built / wrong start chain | 3 patches + PS2 key SSDT |
| 20 | CrossOver/Wine killed by `EXC_GUARD` | `amfi_get_out_of_my_way` makes every process "platform" → immovable task port | boot-arg `ipc_control_port_options=0` |

Details (Chinese): [docs/fixes.md](docs/fixes.md) · Pitfalls: [docs/pitfalls.md](docs/pitfalls.md).

## Licensing

Patches to NullMoth plugin/kexts: PolyForm Noncommercial 1.0.0 (non-commercial use only). Translator patches: LGPL-3.0-or-later.
Lilu plugins: GPL-3.0. Everything else: MIT. See [NOTICE.md](NOTICE.md). Not affiliated with NullMoth Systems, NVIDIA or Apple.
