#!/bin/bash
# Replace EFI/OC/Kexts/BTLEFix.kext on the ESP without mounting it (safe mode cannot load msdosfs and FSKit is not
# available there): mtools reads/writes the FAT volume on the block device directly.
# Run as root:  sudo bash safe-replace-btlefix.sh
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
[ "$(id -u)" -eq 0 ] || { echo "STOP: run with sudo"; exit 1; }
ESPUUID=${ESP_UUID:?set ESP_UUID to the Partition UUID of your OpenCore ESP (diskutil list; diskutil info <disk>)}; DEV=$(for d in $(diskutil list | awk '/ EFI /{print $NF}'); do [ "$(diskutil info $d | awk -F': *' '/Partition UUID/{print $2}')" = $ESPUUID ] && { echo $d; break; }; done); DEV=${DEV:-ESP-not-found}   # disk numbers move between boots: find the ESP by its partition UUID
[ "$(diskutil info $DEV | awk -F': *' '/Partition UUID/{print $2}')" = $ESPUUID ] || { echo "STOP: $DEV is not the expected ESP"; exit 1; }
diskutil unmount $DEV >/dev/null 2>&1 || true
export PATH=/usr/local/bin:$PATH MTOOLS_SKIP_CHECK=1
I=(-i /dev/$DEV)
command -v mcopy >/dev/null || { echo "STOP: mtools missing (brew install mtools)"; exit 1; }
SRC="$HERE/kexts/BTLEFix.kext"
[ -f "$SRC/Contents/MacOS/BTLEFix" ] || { echo "STOP: missing $SRC"; exit 1; }
mdir "${I[@]}" ::/EFI/OC/Kexts/BTLEFix.kext/Contents/MacOS >/dev/null || { echo "STOP: no BTLEFix.kext on the ESP"; exit 1; }

TS=$(date +%Y%m%d-%H%M%S); B="$HERE/backup/esp-btlefix-$TS"; mkdir -p "$B"
mcopy "${I[@]}" -n ::/EFI/OC/config.plist "$B/config.plist"
mcopy "${I[@]}" -n -s ::/EFI/OC/Kexts/BTLEFix.kext "$B/"
echo "== backup: $B"

mdeltree "${I[@]}" ::/EFI/OC/Kexts/BTLEFix.kext
mcopy "${I[@]}" -s -n "$SRC" ::/EFI/OC/Kexts/
sync

T=$(mktemp -d /private/var/tmp/btlefix.XXXX)
mcopy "${I[@]}" -n ::/EFI/OC/Kexts/BTLEFix.kext/Contents/MacOS/BTLEFix "$T/bin"
mcopy "${I[@]}" -n ::/EFI/OC/Kexts/BTLEFix.kext/Contents/Info.plist "$T/plist"
cmp "$T/bin" "$SRC/Contents/MacOS/BTLEFix" && cmp "$T/plist" "$SRC/Contents/Info.plist" \
  && echo "== BTLEFix.kext on the ESP now matches $(shasum -a 256 "$SRC/Contents/MacOS/BTLEFix" | cut -c1-8)" \
  || { echo "STOP: read-back differs, restore with: mdeltree + mcopy from $B"; exit 1; }
rm -rf "$T"

PB=/usr/libexec/PlistBuddy; C="$B/config.plist"; G=7C436110-AB2A-4BBB-A880-FE41995C9F82
echo "== live config checks:"
i=0
while $PB -c "Print :Kernel:Add:$i:BundlePath" "$C" >/dev/null 2>&1; do
  p=$($PB -c "Print :Kernel:Add:$i:BundlePath" "$C")
  case $p in BTLEFix.kext|IntelBTPatcher.kext|NVDSM.kext) echo "   $p Enabled=$($PB -c "Print :Kernel:Add:$i:Enabled" "$C")";; esac
  i=$((i+1))
done
$PB -c "Print :NVRAM:Delete:$G" "$C" | grep -q bluetoothExternalDongleFailed && echo "   NVRAM/Delete has bluetoothExternalDongleFailed" || echo "   WARNING: bluetoothExternalDongleFailed not in NVRAM/Delete"
echo "== done. Reboot normally (not the fallback entry)."
