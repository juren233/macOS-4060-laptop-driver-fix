#!/bin/bash
# Restore config.plist + Kexts from the newest (or given) pre-alc backup and remove AppleALC.kext.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
[ "$(id -u)" -eq 0 ] || { echo "STOP: run with sudo"; exit 1; }
TAR=${1:-$(ls -t "$HERE"/backup/esp-OC-pre-alc-*.tar | tail -1)}   # oldest: the state before the first apply-alc run
DEV=${ESP_DEV:?set ESP_DEV to your OpenCore ESP, e.g. disk1s4 (see: diskutil list)}
[ "$(diskutil info $DEV | awk -F': *' '/Partition UUID/{print $2}')" = ${ESP_UUID:?set ESP_UUID to the Partition UUID of that ESP (diskutil info $ESP_DEV)} ] || { echo "STOP: $DEV is not the expected ESP"; exit 1; }
diskutil unmount $DEV >/dev/null 2>&1 || true
MP=$(mktemp -d /private/var/tmp/esp.XXXX)
mount -t msdos /dev/$DEV "$MP" 2>/dev/null || mount -F -t msdos /dev/$DEV "$MP"
trap 'sync; umount "$MP" 2>/dev/null || diskutil unmount force $DEV; rmdir "$MP" 2>/dev/null || true' EXIT
rm -rf "$MP/EFI/OC/Kexts/AppleALC.kext"
tar -C "$MP" -xf "$TAR"
plutil -lint "$MP/EFI/OC/config.plist"
echo "restored from $TAR"
