#!/bin/bash
# Restore config.plist + Kexts from the newest (or given) pre-kexts backup.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
[ "$(id -u)" -eq 0 ] || { echo "STOP: run with sudo"; exit 1; }
TAR=${1:-$(ls -t "$HERE"/backup/esp-OC-pre-kexts-*.tar | head -1)}
ESPUUID=${ESP_UUID:?set ESP_UUID to the Partition UUID of your OpenCore ESP (diskutil list; diskutil info <disk>)}; DEV=$(for d in $(diskutil list | awk '/ EFI /{print $NF}'); do [ "$(diskutil info $d | awk -F': *' '/Partition UUID/{print $2}')" = $ESPUUID ] && { echo $d; break; }; done); DEV=${DEV:-ESP-not-found}   # disk numbers occasionally change (NVMe probe order): find the ESP by its partition UUID
[ "$(diskutil info $DEV | awk -F': *' '/Partition UUID/{print $2}')" = $ESPUUID ] || { echo "STOP: $DEV is not the expected ESP"; exit 1; }
diskutil unmount $DEV >/dev/null 2>&1 || true
MP=$(mktemp -d /private/var/tmp/esp.XXXX)
# safe mode (-x) cannot load msdosfs.kext: fall back to the FSKit (user-space) msdos module
mount -t msdos /dev/$DEV "$MP" 2>/dev/null || mount -F -t msdos /dev/$DEV "$MP"
trap 'sync; umount "$MP" 2>/dev/null || diskutil unmount force $DEV; rmdir "$MP" 2>/dev/null || true' EXIT
for k in BlueToolFixup BTLEFix IntelBluetoothFirmware IntelBTPatcher IntelBTProductName itlwm NVDSM; do rm -rf "$MP/EFI/OC/Kexts/$k.kext"; done
tar -C "$MP" -xf "$TAR"
plutil -lint "$MP/EFI/OC/config.plist"
echo "restored from $TAR"
