#!/bin/bash
# Puts back the 1.15.0 kexts + kernel collection saved by install-kexts-237.sh (and, on the live system, the ESP's
# config.plist = the old boot-args).   sudo bash rollback-kexts-237.sh <backup dir>
# From macOS Recovery (Terminal): unlock/mount the Data volume (diskutil apfs unlockVolume / mount), then
#   ROOT=/Volumes/<Data volume> bash /Volumes/<Data volume>~/work/nvidia-setup/kext237/rollback-kexts-237.sh \
#        /Volumes/<Data volume>/Library/NullMoth/backup-237-...
# Only copies files (ditto/cp), so it works there. The ESP step needs mtools and is skipped under ROOT: the three
# added boot-args (-nvrmnopm nvrmmapowner=0 nvfbhidpi=1) are ignored by the 1.15.0 kexts, so they can stay.
# /Library/NullMoth/nvfw is left in place (the 1.15.0 kernel reads /Users/Shared/nvfw, restored here if missing).
set -u
BK=${1:-}; ROOT=${ROOT:-}
[ -d "$BK" ] && [ -f "$BK/AuxiliaryKernelExtensions.kc" ] || { echo "STOP: give the backup dir"; exit 1; }
EXT=$ROOT/Library/Extensions; NM=$ROOT/Library/NullMoth; KC=$ROOT/Library/KernelCollections/AuxiliaryKernelExtensions.kc
FWOLD=$ROOT/Users/Shared/nvfw
f=0
for k in NVRM NVAccel NVRMFB NVRMAGDC; do [ -d "$BK/$k.kext" ] || { echo "backup lacks $k"; f=1; continue; }
  rm -rf "$EXT/$k.kext" && ditto "$BK/$k.kext" "$EXT/$k.kext" && chown -R root:wheel "$EXT/$k.kext" || f=1; done
[ -d "$BK/kexts" ] && { rm -rf "$NM/kexts" && ditto "$BK/kexts" "$NM/kexts" || f=1; }
[ -f "$BK/os-major" ] && cp -p "$BK/os-major" "$NM/os-major"
[ -d "$FWOLD/nvidia/610.57.04" ] || { [ -d "$BK/nvfw" ] && mkdir -p "$FWOLD" && ditto "$BK/nvfw" "$FWOLD" || f=1; }
cp -p "$BK/AuxiliaryKernelExtensions.kc" "$KC" && cmp -s "$BK/AuxiliaryKernelExtensions.kc" "$KC" || f=1
[ $f = 0 ] && echo "restored: kexts + kernel collection from $BK" || echo "KEXT RESTORE HAD ERRORS"
if [ -z "$ROOT" ]; then
  V=7C436110-AB2A-4BBB-A880-FE41995C9F82
  nvram -d $V:nullmoth-nv-starts 2>/dev/null; nvram -d $V:nullmoth-nv-ok 2>/dev/null
  ESPUUID=${ESP_UUID:?set ESP_UUID to the Partition UUID of your OpenCore ESP (diskutil info <disk>)}; DEV=$(for d in $(diskutil list | awk '/ EFI /{print $NF}'); do [ "$(diskutil info $d | awk -F': *' '/Partition UUID/{print $2}')" = $ESPUUID ] && { echo $d; break; }; done); DEV=${DEV:-ESP-not-found}; export PATH=/usr/local/bin:$PATH MTOOLS_SKIP_CHECK=1; I=(-i /dev/$DEV)
  if [ -f "$BK/config.plist" ] && command -v mcopy >/dev/null && [ "$(diskutil info $DEV | awk -F': *' '/Partition UUID/{print $2}')" = $ESPUUID ]; then
    diskutil unmount $DEV >/dev/null 2>&1 || true
    T=$(mktemp /var/tmp/oc237.XXXX)
    mcopy "${I[@]}" -o -n "$BK/config.plist" ::/EFI/OC/config.plist && sync && mcopy "${I[@]}" -n ::/EFI/OC/config.plist "$T" && cmp -s "$T" "$BK/config.plist" \
      && echo "restored: ESP config.plist (boot-args: $(cat "$BK/boot-args.txt"))" || { echo "ESP config.plist RESTORE FAILED (copy $BK/config.plist to EFI/OC by hand)"; f=1; }
    rm -f "$T"
    H=$(cd "$(dirname "$0")" && pwd); zsh "$H/../../system/efiguard/install.sh" 2>&1 | tail -2
  else
    echo "ESP config.plist left as it is"
  fi
else
  echo "ESP left as it is (Recovery); the added boot-args are ignored by 1.15.0"
fi
[ $f = 0 ] && echo "Reboot." || { echo "RESTORE HAD ERRORS"; exit 1; }
