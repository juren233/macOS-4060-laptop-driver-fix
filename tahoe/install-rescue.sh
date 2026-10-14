#!/bin/bash
# Puts the Recovery rescue kit on the OpenCore ESP (EFI/OC/rescue/: rescue.sh, config-safe.plist, README.txt), makes efiguard
# and the installed update-26.sh respect it, refreshes efiguard. Changes nothing in config.plist.
#   sudo -E ESP_UUID=<uuid> bash install-rescue.sh        (re-run after any deliberate config.plist change, so config-safe.plist follows it)
set -u
HERE=$(cd "$(dirname "$0")" && pwd); SYS=$(cd "$HERE/.." && pwd)
ESPUUID=${ESP_UUID:?set ESP_UUID to the Partition UUID of your OpenCore ESP (diskutil info <disk>)}; PB=/usr/libexec/PlistBuddy
DEV=$(for d in $(diskutil list | awk '/ EFI /{print $NF}'); do [ "$(diskutil info $d | awk -F': *' '/Partition UUID/{print $2}')" = $ESPUUID ] && { echo $d; break; }; done)
DEV=${DEV:-ESP-not-found}   # disk numbers move between boots (disk1s4 on 15, disk0s4 after some 26 boots): find the ESP by its partition UUID
BA=":NVRAM:Add:7C436110-AB2A-4BBB-A880-FE41995C9F82:boot-args"; MP=""; T=""
die() { echo "   STOP: $*" >&2; exit 1; }
cleanup() { [ -n "$MP" ] && { sync; umount "$MP" 2>/dev/null || diskutil unmount force $DEV >/dev/null 2>&1; rmdir "$MP" 2>/dev/null; }; [ -n "$T" ] && rm -rf "$T"; }
trap cleanup EXIT
TEST=${RESCUE_TEST_ESP:-}   # test on a copy: RESCUE_TEST_ESP=<dir with EFI/OC> bash install-rescue.sh
[ -n "$TEST" ] || [ "$(id -u)" -eq 0 ] || die "run with sudo"
[ -n "$TEST" ] || [ "$(diskutil info $DEV | awk -F': *' '/Partition UUID/{print $2}')" = $ESPUUID ] || die "$DEV is not the expected ESP"
T=$(mktemp -d /var/tmp/rescue.XXXX)
if [ -n "$TEST" ]; then E="$TEST/EFI/OC"; else
  diskutil unmount $DEV >/dev/null 2>&1 || true
  MP=$(mktemp -d /private/var/tmp/esp.XXXX)
  mount -t msdos /dev/$DEV "$MP" 2>/dev/null || mount -F -t msdos /dev/$DEV "$MP" || { rmdir "$MP"; MP=""; die "cannot mount $DEV"; }
  E="$MP/EFI/OC"; fi
C="$E/config.plist"; R="$E/rescue"
{ [ -f "$E/OpenCore.efi" ] || [ -n "$TEST" ]; } && plutil -lint "$C" >/dev/null || die "unexpected ESP layout"
[ -f "$R/ACTIVE" ] && die "the rescue config is active right now - restore first (sh $R/rescue.sh restore)"

# config-safe = the live config + parked driver + installer screen settings + our/new kexts off
N="$T/config-safe.plist"; cp "$C" "$N"
$PB -c "Set :UEFI:Quirks:ResizeGpuBars -1" -c "Set :Booter:Quirks:ResizeAppleGpuBars 0" "$N" || die "BAR"
i=0; while p=$($PB -c "Print :Kernel:Block:$i:Identifier" "$N" 2>/dev/null); do
  [ "$p" = com.apple.iokit.IONDRVSupport ] && $PB -c "Set :Kernel:Block:$i:Enabled false" "$N"; i=$((i+1)); done
off=""; i=0; while b=$($PB -c "Print :Kernel:Add:$i:BundlePath" "$N" 2>/dev/null); do
  case "$b" in AirportItlwm-Tahoe.kext|BTLEFix.kext|NVDSM.kext|RestrictEvents.kext) $PB -c "Set :Kernel:Add:$i:Enabled false" "$N"; off="$off $b";; esac
  i=$((i+1)); done
cur=$($PB -c "Print $BA" "$N"); case " $cur " in *" -nvoff "*) ;; *) cur="$cur -nvoff";; esac
case " $cur " in *" -no_compat_check "*) ;; *) cur="$cur -no_compat_check";; esac
$PB -c "Set $BA $cur" "$N"
plutil -lint "$N" >/dev/null || die "config-safe does not parse"
echo "   config-safe: kexts off:$off"
echo "   config-safe: boot-args: $cur"

mkdir -p "$R" || die "mkdir rescue"
cp "$N" "$R/config-safe.plist" && cp "$HERE/rescue/rescue.sh" "$R/rescue.sh" && sed "s/ESP_UUID_HERE/$ESPUUID/" "$HERE/rescue/README.txt" > "$R/README.txt" || die "copy to ESP"
sync; cmp -s "$N" "$R/config-safe.plist" && cmp -s "$HERE/rescue/rescue.sh" "$R/rescue.sh" || die "ESP read-back differs"
echo "   ok: EFI/OC/rescue written and read back"
cleanup; MP=""; T=""
[ -n "$TEST" ] && { echo "(test mode: stops here)"; exit 0; }

# the installed finish script must know about the rescue marker too
if [ -f /Library/NullMoth/tahoe/update-26.sh ]; then
  cp "$HERE/update-26.sh" /Library/NullMoth/tahoe/update-26.sh && chown root:wheel /Library/NullMoth/tahoe/update-26.sh && chmod 755 /Library/NullMoth/tahoe/update-26.sh \
    && echo "   ok: /Library/NullMoth/tahoe/update-26.sh refreshed" || echo "   NOTE: could not refresh /Library/NullMoth/tahoe/update-26.sh"
fi
echo "== efiguard (new efiguard.sh: hands off while the rescue config is active)"
ESP_UUID=$ESPUUID zsh "$SYS/efiguard/install.sh" 2>&1 | tail -2
echo "done."
