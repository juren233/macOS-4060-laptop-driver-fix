#!/bin/bash
# Zero-copy scanout from boot (2026-10-11). Root fix for "the Dock vanishes every boot until killall Dock".
# One-shot, run with sudo. Steps:
#   1. installs the NVRM kext whose autoGo opens flip immediately after the boot-hold release instead of
#      60 s later (patch-nvrm-190.py; install + kernel-collection rebuild + backup via install-kexts-190.sh),
#      so WindowServer's very first transaction already runs in flip mode and no surface is ever hot-switched;
#   2. drops -nvrmnoflip from the OpenCore config on the ESP AND from the live NVRAM variable (OpenCore does
#      not overwrite an existing boot-args, so both places must change or the flag survives reboots);
#   3. removes the local.nvflip LaunchDaemon (its "display armed + 60 s" switch was what broke the Dock).
# Undo: kexts -> rollback-kexts-190.sh <backup dir printed by the installer>; boot-args -> re-add
#       -nvrmnoflip with nvram + the ESP config; daemon -> reinstall /Library/LaunchDaemons/local.nvflip.plist.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
UUID=7C436110-AB2A-4BBB-A880-FE41995C9F82
FLAGLESS='-v keepsyms=1 debug=0x100 nvfb=1 nvaccel=1 nvfbheads=4 -nvkmsnosmooth amfi_get_out_of_my_way=0x1 amfi=0x80'

echo "== 1/3 install kexts (NVRM: head-scaler + flip-at-boot patches)"
bash "$HERE/install-kexts-190.sh"

echo "== 2/3 OpenCore config on the ESP + live NVRAM: drop -nvrmnoflip"
ESPUUID=${ESP_UUID:?set ESP_UUID to the Partition UUID of your OpenCore ESP (diskutil list; diskutil info <disk>)}; DEV=$(for d in $(diskutil list | awk '/ EFI /{print $NF}'); do [ "$(diskutil info $d | awk -F': *' '/Partition UUID/{print $2}')" = $ESPUUID ] && { echo $d; break; }; done); DEV=${DEV:-ESP-not-found}   # disk numbers move between boots: find the ESP by its partition UUID
[ "$(diskutil info $DEV | awk -F': *' '/Partition UUID/{print $2}')" = $ESPUUID ]
diskutil unmount $DEV >/dev/null 2>&1 || true
MP=$(mktemp -d /private/var/tmp/esp.XXXX); mount -t msdos /dev/$DEV "$MP"
CUR=$(python3 -c "import plistlib,sys; p=plistlib.load(open(sys.argv[1],'rb')); print(p['NVRAM']['Add']['$UUID'].get('boot-args',''))" "$MP/EFI/OC/config.plist")
if [ "$CUR" = "$FLAGLESS" ]; then
  echo "   ESP already without -nvrmnoflip"
else
  python3 - "$MP/EFI/OC/config.plist" <<'EOF'
import plistlib, sys
p, f = sys.argv[1], '7C436110-AB2A-4BBB-A880-FE41995C9F82'
d = plistlib.load(open(p, 'rb'))
ba = d['NVRAM']['Add'][f]['boot-args']
assert ' -nvrmnoflip' in ba or ba.endswith('-nvrmnoflip'), f'unexpected ESP boot-args: {ba!r}'
d['NVRAM']['Add'][f]['boot-args'] = ' '.join(w for w in ba.split() if w != '-nvrmnoflip')
plistlib.dump(d, open(p, 'wb'))
EOF
  python3 -c "import plistlib,sys; plistlib.load(open(sys.argv[1],'rb'))" "$MP/EFI/OC/config.plist" && echo "   ESP config updated + relint OK"
fi
find "$MP/EFI" "$MP" -maxdepth 3 -name '._*' -type f -delete 2>/dev/null || true
sync; umount "$MP" 2>/dev/null || diskutil unmount force $DEV; rmdir "$MP" 2>/dev/null || true

LIVE=$(nvram boot-args 2>/dev/null | sed 's/^boot-args[[:space:]]*//')
case " $LIVE " in
  *" -nvrmnoflip "*) nvram boot-args="$(echo "$LIVE" | sed 's/ *-nvrmnoflip//')"; echo "   live NVRAM updated: $(nvram boot-args)";;
  *) echo "   live NVRAM already without -nvrmnoflip: $LIVE";;
esac

echo "== 3/3 remove the nvflip LaunchDaemon"
launchctl bootout system/local.nvflip 2>/dev/null || true
rm -f /Library/LaunchDaemons/local.nvflip.plist
echo "   removed (/Library/Application Support/nvflip payload left in place, harmless)"

echo
echo "DONE. Reboot to activate:   sudo shutdown -r now"
echo "After login verify:"
echo "  ioreg -l | grep nvrm-flip            -> \"nvrm-flip\" = on"
echo "  sysctl debug.nvaccel_iop_flips       -> grows while the desktop updates"
echo "  /var/log/nvflip.log                  -> no new lines (daemon gone)"
echo "  the Dock                             -> present at login, no killall"
