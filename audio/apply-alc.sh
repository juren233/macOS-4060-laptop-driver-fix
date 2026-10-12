#!/bin/bash
# Add AppleALC (reference machine: Realtek ALC256, subsystem 1558:25E1, Clevo) to the OpenCore ESP and select a layout through
# the alcid= boot-arg. Patches the LIVE config.plist in place (after a backup), idempotent: re-run with another layout
# number to switch layouts.  Run as root:  sudo -E ESP_DEV=... ESP_UUID=... bash apply-alc.sh [layout]   (default 11)   Undo: revert-alc.sh
# AppleALC.kext is NOT shipped here: download the 1.9.8 RELEASE zip (see SOURCE.txt), unpack it, and point APPLEALC_KEXT at the .kext (default ./kexts/AppleALC.kext).
# ALC256 layouts shipped in AppleALC 1.9.8: 5 11 12 13 14 16 17 19 20 21 22 23 24 28 33 38 41 48 49 56 57 66 67 68 69 70 76 77 88 95 97 99 100
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
LAYOUT=${1:-11}
case "$LAYOUT" in ''|*[!0-9]*) echo "STOP: layout must be a number"; exit 1;; esac
[ "$(id -u)" -eq 0 ] || { echo "STOP: run with sudo"; exit 1; }
DEV=${ESP_DEV:?set ESP_DEV to your OpenCore ESP, e.g. disk1s4 (see: diskutil list)}
[ "$(diskutil info $DEV | awk -F': *' '/Partition UUID/{print $2}')" = ${ESP_UUID:?set ESP_UUID to the Partition UUID of that ESP (diskutil info $ESP_DEV)} ] || { echo "STOP: $DEV is not the expected ESP"; exit 1; }
KEXT=${APPLEALC_KEXT:-$HERE/kexts/AppleALC.kext}
[ -f "$KEXT/Contents/Info.plist" ] || { echo "STOP: AppleALC.kext not found at $KEXT (download it, see SOURCE.txt, or set APPLEALC_KEXT)"; exit 1; }

diskutil unmount $DEV >/dev/null 2>&1 || true
MP=$(mktemp -d /private/var/tmp/esp.XXXX)
# safe mode (-x) cannot load msdosfs.kext: fall back to the FSKit (user-space) msdos module
mount -t msdos /dev/$DEV "$MP" 2>/dev/null || mount -F -t msdos /dev/$DEV "$MP"
trap 'sync; umount "$MP" 2>/dev/null || diskutil unmount force $DEV; rmdir "$MP" 2>/dev/null || true' EXIT
E="$MP/EFI/OC"; C="$E/config.plist"
[ -f "$E/OpenCore.efi" ] && [ -f "$C" ] || { echo "STOP: unexpected ESP layout"; exit 1; }
plutil -lint "$C" >/dev/null || { echo "STOP: live config.plist does not parse"; exit 1; }

PB=/usr/libexec/PlistBuddy
$PB -c 'Print :Kernel:Add' "$C" | grep -q 'BundlePath = Lilu.kext$' || { echo "STOP: Lilu.kext is not in Kernel/Add (AppleALC is a Lilu plugin)"; exit 1; }

TS=$(date +%Y%m%d-%H%M%S)
mkdir -p "$HERE/backup"
tar -C "$MP" -cf "$HERE/backup/esp-OC-pre-alc-$TS.tar" EFI/OC/config.plist EFI/OC/Kexts
echo "== backup: $HERE/backup/esp-OC-pre-alc-$TS.tar"

k=AppleALC
rm -rf "$E/Kexts/$k.kext"; cp -R "$KEXT" "$E/Kexts/"
if $PB -c 'Print :Kernel:Add' "$C" | grep -q "BundlePath = $k.kext\$"; then
  echo "   $k.kext: entry already present (kext files refreshed)"
  i=0
  while $PB -c "Print :Kernel:Add:$i:BundlePath" "$C" >/dev/null 2>&1; do
    [ "$($PB -c "Print :Kernel:Add:$i:BundlePath" "$C")" = "$k.kext" ] && $PB -c "Set :Kernel:Add:$i:Enabled true" "$C"
    i=$((i+1))
  done
else
  n=$($PB -c 'Print :Kernel:Add' "$C" | grep -c 'BundlePath = ')
  # one PlistBuddy call per command: chained -c made the new array element a copy of the last one on this macOS
  $PB -c "Add :Kernel:Add:$n dict" "$C"
  for f in "Arch string x86_64" "BundlePath string $k.kext" "Comment string added-by-apply-alc" "Enabled bool true" \
           "ExecutablePath string Contents/MacOS/$k" "MaxKernel string" "MinKernel string" "PlistPath string Contents/Info.plist"; do
    $PB -c "Add :Kernel:Add:$n:$f" "$C"
  done
  echo "   $k.kext: added as Kernel/Add #$n (after Lilu)"
fi

# alcid= selects the layout. OpenCore rewrites boot-args from the config every boot, so it goes there.
BA=":NVRAM:Add:7C436110-AB2A-4BBB-A880-FE41995C9F82:boot-args"
cur=$($PB -c "Print $BA" "$C")
new=$(printf '%s' "$cur" | tr ' ' '\n' | grep -v '^alcid=' | grep -v '^$' | tr '\n' ' ')
$PB -c "Set $BA ${new}alcid=$LAYOUT" "$C"
echo "   boot-args now: $($PB -c "Print $BA" "$C")"
plutil -lint "$C"
echo "== Kernel/Add now:"
$PB -c 'Print :Kernel:Add' "$C" | grep 'BundlePath = ' | sed 's/^ */   /'
sync
echo "== done (layout $LAYOUT). Reboot to load. Check: system_profiler SPAudioDataType, or Sound settings."
echo "== if you use efiguard, refresh its snapshot now (otherwise it keeps the old state): see efiguard/install.sh"
