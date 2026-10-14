#!/bin/bash
# Installs ACProbe.kext (read-only AC adapter diagnostic) into /Library/Extensions and rebuilds the auxiliary kernel collection
# (same recipe as audio/install-hda26.sh, keeps AppleHDA + NullMoth kexts). Reboot afterwards, then:  ioreg -rn AC -l | grep probe_
# Run as root:  sudo bash install-acprobe.sh        Undo: sudo bash install-acprobe.sh undo
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SRC="$HERE/ACProbe/build/ACProbe.kext"; DST=/Library/Extensions/ACProbe.kext
KC=/Library/KernelCollections/AuxiliaryKernelExtensions.kc
die() { echo "STOP: $*"; exit 1; }
[ "$(id -u)" -eq 0 ] || die "run with sudo"
[ "$(sw_vers -productVersion | cut -d. -f1)" = 26 ] || die "this is for macOS 26"
HDA=(com.apple.driver.AppleHDA com.apple.driver.AppleHDAController com.apple.driver.AppleHDAHardwareConfigDriver com.apple.driver.DspFuncLib com.apple.iokit.IOHDAFamily)
NV=(com.nullmoth.NVRM com.nullmoth.NVAccel com.nullmoth.NVRMFB com.nullmoth.NVRMAGDC)
build() {
  local KARG=(--allow-missing-kdk); [ -f /System/Library/Kernels/kernel ] && KARG+=(--kernel /System/Library/Kernels/kernel)
  local BARG=(); for b in "${HDA[@]}"; do BARG+=(-b "$b"); done
  kmutil create -n aux --volume-root / "${KARG[@]}" "${BARG[@]}" -B /System/Library/KernelCollections/BootKernelExtensions.kc \
    -S /System/Library/KernelCollections/SystemKernelExtensions.kc --repository /Library/Extensions --repository /Library/Apple/System/Library/Extensions -A "$1" -z
}
check() { local INS; INS=$(kmutil inspect -a x86_64 -A "$1" 2>/dev/null); shift; for k in "$@"; do printf '%s\n' "$INS" | grep -Fq "$k" || { echo "missing: $k"; return 1; }; done; }
B="$HERE/backup/acprobe-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$B"; cp -p "$KC" "$B/" || die "cannot back up $KC"; echo "== backup: $B"
N="$KC.probe-new"; rm -f "$N"
if [ "${1:-}" = undo ]; then
  rm -rf "$DST"; build "$N" > "$B/kmutil.log" 2>&1 || die "kmutil failed ($B/kmutil.log); collection unchanged"
  check "$N" "${HDA[@]}" "${NV[@]}" || die "kexts missing in new collection"
  mv -f "$N" "$KC" && echo "== ACProbe removed. Reboot."; exit 0
fi
[ -f "$SRC/Contents/MacOS/ACProbe" ] || die "build first: $HERE/ACProbe/build.sh"
rm -rf "$DST"; ditto "$SRC" "$DST"; chown -R root:wheel "$DST"; chmod -R go-w "$DST"; xattr -cr "$DST" 2>/dev/null
if ! build "$N" > "$B/kmutil.log" 2>&1; then rm -rf "$DST"; tail -15 "$B/kmutil.log"; die "kmutil failed ($B/kmutil.log); ACProbe removed, collection unchanged"; fi
if ! check "$N" local.juren.ACProbe "${HDA[@]}" "${NV[@]}"; then rm -rf "$DST" "$N"; die "not all kexts in the new collection; collection unchanged"; fi
mv -f "$N" "$KC" || die "cannot publish the collection (backup: $B)"
echo "== ACProbe is in the auxiliary kernel collection. Reboot, then:  ioreg -rn AC -l | grep probe_"
