#!/bin/bash
# Puts back the kexts + kernel collection (and the ESP's NVDSM.kext) saved by install-kexts-115.sh.
#   sudo bash rollback-kexts-115.sh <backup dir>
# From macOS Recovery (Terminal): mount the Data volume (diskutil apfs unlockVolume / mount), then run with ROOT=/Volumes/<Data volume>.
# The ESP step needs mtools and is skipped there; the new NVDSM also works with the 1.9.0 NVRM (it routes the backlight as before).
set -u
BK=${1:-}; ROOT=${ROOT:-}
[ -d "$BK" ] && [ -f "$BK/AuxiliaryKernelExtensions.kc" ] || { echo "STOP: give the backup dir"; exit 1; }
EXT=$ROOT/Library/Extensions; NM=$ROOT/Library/NullMoth; KC=$ROOT/Library/KernelCollections/AuxiliaryKernelExtensions.kc
f=0
for k in NVRM NVAccel NVRMFB NVRMAGDC; do [ -d "$BK/$k.kext" ] || { echo "backup lacks $k"; f=1; continue; }
  rm -rf "$EXT/$k.kext" && ditto "$BK/$k.kext" "$EXT/$k.kext" && chown -R root:wheel "$EXT/$k.kext" || f=1; done
[ -d "$BK/kexts" ] && { rm -rf "$NM/kexts" && ditto "$BK/kexts" "$NM/kexts" || f=1; }
[ -f "$BK/os-major" ] && cp -p "$BK/os-major" "$NM/os-major"
cp -p "$BK/AuxiliaryKernelExtensions.kc" "$KC" && cmp -s "$BK/AuxiliaryKernelExtensions.kc" "$KC" || f=1
[ $f = 0 ] && echo "restored: kexts + kernel collection from $BK" || echo "KEXT RESTORE HAD ERRORS"
ESPUUID=${ESP_UUID:-}   # the ESP step (NVDSM.kext back) needs it: sudo -E ESP_UUID=<uuid> ...
DEV=$(for d in $(diskutil list | awk '/ EFI /{print $NF}'); do [ "$(diskutil info $d | awk -F': *' '/Partition UUID/{print $2}')" = $ESPUUID ] && { echo $d; break; }; done); DEV=${DEV:-ESP-not-found}   # disk numbers occasionally change (NVMe probe order): find the ESP by UUID
export PATH=/usr/local/bin:$PATH MTOOLS_SKIP_CHECK=1; I=(-i /dev/$DEV)
if [ -z "$ROOT" ] && [ -n "$ESPUUID" ] && [ -f "$BK/NVDSM.kext/Contents/MacOS/NVDSM" ] && command -v mcopy >/dev/null \
   && [ "$(diskutil info $DEV | awk -F': *' '/Partition UUID/{print $2}')" = "$ESPUUID" ]; then
  diskutil unmount $DEV >/dev/null 2>&1 || true
  T=$(mktemp /var/tmp/nvdsm.XXXX)
  mdeltree "${I[@]}" ::/EFI/OC/Kexts/NVDSM.kext; mcopy "${I[@]}" -s -n "$BK/NVDSM.kext" ::/EFI/OC/Kexts/ && sync \
    && mcopy "${I[@]}" -n ::/EFI/OC/Kexts/NVDSM.kext/Contents/MacOS/NVDSM "$T" && cmp -s "$T" "$BK/NVDSM.kext/Contents/MacOS/NVDSM" \
    && echo "restored: ESP NVDSM.kext" || { echo "ESP NVDSM RESTORE FAILED"; f=1; }
  rm -f "$T"
  H=$(cd "$(dirname "$0")" && pwd); zsh "$H/../efiguard/install.sh" 2>&1 | tail -2
else
  echo "ESP NVDSM.kext left as it is"
fi
[ $f = 0 ] && echo "Reboot." || { echo "RESTORE HAD ERRORS"; exit 1; }
