#!/bin/bash
# Puts back EFI/OC/config.plist and EFI/OC/Kexts saved by prep-efi-26.sh (or update-26.sh) and refreshes efiguard.
#   sudo -E ESP_UUID=<uuid> bash revert-efi-26.sh <backup .tar>
set -u
BK=${1:-}; HERE=$(cd "$(dirname "$0")" && pwd); SYS=$(cd "$HERE/.." && pwd)
die() { echo "STOP: $*" >&2; exit 1; }
ESPUUID=${ESP_UUID:?set ESP_UUID to the Partition UUID of your OpenCore ESP (diskutil info <disk>)}
DEV=$(for d in $(diskutil list | awk '/ EFI /{print $NF}'); do [ "$(diskutil info $d | awk -F': *' '/Partition UUID/{print $2}')" = $ESPUUID ] && { echo $d; break; }; done)
DEV=${DEV:-ESP-not-found}   # disk numbers occasionally change (two NVMe drives, probe order varies: disk1s4 / disk0s4): find the ESP by its partition UUID
[ "$(id -u)" -eq 0 ] || die "run with sudo"
[ -f "$BK" ] && tar -tf "$BK" | grep -qx 'EFI/OC/config.plist' || die "give the backup tar"
[ "$(diskutil info $DEV | awk -F': *' '/Partition UUID/{print $2}')" = $ESPUUID ] || die "$DEV is not the expected ESP"
T=$(mktemp -d /var/tmp/tahoe-rev.XXXX); tar -C "$T" -xf "$BK" && plutil -lint "$T/EFI/OC/config.plist" >/dev/null || die "backup does not unpack / parse"
diskutil unmount $DEV >/dev/null 2>&1 || true
MP=$(mktemp -d /private/var/tmp/esp.XXXX)
mount -t msdos /dev/$DEV "$MP" 2>/dev/null || mount -F -t msdos /dev/$DEV "$MP" || die "cannot mount $DEV"
trap 'sync; umount "$MP" 2>/dev/null || diskutil unmount force $DEV; rmdir "$MP" 2>/dev/null; rm -rf "$T"' EXIT
f=0
if tar -tf "$BK" | grep -q '^EFI/OC/Kexts/'; then
  rm -rf "$MP/EFI/OC/Kexts" && cp -R "$T/EFI/OC/Kexts" "$MP/EFI/OC/Kexts" && diff -r "$T/EFI/OC/Kexts" "$MP/EFI/OC/Kexts" >/dev/null || f=1
fi
cp "$T/EFI/OC/config.plist" "$MP/EFI/OC/config.plist" && sync && cmp -s "$T/EFI/OC/config.plist" "$MP/EFI/OC/config.plist" || f=1
[ $f = 0 ] || die "RESTORE HAD ERRORS - the backup is still in $BK"
echo "restored from $BK"
sync; umount "$MP" 2>/dev/null || diskutil unmount force $DEV; rmdir "$MP" 2>/dev/null; trap 'rm -rf "$T"' EXIT
ESP_UUID=$ESPUUID zsh "$SYS/efiguard/install.sh" 2>&1 | tail -2
echo "Reboot."
