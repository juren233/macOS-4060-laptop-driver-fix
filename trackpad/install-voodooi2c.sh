#!/bin/bash
# Touchpad = ELAN0420 on I2C0 (PCI 8086:51e8, ADL-P LPSS). Its PS/2 side (ETD0467) answers the Elan identify,
# so VoodooPS2Trackpad attaches, but it never sends packets. This switches the OpenCore ESP (disk1s4) to
# VoodooI2C 2.9.1 + VoodooI2CHID:
#   - kexts/VoodooI2C.kext is upstream 2.9.1 with 0x51e88086 added to VoodooI2CPCILakeController's IOPCIMatch
#     (upstream only lists Cannon/Ice/Comet Lake-LP ids; the GPIO plugin already knows INTC1055)
#   - VoodooPS2's VoodooInput/Trackpad/Mouse plugins are disabled (two VoodooInputs conflict); PS/2 keyboard stays
# Patches the LIVE config.plist in place after a backup; idempotent.
# Run as root:  sudo bash install-voodooi2c.sh      Undo: sudo bash revert-voodooi2c.sh
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
[ "$(id -u)" -eq 0 ] || { echo "STOP: run with sudo"; exit 1; }
ESPUUID=${ESP_UUID:?set ESP_UUID to the Partition UUID of your OpenCore ESP (diskutil list; diskutil info <disk>)}; DEV=$(for d in $(diskutil list | awk '/ EFI /{print $NF}'); do [ "$(diskutil info $d | awk -F': *' '/Partition UUID/{print $2}')" = $ESPUUID ] && { echo $d; break; }; done); DEV=${DEV:-ESP-not-found}   # disk numbers move between boots: find the ESP by its partition UUID
[ "$(diskutil info $DEV | awk -F': *' '/Partition UUID/{print $2}')" = $ESPUUID ] || { echo "STOP: $DEV is not the expected ESP"; exit 1; }
for k in VoodooI2C VoodooI2CHID; do [ -f "$HERE/kexts/$k.kext/Contents/MacOS/$k" ] || { echo "STOP: missing kexts/$k.kext"; exit 1; }; done
grep -q 0x51e88086 "$HERE/kexts/VoodooI2C.kext/Contents/Info.plist" || { echo "STOP: VoodooI2C.kext lacks the 51e8 IOPCIMatch patch"; exit 1; }

diskutil unmount $DEV >/dev/null 2>&1 || true
MP=$(mktemp -d /private/var/tmp/esp.XXXX)
# safe mode (-x) cannot load msdosfs.kext: fall back to the FSKit (user-space) msdos module
mount -t msdos /dev/$DEV "$MP" 2>/dev/null || mount -F -t msdos /dev/$DEV "$MP"
trap 'sync; umount "$MP" 2>/dev/null || diskutil unmount force $DEV; rmdir "$MP" 2>/dev/null || true' EXIT
E="$MP/EFI/OC"; C="$E/config.plist"
[ -f "$E/OpenCore.efi" ] && [ -f "$C" ] || { echo "STOP: unexpected ESP layout"; exit 1; }
plutil -lint "$C" >/dev/null || { echo "STOP: live config.plist does not parse"; exit 1; }

TS=$(date +%Y%m%d-%H%M%S)
mkdir -p "$HERE/backup"
tar -C "$MP" -cf "$HERE/backup/esp-OC-pre-voodooi2c-$TS.tar" EFI/OC/config.plist EFI/OC/Kexts
echo "== backup: $HERE/backup/esp-OC-pre-voodooi2c-$TS.tar"

PB=/usr/libexec/PlistBuddy
idx_of() {  # print the Kernel/Add index whose BundlePath is $1, or nothing
  local i=0 p
  while p=$($PB -c "Print :Kernel:Add:$i:BundlePath" "$C" 2>/dev/null); do
    [ "$p" = "$1" ] && { echo $i; return; }
    i=$((i+1))
  done
}

for k in VoodooI2C VoodooI2CHID; do rm -rf "$E/Kexts/$k.kext"; cp -R "$HERE/kexts/$k.kext" "$E/Kexts/"; done
echo "   kexts copied to EFI/OC/Kexts"

# dependencies first: VoodooI2C links against VoodooGPIO + VoodooI2CServices, VoodooI2CHID against VoodooI2C
ENTRIES=(
  "VoodooI2C.kext/Contents/PlugIns/VoodooGPIO.kext|Contents/MacOS/VoodooGPIO"
  "VoodooI2C.kext/Contents/PlugIns/VoodooI2CServices.kext|Contents/MacOS/VoodooI2CServices"
  "VoodooI2C.kext/Contents/PlugIns/VoodooInput.kext|Contents/MacOS/VoodooInput"
  "VoodooI2C.kext|Contents/MacOS/VoodooI2C"
  "VoodooI2CHID.kext|Contents/MacOS/VoodooI2CHID"
)
n=$($PB -c 'Print :Kernel:Add' "$C" | grep -c 'BundlePath = ')
for e in "${ENTRIES[@]}"; do
  bp=${e%%|*}; exe=${e#*|}
  i=$(idx_of "$bp")
  if [ -n "$i" ]; then
    $PB -c "Set :Kernel:Add:$i:Enabled true" "$C"; echo "   $bp: already present (#$i), enabled"; continue
  fi
  $PB -c "Add :Kernel:Add:$n dict" \
      -c "Add :Kernel:Add:$n:Arch string x86_64" \
      -c "Add :Kernel:Add:$n:BundlePath string $bp" \
      -c "Add :Kernel:Add:$n:Comment string added-by-install-voodooi2c" \
      -c "Add :Kernel:Add:$n:Enabled bool true" \
      -c "Add :Kernel:Add:$n:ExecutablePath string $exe" \
      -c "Add :Kernel:Add:$n:MaxKernel string" \
      -c "Add :Kernel:Add:$n:MinKernel string" \
      -c "Add :Kernel:Add:$n:PlistPath string Contents/Info.plist" "$C"
  echo "   $bp: added as Kernel/Add #$n"
  n=$((n+1))
done

for bp in VoodooPS2Controller.kext/Contents/PlugIns/VoodooInput.kext \
          VoodooPS2Controller.kext/Contents/PlugIns/VoodooPS2Trackpad.kext \
          VoodooPS2Controller.kext/Contents/PlugIns/VoodooPS2Mouse.kext; do
  i=$(idx_of "$bp")
  [ -n "$i" ] && { $PB -c "Set :Kernel:Add:$i:Enabled false" "$C"; echo "   $bp: disabled (#$i)"; }
done

plutil -lint "$C"
echo "== Kernel/Add now:"
i=0
while p=$($PB -c "Print :Kernel:Add:$i:BundlePath" "$C" 2>/dev/null); do
  echo "   #$i $($PB -c "Print :Kernel:Add:$i:Enabled" "$C") $p"; i=$((i+1))
done
sync
echo "== done. Reboot to load. If the touchpad is still dead (or the keyboard misbehaves): sudo bash revert-voodooi2c.sh"
