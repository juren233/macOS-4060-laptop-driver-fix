#!/bin/bash
# Undo install-voodooi2c.sh: disable the VoodooI2C entries and re-enable VoodooPS2's VoodooInput/Trackpad/Mouse.
# Kext files stay on the ESP (harmless when disabled). Full restore instead: untar backup/esp-OC-pre-voodooi2c-*.tar
# onto the mounted ESP.  Run as root:  sudo bash revert-voodooi2c.sh
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
[ "$(id -u)" -eq 0 ] || { echo "STOP: run with sudo"; exit 1; }
ESPUUID=${ESP_UUID:?set ESP_UUID to the Partition UUID of your OpenCore ESP (diskutil list; diskutil info <disk>)}; DEV=$(for d in $(diskutil list | awk '/ EFI /{print $NF}'); do [ "$(diskutil info $d | awk -F': *' '/Partition UUID/{print $2}')" = $ESPUUID ] && { echo $d; break; }; done); DEV=${DEV:-ESP-not-found}   # disk numbers occasionally change (NVMe probe order): find the ESP by its partition UUID
[ "$(diskutil info $DEV | awk -F': *' '/Partition UUID/{print $2}')" = $ESPUUID ] || { echo "STOP: $DEV is not the expected ESP"; exit 1; }
diskutil unmount $DEV >/dev/null 2>&1 || true
MP=$(mktemp -d /private/var/tmp/esp.XXXX)
mount -t msdos /dev/$DEV "$MP" 2>/dev/null || mount -F -t msdos /dev/$DEV "$MP"
trap 'sync; umount "$MP" 2>/dev/null || diskutil unmount force $DEV; rmdir "$MP" 2>/dev/null || true' EXIT
C="$MP/EFI/OC/config.plist"
plutil -lint "$C" >/dev/null || { echo "STOP: live config.plist does not parse"; exit 1; }
mkdir -p "$HERE/backup"; cp "$C" "$HERE/backup/config-pre-revert-$(date +%Y%m%d-%H%M%S).plist"
PB=/usr/libexec/PlistBuddy
i=0
while p=$($PB -c "Print :Kernel:Add:$i:BundlePath" "$C" 2>/dev/null); do
  case "$p" in
    VoodooI2C.kext|VoodooI2C.kext/*|VoodooI2CHID.kext) $PB -c "Set :Kernel:Add:$i:Enabled false" "$C"; echo "   #$i $p: disabled";;
    VoodooPS2Controller.kext/Contents/PlugIns/VoodooInput.kext|VoodooPS2Controller.kext/Contents/PlugIns/VoodooPS2Trackpad.kext|VoodooPS2Controller.kext/Contents/PlugIns/VoodooPS2Mouse.kext)
      $PB -c "Set :Kernel:Add:$i:Enabled true" "$C"; echo "   #$i $p: enabled";;
  esac
  i=$((i+1))
done
plutil -lint "$C"
sync
echo "== reverted. Reboot."
