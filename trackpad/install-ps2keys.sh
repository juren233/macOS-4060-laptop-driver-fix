#!/bin/bash
# Add acpi/SSDT-PS2KEYS.aml (VoodooPS2 RMCF: Fn+F1 macro -> touchpad toggle, PrtSc -> F13) to the OpenCore
# ESP (disk1s4). Live config.plist, backup first, idempotent.
# Run as root:  sudo bash install-ps2keys.sh        Undo: sudo bash install-ps2keys.sh undo
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
[ "$(id -u)" -eq 0 ] || { echo "STOP: run with sudo"; exit 1; }
ESPUUID=${ESP_UUID:?set ESP_UUID to the Partition UUID of your OpenCore ESP (diskutil list; diskutil info <disk>)}; DEV=$(for d in $(diskutil list | awk '/ EFI /{print $NF}'); do [ "$(diskutil info $d | awk -F': *' '/Partition UUID/{print $2}')" = $ESPUUID ] && { echo $d; break; }; done); DEV=${DEV:-ESP-not-found}   # disk numbers occasionally change (NVMe probe order): find the ESP by its partition UUID
[ "$(diskutil info $DEV | awk -F': *' '/Partition UUID/{print $2}')" = $ESPUUID ] || { echo "STOP: $DEV is not the expected ESP"; exit 1; }
AML=SSDT-PS2KEYS.aml
[ -f "$HERE/acpi/$AML" ] || { echo "STOP: missing acpi/$AML"; exit 1; }

diskutil unmount $DEV >/dev/null 2>&1 || true
MP=$(mktemp -d /private/var/tmp/esp.XXXX)
mount -t msdos /dev/$DEV "$MP" 2>/dev/null || mount -F -t msdos /dev/$DEV "$MP"
trap 'sync; umount "$MP" 2>/dev/null || diskutil unmount force $DEV; rmdir "$MP" 2>/dev/null || true' EXIT
E="$MP/EFI/OC"; C="$E/config.plist"
[ -f "$E/OpenCore.efi" ] && [ -f "$C" ] || { echo "STOP: unexpected ESP layout"; exit 1; }
plutil -lint "$C" >/dev/null || { echo "STOP: live config.plist does not parse"; exit 1; }
mkdir -p "$HERE/backup"
cp "$C" "$HERE/backup/config-pre-ps2keys-$(date +%Y%m%d-%H%M%S).plist"

PB=/usr/libexec/PlistBuddy
i=0; idx=""
while p=$($PB -c "Print :ACPI:Add:$i:Path" "$C" 2>/dev/null); do
  [ "$p" = "$AML" ] && { idx=$i; break; }
  i=$((i+1))
done

if [ "${1:-}" = undo ]; then
  [ -n "$idx" ] && $PB -c "Set :ACPI:Add:$idx:Enabled false" "$C" && echo "   ACPI/Add #$idx $AML: disabled"
  plutil -lint "$C"; sync; echo "== reverted. Reboot."; exit 0
fi

cp "$HERE/acpi/$AML" "$E/ACPI/$AML"
if [ -n "$idx" ]; then
  $PB -c "Set :ACPI:Add:$idx:Enabled true" "$C"; echo "   ACPI/Add $AML: present (#$idx), enabled, file refreshed"
else
  $PB -c "Add :ACPI:Add:$i dict" \
      -c "Add :ACPI:Add:$i:Comment string VoodooPS2 RMCF Fn+F1 touchpad toggle, PrtSc F13" \
      -c "Add :ACPI:Add:$i:Enabled bool true" \
      -c "Add :ACPI:Add:$i:Path string $AML" "$C"
  echo "   ACPI/Add $AML: added as #$i"
fi
plutil -lint "$C"
echo "== ACPI/Add:"; $PB -c 'Print :ACPI:Add' "$C" | grep -E 'Path|Enabled' | paste - - | sed 's/^ */   /'
sync
echo "== done. Reboot: Fn+F1 toggles the touchpad, PrtSc becomes F13."
