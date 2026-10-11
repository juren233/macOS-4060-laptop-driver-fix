#!/bin/bash
# Puts back the kexts + kernel collection saved by install-kexts-190.sh.  Usage: sudo rollback-kexts-190.sh <backup dir>
# From macOS Recovery (Terminal): mount the Data volume (diskutil apfs unlockVolume / mount), then run with ROOT=/Volumes/<Data volume>.
set -u
BK=${1:-}; ROOT=${ROOT:-}
[ -d "$BK" ] && [ -f "$BK/AuxiliaryKernelExtensions.kc" ] || { echo "STOP: give the backup dir"; exit 1; }
EXT=$ROOT/Library/Extensions; NM=$ROOT/Library/NullMoth; KC=$ROOT/Library/KernelCollections/AuxiliaryKernelExtensions.kc
f=0
for k in NVRM NVAccel NVRMFB NVRMAGDC; do [ -d "$BK/$k.kext" ] || { echo "backup lacks $k"; f=1; continue; }
  rm -rf "$EXT/$k.kext" && ditto "$BK/$k.kext" "$EXT/$k.kext" || f=1; done
[ -d "$BK/kexts" ] && { rm -rf "$NM/kexts" && ditto "$BK/kexts" "$NM/kexts" || f=1; }
[ -f "$BK/os-major" ] && cp -p "$BK/os-major" "$NM/os-major"
cp -p "$BK/AuxiliaryKernelExtensions.kc" "$KC" || f=1
[ $f = 0 ] && echo "restored: kexts + kernel collection from $BK. Reboot." || { echo "RESTORE HAD ERRORS"; exit 1; }
