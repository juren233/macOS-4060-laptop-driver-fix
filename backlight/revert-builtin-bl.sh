#!/bin/bash
# Undo install-builtin-bl.sh: puts back NVRMFB.kext, the auxiliary kernel collection, the ESP's NVDSM.kext and
# config.plist (dropping BrightnessKeys.kext if that config did not use it) from a
# backup made by it. Plain file copies + mtools: works from the safe-mode fallback entry too.
#   sudo bash revert-builtin-bl.sh backup/bl-YYYYmmdd-HHMMSS
set -uo pipefail
die() { echo "STOP: $*"; exit 1; }
[ "$(id -u)" -eq 0 ] || die "run with sudo"
BK=${1:-}; [ -n "$BK" ] || BK=$(ls -d "$(cd "$(dirname "$0")" && pwd)"/backup/bl-* 2>/dev/null | tail -1)
[ -f "$BK/AuxiliaryKernelExtensions.kc" ] && [ -f "$BK/NVRMFB.kext/Contents/MacOS/NVRMFB" ] && [ -f "$BK/NVDSM.kext/Contents/MacOS/NVDSM" ] \
  || die "not a complete backup: $BK"
echo "== restoring from $BK"
rm -rf /Library/Extensions/NVRMFB.kext && ditto "$BK/NVRMFB.kext" /Library/Extensions/NVRMFB.kext \
  && chown -R root:wheel /Library/Extensions/NVRMFB.kext && chmod -R 755 /Library/Extensions/NVRMFB.kext || die "NVRMFB.kext restore failed"
cp -p "$BK/AuxiliaryKernelExtensions.kc" /Library/KernelCollections/AuxiliaryKernelExtensions.kc || die "collection restore failed"
cmp -s "$BK/AuxiliaryKernelExtensions.kc" /Library/KernelCollections/AuxiliaryKernelExtensions.kc && echo "   ok  NVRMFB + auxiliary collection"
ESPUUID=${ESP_UUID:?set ESP_UUID to the Partition UUID of your OpenCore ESP (diskutil list; diskutil info <disk>)}; DEV=$(for d in $(diskutil list | awk '/ EFI /{print $NF}'); do [ "$(diskutil info $d | awk -F': *' '/Partition UUID/{print $2}')" = $ESPUUID ] && { echo $d; break; }; done); DEV=${DEV:-ESP-not-found}; export PATH=/usr/local/bin:$PATH MTOOLS_SKIP_CHECK=1; I=(-i /dev/$DEV)
[ "$(diskutil info $DEV | awk -F': *' '/Partition UUID/{print $2}')" = $ESPUUID ] || die "$DEV is not the expected ESP"
diskutil unmount $DEV >/dev/null 2>&1 || true
mdeltree "${I[@]}" ::/EFI/OC/Kexts/NVDSM.kext; mcopy "${I[@]}" -s -n "$BK/NVDSM.kext" ::/EFI/OC/Kexts/ || die "ESP NVDSM restore failed"
sync
T=$(mktemp /var/tmp/nvdsm.XXXX); mcopy "${I[@]}" -n ::/EFI/OC/Kexts/NVDSM.kext/Contents/MacOS/NVDSM "$T"
cmp -s "$T" "$BK/NVDSM.kext/Contents/MacOS/NVDSM" && echo "   ok  ESP NVDSM.kext" || die "ESP read-back differs"
if [ -f "$BK/config.plist" ]; then
  mcopy "${I[@]}" -o -n "$BK/config.plist" ::/EFI/OC/config.plist || die "config.plist restore failed"
  sync; mcopy "${I[@]}" -n ::/EFI/OC/config.plist "$T.cfg"
  cmp -s "$T.cfg" "$BK/config.plist" && echo "   ok  ESP config.plist" || die "config read-back differs"
  rm -f "$T.cfg"
  /usr/libexec/PlistBuddy -c "Print :Kernel:Add" "$BK/config.plist" | grep -q BrightnessKeys.kext || mdeltree "${I[@]}" ::/EFI/OC/Kexts/BrightnessKeys.kext 2>/dev/null
fi
rm -f "$T"
echo "DONE. Reboot normally."
