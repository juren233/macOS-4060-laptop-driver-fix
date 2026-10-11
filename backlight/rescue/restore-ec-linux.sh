#!/bin/bash
# Arch Linux: put the original SSDT-EC.aml (EC0 hidden from macOS) back on the macOS ESP. Run: sudo bash restore-ec-linux.sh
set -euo pipefail
B64='U1NEVMQAAAAC8ENPUlAgAFNzZHRFQwAAABAAAElOVEwnCSQgoCoAFVwvA19TQl9QQzAwTFBDQgYAFVwvBF9TQl9QQzAwTFBDQkVDMF8GABAwXC8EX1NCX1BDMDBMUENCRUMwXxQbX1NUQQCgD19PU0kNRGFyd2luAKQAoQSkCg8QQwRcLwNfU0JfUEMwMExQQ0JbgjBFQ19fCF9ISUQNQUNJRDAwMDEAFBtfU1RBAKAQX09TSQ1EYXJ3aW4ApAoPoQOkAA=='
SHA=04a94d552659ca57acc8859c3e85712e6fd867693fe3090d84193f934d1afea1
DEV=$(readlink -f /dev/disk/by-partuuid/${ESP_PARTUUID:?set ESP_PARTUUID to the lower-case PARTUUID of the macOS ESP}) || { echo "macOS ESP (PARTUUID $ESP_PARTUUID) not found"; exit 1; }
T=$(mktemp -d)
echo "$B64" | base64 -d > "$T/SSDT-EC.aml"
echo "$SHA  $T/SSDT-EC.aml" | sha256sum -c --quiet || { echo "embedded data corrupt"; exit 1; }
MP=$(findmnt -nro TARGET -S "$DEV" | head -1 || true)
MOUNTED=0
if [ -z "$MP" ]; then MP=$T/esp; mkdir "$MP"; mount -t vfat "$DEV" "$MP"; MOUNTED=1; fi
F=$(find "$MP" -maxdepth 4 -ipath "$MP/efi/oc/acpi/ssdt-ec.aml" | head -1)
[ -n "$F" ] || { echo "EFI/OC/ACPI/SSDT-EC.aml not on $DEV"; [ $MOUNTED = 1 ] && umount "$MP"; exit 1; }
cp "$F" "$T/SSDT-EC.patched.aml"
cp "$T/SSDT-EC.aml" "$F"; sync
echo "$SHA  $F" | sha256sum -c --quiet && echo "OK: original SSDT-EC.aml restored on $DEV ($F). Reboot into macOS."
[ $MOUNTED = 1 ] && umount "$MP"
