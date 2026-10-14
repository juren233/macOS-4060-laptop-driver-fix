#!/bin/sh
# EFI rescue - lives on the OpenCore ESP in EFI/OC/rescue/, runs from macOS Recovery's Terminal (only sh, cp, cmp needed).
#   sh rescue.sh safe     -> config-safe.plist becomes config.plist (the current one is kept as config-before-rescue.plist)
#   sh rescue.sh restore  -> config-before-rescue.plist goes back
#   sh rescue.sh status
# config-safe.plist = the macOS 26 config with: NVIDIA driver parked (-nvoff), installer screen settings (small BAR,
# firmware framebuffer), and our own / new kexts disabled (AirportItlwm-Tahoe, BTLEFix, NVDSM, RestrictEvents).
# While ACTIVE exists, efiguard and the update-26 finish step leave the ESP alone.
D=$(cd "$(dirname "$0")" && pwd); OC=$(dirname "$D")
[ -f "$OC/OpenCore.efi" ] && [ -f "$D/config-safe.plist" ] || { echo "STOP: run this from EFI/OC/rescue on the OpenCore ESP"; exit 1; }
put() { cp "$1" "$OC/config.plist" && sync && cmp -s "$1" "$OC/config.plist"; }
case "$1" in
safe)
  if [ ! -f "$D/ACTIVE" ]; then cp "$OC/config.plist" "$D/config-before-rescue.plist" || { echo "STOP: cannot save the current config"; exit 1; }; fi
  put "$D/config-safe.plist" && touch "$D/ACTIVE" && sync && echo "OK: rescue config active. Restart." || { echo "FAILED - config.plist may be damaged: sh $0 restore"; exit 1; } ;;
restore)
  [ -f "$D/config-before-rescue.plist" ] || { echo "nothing to restore"; exit 1; }
  put "$D/config-before-rescue.plist" && rm -f "$D/ACTIVE" && sync && echo "OK: previous config back. Restart." || { echo "FAILED"; exit 1; } ;;
status)
  [ -f "$D/ACTIVE" ] && echo "rescue config ACTIVE" || echo "normal config"
  cmp -s "$OC/config.plist" "$D/config-safe.plist" && echo "config.plist = config-safe.plist" ;;
*) echo "usage: sh $0 safe | restore | status"; exit 1 ;;
esac
