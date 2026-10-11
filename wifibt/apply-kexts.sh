#!/bin/bash
# Add Intel Wi-Fi (itlwm), Intel Bluetooth (IntelBluetoothFirmware + IntelBTPatcher + BlueToolFixup + BTLEFix)
# and NVDSM (Lilu plugin: real ACPI _DSM for NullMoth NVRM, needed for panel backlight)
# to the OpenCore ESP (disk1s4). Patches the LIVE config.plist in place (after a backup), idempotent.
# Run as root:  sudo bash apply-kexts.sh      Undo: sudo bash revert-kexts.sh
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
[ "$(id -u)" -eq 0 ] || { echo "STOP: run with sudo"; exit 1; }
DEV=${ESP_DEV:?set ESP_DEV to your OpenCore ESP, e.g. disk1s4 (see: diskutil list)}
[ "$(diskutil info $DEV | awk -F': *' '/Partition UUID/{print $2}')" = ${ESP_UUID:?set ESP_UUID to the Partition UUID of that ESP (diskutil info $ESP_DEV)} ] || { echo "STOP: $DEV is not the expected ESP"; exit 1; }
KEXTS="BlueToolFixup BTLEFix IntelBluetoothFirmware IntelBTPatcher IntelBTProductName itlwm NVDSM"   # order matters: Lilu plugins after Lilu (already first)
for k in $KEXTS; do [ -f "$HERE/kexts/$k.kext/Contents/Info.plist" ] || { echo "STOP: missing kexts/$k.kext"; exit 1; }; done

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
tar -C "$MP" -cf "$HERE/backup/esp-OC-pre-kexts-$TS.tar" EFI/OC/config.plist EFI/OC/Kexts
echo "== backup: $HERE/backup/esp-OC-pre-kexts-$TS.tar"

PB=/usr/libexec/PlistBuddy
n=$($PB -c 'Print :Kernel:Add' "$C" | grep -c 'BundlePath = ')
for k in $KEXTS; do
  rm -rf "$E/Kexts/$k.kext"; cp -R "$HERE/kexts/$k.kext" "$E/Kexts/"
  if $PB -c 'Print :Kernel:Add' "$C" | grep -q "BundlePath = $k.kext\$"; then
    echo "   $k.kext: entry already present (kext files refreshed)"; continue
  fi
  exe=""; [ -f "$HERE/kexts/$k.kext/Contents/MacOS/$k" ] && exe="Contents/MacOS/$k"
  $PB -c "Add :Kernel:Add:$n dict" \
      -c "Add :Kernel:Add:$n:Arch string x86_64" \
      -c "Add :Kernel:Add:$n:BundlePath string $k.kext" \
      -c "Add :Kernel:Add:$n:Comment string added-by-apply-kexts" \
      -c "Add :Kernel:Add:$n:Enabled bool true" \
      -c "Add :Kernel:Add:$n:ExecutablePath string $exe" \
      -c "Add :Kernel:Add:$n:MaxKernel string" \
      -c "Add :Kernel:Add:$n:MinKernel string" \
      -c "Add :Kernel:Add:$n:PlistPath string Contents/Info.plist" "$C"
  echo "   $k.kext: added as Kernel/Add #$n"
  n=$((n+1))
done
# BTLEFix routes IOUSBHostDevice::deviceRequest itself (random-address fix + HCI trace), so IntelBTPatcher, which
# routes the same function, stays installed but disabled.
i=0
while $PB -c "Print :Kernel:Add:$i:BundlePath" "$C" >/dev/null 2>&1; do
  if [ "$($PB -c "Print :Kernel:Add:$i:BundlePath" "$C")" = IntelBTPatcher.kext ]; then
    $PB -c "Set :Kernel:Add:$i:Enabled false" "$C"; echo "   IntelBTPatcher.kext: disabled (Kernel/Add #$i)"
  fi
  i=$((i+1))
done
# -btlfxboardid: on macOS 14+ BlueToolFixup only makes BlueTool treat this board-id (iMacPro1,1, a Mac with
# UART Bluetooth) as a USB-Bluetooth Mac when asked to; without it bluetoothd reports "External Bluetooth
# dongle was not found". OpenCore rewrites boot-args from the config every boot, so it goes there.
BA=":NVRAM:Add:7C436110-AB2A-4BBB-A880-FE41995C9F82:boot-args"
for arg in -btlfxboardid; do
  cur=$($PB -c "Print $BA" "$C")
  case " $cur " in *" $arg "*) echo "   boot-args: $arg already present";;
    *) $PB -c "Set $BA $cur $arg" "$C"; echo "   boot-args: added $arg";; esac
done
echo "   boot-args now: $($PB -c "Print $BA" "$C")"
# bluetoothHostControllerSwitchBehavior=always: bluetoothd then scans for an external USB dongle (generic HCI init)
# instead of assuming Apple's internal Broadcom controller. In NVRAM/Delete too, so OpenCore rewrites it every boot.
G=7C436110-AB2A-4BBB-A880-FE41995C9F82; KEY=bluetoothHostControllerSwitchBehavior
$PB -c "Delete :NVRAM:Add:$G:$KEY" "$C" 2>/dev/null || true
$PB -c "Add :NVRAM:Add:$G:$KEY string always" "$C"
if ! $PB -c "Print :NVRAM:Delete:$G" "$C" | grep -qx "    $KEY"; then
  $PB -c "Add :NVRAM:Delete:$G: string $KEY" "$C"
fi
echo "   NVRAM $KEY = $($PB -c "Print :NVRAM:Add:$G:$KEY" "$C") (also in NVRAM/Delete)"
# bluetoothd writes bluetoothExternalDongleFailed=01 after one failed dongle init and then never scans for the dongle
# again; let OpenCore delete it every boot.
KEY2=bluetoothExternalDongleFailed
if ! $PB -c "Print :NVRAM:Delete:$G" "$C" | grep -qx "    $KEY2"; then
  $PB -c "Add :NVRAM:Delete:$G: string $KEY2" "$C"
fi
echo "   NVRAM $KEY2 is deleted every boot"
plutil -lint "$C"
echo "== Kernel/Add now:"
$PB -c 'Print :Kernel:Add' "$C" | grep 'BundlePath = ' | sed 's/^ */   /'
sync
echo "== done. Reboot to load. Then open /Applications/HeliPort.app for Wi-Fi."
