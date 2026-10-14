#!/bin/bash
# macOS 26 removed AppleHDA.kext; AppleALC (on the ESP) patches AppleHDA by name, so without it there is no built-in audio.
# This puts AppleHDA (+ AppleHDAController, AppleHDAHardwareConfigDriver, IOHDAFamily, DspFuncLib) from the macOS 15.7.9 KDK
# (dortania KdkSupportPkg 24G830, extracted to dl/kdk15) into /Library/Apple/System/Library/Extensions and rebuilds the auxiliary
# kernel collection with those bundle ids requested explicitly (-b) - the sealed system volume is NOT touched, and a macOS update
# keeps the kext (it is just re-linked). Same kmutil recipe as ../update-26.sh finish.
# Also needs BTLEFix 1.0.6 on the ESP: it answers AppleHDADriver's OSKextRequestResource (layoutN.xml.zlib / Platforms.xml.zlib),
# which kernelmanagerd never answers for this kext - without it the driver waits for ever and no audio device appears.
# Run as root:  sudo bash install-hda26.sh        Undo: sudo bash install-hda26.sh undo
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
# AppleHDA source (default: the macOS 15.7.9 one from the Sequoia KDK, dortania 24G830 - the binary AppleALC 1.9.8 is validated
# against; the Tahoe beta 1 KDK copy, dl/kdk/..., attached the codec but its AppleHDADriver never started). Override: HDA_SRC=<AppleHDA.kext>
SRC=${HDA_SRC:-"$HERE/dl/kdk15/x/KDK.pkg/Payload/System/Library/Extensions/AppleHDA.kext"}
KC=/Library/KernelCollections/AuxiliaryKernelExtensions.kc
# kernelmanagerd answers kext resource requests (AppleHDADriver asks for layoutN.xml.zlib and then waits for the answer for ever)
# only for Apple-prefixed kexts that live in an Apple repository: "Cannot insert Kext com.apple.driver.AppleHDA ... at
# /Library/Extensions/AppleHDA.kext into a restricted lookup table". /Library/Apple/System/Library/Extensions is that repository
# (AppleMobileDevice.kext is there). The old /Library/Extensions copy must go (same bundle id twice).
DST=/Library/Apple/System/Library/Extensions/AppleHDA.kext
OLD=/Library/Extensions/AppleHDA.kext
die() { echo "STOP: $*"; exit 1; }
[ "$(id -u)" -eq 0 ] || die "run with sudo"
[ "$(sw_vers -productVersion | cut -d. -f1)" = 26 ] || die "this is for macOS 26"
TS=$(date +%Y%m%d-%H%M%S); B="$HERE/backup/hda26-$TS"

build() {   # build <out.kc> : link all kexts of /Library/Extensions into an auxiliary kernel collection
  local KARG=(--allow-missing-kdk); [ -f /System/Library/Kernels/kernel ] && KARG+=(--kernel /System/Library/Kernels/kernel)
  # Apple-prefixed kexts in /Library/Extensions are left out unless requested with -b (found with diag-hda26.sh)
  local BARG=(); for b in "${HDA[@]}"; do BARG+=(-b "$b"); done
  kmutil create -n aux --volume-root / "${KARG[@]}" "${BARG[@]}" -B /System/Library/KernelCollections/BootKernelExtensions.kc \
    -S /System/Library/KernelCollections/SystemKernelExtensions.kc --repository /Library/Extensions --repository /Library/Apple/System/Library/Extensions -A "$1" -z
}
check() {   # check <kc> <ids...>
  local KCF=$1; shift; local INS; INS=$(kmutil inspect -a x86_64 -A "$KCF" 2>/dev/null)
  for k in "$@"; do printf '%s\n' "$INS" | grep -Fq "$k" || { echo "missing in $KCF: $k"; return 1; }; done
}
HDA=(com.apple.driver.AppleHDA com.apple.driver.AppleHDAController com.apple.driver.AppleHDAHardwareConfigDriver com.apple.driver.DspFuncLib com.apple.iokit.IOHDAFamily)
NV=(com.nullmoth.NVRM com.nullmoth.NVAccel com.nullmoth.NVRMFB com.nullmoth.NVRMAGDC)

mkdir -p "$B"; cp -p "$KC" "$B/" || die "cannot back up $KC"
echo "== backup: $B"

if [ "${1:-}" = undo ]; then
  rm -rf "$DST" "$OLD"
  N="$KC.hda-new"; rm -f "$N"
  build "$N" > "$B/kmutil.log" 2>&1 || die "kmutil failed ($B/kmutil.log); previous collection still in place ($B)"
  check "$N" "${NV[@]}" || die "NullMoth kexts missing in the new collection"
  mv -f "$N" "$KC" && echo "== AppleHDA removed from the auxiliary kernel collection. Reboot."; exit 0
fi

[ -f "$SRC/Contents/MacOS/AppleHDA" ] || die "missing $SRC (re-extract the KDK, see this script's header)"
rm -rf "$DST" "$OLD"; ditto "$SRC" "$DST" || die "copy failed"
chown -R root:wheel "$DST"; chmod -R go-w "$DST"; xattr -cr "$DST" 2>/dev/null
N="$KC.hda-new"; rm -f "$N"
if ! build "$N" > "$B/kmutil.log" 2>&1; then
  rm -rf "$DST"; tail -15 "$B/kmutil.log"; die "kmutil failed (full log $B/kmutil.log); AppleHDA removed again, collection unchanged"
fi
if ! check "$N" "${HDA[@]}" "${NV[@]}"; then
  rm -rf "$DST" "$N"; die "AppleHDA/NullMoth kexts not all in the new collection ($B/kmutil.log); collection unchanged"
fi
mv -f "$N" "$KC" || die "cannot publish the collection (backup: $B/$(basename $KC))"
echo "== AppleHDA is in the auxiliary kernel collection:"
kmutil inspect -a x86_64 -A "$KC" 2>/dev/null | grep -E 'AppleHDA|IOHDAFamily|DspFuncLib|AppleMikey' | sed 's/^/   /'
echo "== done. Reboot, then check:  kextstat | grep -i hda ; system_profiler SPAudioDataType"
