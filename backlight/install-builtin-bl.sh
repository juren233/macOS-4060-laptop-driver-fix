#!/bin/bash
# Built-in panel brightness for macOS (Control Center slider, brightness keys). Run as root:
#   sudo bash install-builtin-bl.sh
# - NVRMFB (fbbuild/NVRMFB.kext, from src/fb-patched/nvrm-fb.cpp): the eDP panel is reported built-in and gets the
#   IODisplay "brightness" parameter -> AppleBacklightDisplay.
# - NVDSM v8 (NVDSM/build/NVDSM.kext, on the ESP): hands NVKMS's panel backlight (nvKmsSetBacklight) to NVRMFB.
# - BrightnessKeys (acidanthera 1.0.3, deps/bkeys-dl): turns the panel's ACPI Notify 0x86/0x87 (Fn brightness keys,
#   EC _Q12/_Q11) into brightness key presses through VoodooPS2Keyboard; added to config.plist Kernel/Add after Lilu.
# Backs up NVRMFB.kext, the auxiliary kernel collection and the ESP's NVDSM.kext + config.plist first.
# Undo (also from the safe-mode fallback entry): sudo bash revert-builtin-bl.sh <backup dir printed below>
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
die() { echo "STOP: $*"; exit 1; }
[ "$(id -u)" -eq 0 ] || die "run with sudo"
FB="$HERE/fbbuild/NVRMFB.kext"; DSM="$HERE/NVDSM/build/NVDSM.kext"; BKX="$HERE/deps/bkeys-dl/x/BrightnessKeys.kext"
[ -f "$FB/Contents/MacOS/NVRMFB" ] && [ -f "$DSM/Contents/MacOS/NVDSM" ] && [ -f "$BKX/Contents/MacOS/BrightnessKeys" ] || die "build outputs missing"
PB=/usr/libexec/PlistBuddy
codesign --verify "$FB" || die "NVRMFB.kext signature invalid"
EXT=/Library/Extensions; KC=/Library/KernelCollections/AuxiliaryKernelExtensions.kc
KB=/System/Library/KernelCollections/BootKernelExtensions.kc; KS=/System/Library/KernelCollections/SystemKernelExtensions.kc
KARG=(--allow-missing-kdk); [ -f /System/Library/Kernels/kernel ] && KARG+=(--kernel /System/Library/Kernels/kernel)
ESPUUID=${ESP_UUID:?set ESP_UUID to the Partition UUID of your OpenCore ESP (diskutil list; diskutil info <disk>)}; DEV=$(for d in $(diskutil list | awk '/ EFI /{print $NF}'); do [ "$(diskutil info $d | awk -F': *' '/Partition UUID/{print $2}')" = $ESPUUID ] && { echo $d; break; }; done); DEV=${DEV:-ESP-not-found}; export PATH=/usr/local/bin:$PATH MTOOLS_SKIP_CHECK=1; I=(-i /dev/$DEV)
[ "$(diskutil info $DEV | awk -F': *' '/Partition UUID/{print $2}')" = $ESPUUID ] || die "$DEV is not the expected ESP"
command -v mcopy >/dev/null || die "mtools missing"
diskutil unmount $DEV >/dev/null 2>&1 || true
mdir "${I[@]}" ::/EFI/OC/Kexts/NVDSM.kext/Contents/MacOS >/dev/null || die "no NVDSM.kext on the ESP"

echo "== 1. test kernel collection with the new NVRMFB"
T=$(mktemp -d /var/tmp/nvbl.XXXX); mkdir -p "$T/repo"
for x in "$EXT"/*.kext; do [ "$(basename "$x")" = NVRMFB.kext ] || cp -R "$x" "$T/repo/"; done
cp -R "$FB" "$T/repo/"
chown -R root:wheel "$T/repo" && chmod -R go-w "$T/repo"
kmutil create -n aux --volume-root / "${KARG[@]}" -B $KB -S $KS --repository "$T/repo" -A "$T/aux.kc" -z >"$T/kmutil.log" 2>&1 \
  || { tail -20 "$T/kmutil.log"; die "test collection build failed (nothing changed)"; }
kmutil inspect -a x86_64 -A "$T/aux.kc" 2>/dev/null | grep -q com.nullmoth.NVRMFB || { tail -20 "$T/kmutil.log"; die "kmutil dropped NVRMFB (nothing changed)"; }
echo "   ok"

BK="$HERE/backup/bl-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$BK"
echo "== 2. backup -> $BK"
cp -Rp "$EXT/NVRMFB.kext" "$BK/" && cp -p "$KC" "$BK/AuxiliaryKernelExtensions.kc" || die "backup failed (nothing changed)"
mcopy "${I[@]}" -n -s ::/EFI/OC/Kexts/NVDSM.kext "$BK/" || die "ESP NVDSM backup failed (nothing changed)"
mcopy "${I[@]}" -n ::/EFI/OC/config.plist "$BK/config.plist" && plutil -lint "$BK/config.plist" >/dev/null || die "config.plist backup failed (nothing changed)"
[ -f "$BK/NVDSM.kext/Contents/MacOS/NVDSM" ] || die "ESP NVDSM backup incomplete (nothing changed)"
echo "   ok"

echo "== 3. install NVRMFB + rebuild the auxiliary collection"
rm -rf "$EXT/NVRMFB.kext" && ditto "$FB" "$EXT/NVRMFB.kext" && chown -R root:wheel "$EXT/NVRMFB.kext" && chmod -R 755 "$EXT/NVRMFB.kext" \
  || { rm -rf "$EXT/NVRMFB.kext"; ditto "$BK/NVRMFB.kext" "$EXT/NVRMFB.kext"; die "copy failed, old NVRMFB restored"; }
kmutil create -n aux --volume-root / "${KARG[@]}" -B $KB -S $KS --repository "$EXT" -A "$KC.new" -z >"$T/kmutil2.log" 2>&1 \
  && kmutil inspect -a x86_64 -A "$KC.new" 2>/dev/null | grep -q com.nullmoth.NVRMFB && mv -f "$KC.new" "$KC" \
  || { tail -20 "$T/kmutil2.log"; rm -f "$KC.new"; rm -rf "$EXT/NVRMFB.kext"; ditto "$BK/NVRMFB.kext" "$EXT/NVRMFB.kext"; die "collection build failed, old NVRMFB restored"; }
echo "   ok  NVRMFB $(shasum -a 256 "$EXT/NVRMFB.kext/Contents/MacOS/NVRMFB" | cut -c1-8)"

echo "== 4. NVDSM v8 on the ESP"
mdeltree "${I[@]}" ::/EFI/OC/Kexts/NVDSM.kext && mcopy "${I[@]}" -s -n "$DSM" ::/EFI/OC/Kexts/ || die "ESP copy failed: run revert-builtin-bl.sh $BK"
sync
mcopy "${I[@]}" -n ::/EFI/OC/Kexts/NVDSM.kext/Contents/MacOS/NVDSM "$T/nvdsm"
cmp -s "$T/nvdsm" "$DSM/Contents/MacOS/NVDSM" || die "ESP read-back differs: run revert-builtin-bl.sh $BK"
echo "   ok  NVDSM $(shasum -a 256 "$DSM/Contents/MacOS/NVDSM" | cut -c1-8)"

echo "== 5. BrightnessKeys on the ESP + config.plist"
mdeltree "${I[@]}" ::/EFI/OC/Kexts/BrightnessKeys.kext 2>/dev/null
mcopy "${I[@]}" -s -n "$BKX" ::/EFI/OC/Kexts/ || die "ESP copy failed: run revert-builtin-bl.sh $BK"
C="$T/config.plist"; cp "$BK/config.plist" "$C"
have=0; i=0
while $PB -c "Print :Kernel:Add:$i:BundlePath" "$C" >/dev/null 2>&1; do
  [ "$($PB -c "Print :Kernel:Add:$i:BundlePath" "$C")" = BrightnessKeys.kext ] && { have=1; $PB -c "Set :Kernel:Add:$i:Enabled true" "$C"; }
  i=$((i+1))
done
if [ $have = 0 ]; then
  J='{"Arch":"x86_64","BundlePath":"BrightnessKeys.kext","Comment":"added-by-install-builtin-bl","Enabled":true,"ExecutablePath":"Contents/MacOS/BrightnessKeys","MaxKernel":"","MinKernel":"","PlistPath":"Contents/Info.plist"}'
  plutil -insert Kernel.Add -json "$J" -append "$C" || die "config edit failed (ESP config untouched)"
fi
plutil -lint "$C" >/dev/null || die "edited config.plist invalid (ESP config untouched)"
[ "$($PB -c "Print :Kernel:Add:0:BundlePath" "$C")" = Lilu.kext ] || die "Lilu is not first in Kernel/Add (ESP config untouched)"
mcopy "${I[@]}" -o -n "$C" ::/EFI/OC/config.plist || die "config write failed: run revert-builtin-bl.sh $BK"
sync
mcopy "${I[@]}" -n ::/EFI/OC/config.plist "$T/readback.plist"
cmp -s "$C" "$T/readback.plist" || die "config read-back differs: run revert-builtin-bl.sh $BK"
mcopy "${I[@]}" -n ::/EFI/OC/Kexts/BrightnessKeys.kext/Contents/MacOS/BrightnessKeys "$T/bkeys"
cmp -s "$T/bkeys" "$BKX/Contents/MacOS/BrightnessKeys" || die "BrightnessKeys read-back differs: run revert-builtin-bl.sh $BK"
echo "   ok  BrightnessKeys.kext + Kernel/Add entry $i ($([ $have = 1 ] && echo existing || echo new))"
rm -rf "$T"
echo
echo "DONE. Reboot normally. Undo: sudo bash $HERE/revert-builtin-bl.sh $BK"
