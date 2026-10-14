#!/bin/bash
# Replace EFI/OC/Kexts/AirportItlwm.kext on the ESP with your own init-recovery build (put it in wifibt/kexts/AirportItlwm.kext,
# build steps in initrec/README.md). mtools on the block device, so it also works from safe mode.
# Run as root:  sudo -E ESP_UUID=<uuid> bash replace-airportitlwm.sh            install
#               sudo -E ESP_UUID=<uuid> bash replace-airportitlwm.sh undo DIR   put back the kext saved in DIR
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
[ "$(id -u)" -eq 0 ] || { echo "STOP: run with sudo"; exit 1; }
ESPUUID=${ESP_UUID:?set ESP_UUID to the Partition UUID of your OpenCore ESP (diskutil list; diskutil info <disk>)}; DEV=$(for d in $(diskutil list | awk '/ EFI /{print $NF}'); do [ "$(diskutil info $d | awk -F': *' '/Partition UUID/{print $2}')" = $ESPUUID ] && { echo $d; break; }; done); DEV=${DEV:-ESP-not-found}   # disk numbers occasionally change (NVMe probe order): find the ESP by its partition UUID
[ "$(diskutil info $DEV | awk -F': *' '/Partition UUID/{print $2}')" = $ESPUUID ] || { echo "STOP: $DEV is not the expected ESP"; exit 1; }
diskutil unmount $DEV >/dev/null 2>&1 || true
export PATH=/usr/local/bin:$PATH MTOOLS_SKIP_CHECK=1
I=(-i /dev/$DEV)
command -v mcopy >/dev/null || { echo "STOP: mtools missing"; exit 1; }

if [ "${1:-}" = undo ]; then
  SRC="${2:-}/AirportItlwm.kext"
  [ -f "$SRC/Contents/MacOS/AirportItlwm" ] || { echo "usage: replace-airportitlwm.sh undo <backup dir>"; exit 1; }
else
  SRC="$HERE/kexts/AirportItlwm.kext"
  [ -f "$SRC/Contents/MacOS/AirportItlwm" ] || { echo "STOP: missing $SRC"; exit 1; }
  grep -a -q "itlwm: init recovery" "$SRC/Contents/MacOS/AirportItlwm" || { echo "STOP: $SRC is not the init-recovery build"; exit 1; }
fi
grep -q "${WIFI_PCI_ID:-0x51F18086}" "$SRC/Contents/Info.plist" || { echo "STOP: kext does not match ${WIFI_PCI_ID:-0x51F18086} (set WIFI_PCI_ID, e.g. 0x51F08086)"; exit 1; }
mdir "${I[@]}" ::/EFI/OC/Kexts/AirportItlwm.kext/Contents/MacOS >/dev/null || { echo "STOP: no AirportItlwm.kext on the ESP"; exit 1; }

TS=$(date +%Y%m%d-%H%M%S); B="$HERE/backup/esp-aitlwm-$TS"; mkdir -p "$B"
mcopy "${I[@]}" -n -s ::/EFI/OC/Kexts/AirportItlwm.kext "$B/"
[ -f "$B/AirportItlwm.kext/Contents/MacOS/AirportItlwm" ] || { echo "STOP: backup failed (ESP untouched)"; exit 1; }
echo "== backup: $B ($(shasum -a 256 "$B/AirportItlwm.kext/Contents/MacOS/AirportItlwm" | cut -c1-8))"

mdeltree "${I[@]}" ::/EFI/OC/Kexts/AirportItlwm.kext
mcopy "${I[@]}" -s -n "$SRC" ::/EFI/OC/Kexts/
sync

T=$(mktemp -d /private/var/tmp/aitlwm.XXXX)
mcopy "${I[@]}" -n ::/EFI/OC/Kexts/AirportItlwm.kext/Contents/MacOS/AirportItlwm "$T/bin"
mcopy "${I[@]}" -n ::/EFI/OC/Kexts/AirportItlwm.kext/Contents/Info.plist "$T/plist"
cmp "$T/bin" "$SRC/Contents/MacOS/AirportItlwm" && cmp "$T/plist" "$SRC/Contents/Info.plist" \
  && echo "== AirportItlwm.kext on the ESP now matches $(shasum -a 256 "$SRC/Contents/MacOS/AirportItlwm" | cut -c1-8)" \
  || { echo "STOP: read-back differs, undo with: sudo bash $0 undo $B"; exit 1; }
rm -rf "$T"
echo "== done. Refresh the efiguard snapshot if you use it (efiguard/install.sh)"
echo "   then reboot normally. Undo: sudo bash $HERE/replace-airportitlwm.sh undo $B"
