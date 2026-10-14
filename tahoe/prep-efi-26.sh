#!/bin/bash
# macOS 26 (Tahoe) step 1 of 3, run on macOS 15: EFI changes that work on BOTH 15 and 26 (so 15 keeps booting the same way).
#   + RestrictEvents.kext 1.1.6 (acidanthera release)  + boot-args -no_compat_check revpatch=sbvmm
#       iMacPro1,1 is a model macOS 26 dropped. We KEEP it (issue #154: switching an installed 15.8.1 to MacPro7,1 boot-loops);
#       -no_compat_check lets 26 boot on it, revpatch=sbvmm makes Software Update offer 26 to it.
#   + AirportItlwm-Tahoe.kext (laobamac d695c97 + our initrec retry, Tahoe scheme) as a second entry, MinKernel 25.0.0 MaxKernel 25.99.99;
#       the Sequoia AirportItlwm.kext entry (24.2.0 - 24.99.99) stays, OpenCore injects the one that matches the kernel.
#   ~ NVDSM.kext / BTLEFix.kext: same code, Lilu plugin max kernel Sequoia -> Tahoe (else Lilu skips them on 26).
# Nothing else changes (driver parking for the update itself = update-26.sh prepare, run right before updating).
# The payload hashes below are the AUTHOR'S builds: put your own kexts into payload/ESP and their sha256 here.
# Usage: sudo -E ESP_UUID=<uuid> bash prep-efi-26.sh [--check]     Undo: sudo bash revert-efi-26.sh <backup tar printed below>
set -u
HERE=$(cd "$(dirname "$0")" && pwd); P="$HERE/payload/ESP"; SYS=$(cd "$HERE/.." && pwd)
ESPUUID=${ESP_UUID:?set ESP_UUID to the Partition UUID of your OpenCore ESP (diskutil info <disk>)}; PB=/usr/libexec/PlistBuddy
DEV=$(for d in $(diskutil list | awk '/ EFI /{print $NF}'); do [ "$(diskutil info $d | awk -F': *' '/Partition UUID/{print $2}')" = $ESPUUID ] && { echo $d; break; }; done)
DEV=${DEV:-ESP-not-found}   # disk numbers occasionally change (two NVMe drives, probe order varies: disk1s4 / disk0s4): find the ESP by its partition UUID
BA=":NVRAM:Add:7C436110-AB2A-4BBB-A880-FE41995C9F82:boot-args"
MP=""; T=""
die() { echo "   STOP: $*" >&2; exit 1; }
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
cleanup() { [ -n "$MP" ] && { sync; umount "$MP" 2>/dev/null || diskutil unmount force $DEV >/dev/null 2>&1; rmdir "$MP" 2>/dev/null; }; [ -n "$T" ] && rm -rf "$T"; }
trap cleanup EXIT
TEST=${TAHOE_TEST_ESP:-}   # test on a copy: TAHOE_TEST_ESP=<dir with EFI/OC> bash prep-efi-26.sh (no root, no mount, no efiguard)
[ -n "$TEST" ] || [ "$(id -u)" -eq 0 ] || die "run with sudo"
[ "$(sw_vers -productVersion | cut -d. -f1)" = 15 ] || die "run this on macOS 15"
want() { [ "$(sha "$1")" = "$2" ] || die "payload file changed: $1"; }
want "$P/RestrictEvents.kext/Contents/MacOS/RestrictEvents"   16979236f272c0500913882e5347e38d5bad1841ea619fe5a0311e9f768aea4e
want "$P/AirportItlwm-Tahoe.kext/Contents/MacOS/AirportItlwm" 8560f2a400266a0da97bc0d0bb0f2c82b04b813e04de4b9f52744f99da1642fb
want "$P/NVDSM.kext/Contents/MacOS/NVDSM"                     993c39515cc1f00f3ae33bb48cd505c0114f07dba566de1505691486dbea8a4b
want "$P/BTLEFix.kext/Contents/MacOS/BTLEFix"                 3d7c6d2de68d418cf90a42ec1fcaed07b1a1fb804e024c80605b39a4d0dd982b
T=$(mktemp -d /var/tmp/tahoe-efi.XXXX) || die "tmp dir"
if [ -n "$TEST" ]; then E="$TEST/EFI/OC"; else
  [ "$(diskutil info $DEV | awk -F': *' '/Partition UUID/{print $2}')" = $ESPUUID ] || die "$DEV is not the expected ESP"
  diskutil unmount $DEV >/dev/null 2>&1 || true
  MP=$(mktemp -d /private/var/tmp/esp.XXXX)
  mount -t msdos /dev/$DEV "$MP" 2>/dev/null || mount -F -t msdos /dev/$DEV "$MP" || { rmdir "$MP"; MP=""; die "cannot mount $DEV"; }
  E="$MP/EFI/OC"; fi
S="${TEST:-$MP}"; C="$E/config.plist"
{ [ -f "$E/OpenCore.efi" ] || [ -n "$TEST" ]; } && [ -f "$C" ] || die "unexpected ESP layout"
plutil -lint "$C" >/dev/null || die "live config.plist does not parse"
for k in NVDSM BTLEFix AirportItlwm; do [ -d "$E/Kexts/$k.kext" ] || die "ESP has no $k.kext (not the EFI this was written for)"; done

# ---- the new config, built on a copy ----
N="$T/config.plist"; cp "$C" "$N"
idx() { local i=0 b; while b=$($PB -c "Print :Kernel:Add:$i:BundlePath" "$N" 2>/dev/null); do [ "$b" = "$1" ] && { echo $i; return; }; i=$((i+1)); done; }
count() { local i=0; while $PB -c "Print :Kernel:Add:$i:BundlePath" "$N" >/dev/null 2>&1; do i=$((i+1)); done; echo $i; }
a=$(idx AirportItlwm.kext); [ -n "$a" ] || die "no AirportItlwm.kext entry"
[ "$($PB -c "Print :Kernel:Add:$a:MaxKernel" "$N")" = 24.99.99 ] || die "AirportItlwm.kext entry has no MaxKernel 24.99.99 - it would load on 26 too"
addk() {  # $1 bundle dir name, $2 executable, $3 min, $4 max, $5 comment
  [ -n "$(idx "$1")" ] && { echo "   $1: entry already present"; return; }
  local n; n=$(count)
  $PB -c "Add :Kernel:Add:$n dict" -c "Add :Kernel:Add:$n:Arch string x86_64" -c "Add :Kernel:Add:$n:BundlePath string $1" \
      -c "Add :Kernel:Add:$n:Comment string $5" -c "Add :Kernel:Add:$n:Enabled bool true" \
      -c "Add :Kernel:Add:$n:ExecutablePath string Contents/MacOS/$2" -c "Add :Kernel:Add:$n:MaxKernel string $4" \
      -c "Add :Kernel:Add:$n:MinKernel string $3" -c "Add :Kernel:Add:$n:PlistPath string Contents/Info.plist" "$N" || die "PlistBuddy $1"
  echo "   $1: added as Kernel/Add #$n ($3 - $4)"; }
addk RestrictEvents.kext RestrictEvents "" "" "tahoe: revpatch=sbvmm (OTA on iMacPro1,1)"
addk AirportItlwm-Tahoe.kext AirportItlwm 25.0.0 25.99.99 "tahoe: AirportItlwm d695c97+initrec Tahoe build"
cur=$($PB -c "Print $BA" "$N")
for arg in -no_compat_check revpatch=sbvmm; do
  case " $cur " in *" $arg "*) echo "   boot-args: $arg already present";; *) cur="$cur $arg"; echo "   boot-args: + $arg";; esac
done
$PB -c "Set $BA $cur" "$N"
plutil -lint "$N" >/dev/null || die "new config does not parse (nothing changed)"
echo "   boot-args: $cur"
[ "${1:-}" = --check ] && { echo "CHECK PASS (nothing changed)"; exit 0; }

# ---- backup, then write ----
TS=$(date +%Y%m%d-%H%M%S); BKD=${TEST:+$TEST/..}; BKD=${BKD:-$HERE/backup}; mkdir -p "$BKD"; BK="$BKD/esp-OC-pre-tahoe-$TS.tar"
tar -C "$S" -cf "$BK" EFI/OC/config.plist EFI/OC/Kexts || die "backup failed (nothing changed)"
echo "== backup: $BK"
for k in RestrictEvents AirportItlwm-Tahoe NVDSM BTLEFix; do
  rm -rf "$E/Kexts/$k.kext" && cp -R "$P/$k.kext" "$E/Kexts/" || die "copy $k.kext - restore with: sudo bash $HERE/revert-efi-26.sh $BK"
  diff -r "$P/$k.kext" "$E/Kexts/$k.kext" >/dev/null || die "read-back $k.kext differs - restore with: sudo bash $HERE/revert-efi-26.sh $BK"
done
cp "$N" "$C" && sync && cmp -s "$N" "$C" || die "config.plist write/read-back failed - restore with: sudo bash $HERE/revert-efi-26.sh $BK"
echo "   ok: kexts + config.plist written and read back"
cleanup; MP=""; T=""
[ -n "$TEST" ] && { echo "(test mode: efiguard not refreshed)"; exit 0; }
echo "== efiguard snapshot (keeps the new entries and the two boot-args)"
ESP_UUID=$ESPUUID zsh "$SYS/efiguard/install.sh" 2>&1 | tail -3 || echo "   NOTE: run: sudo -E ESP_UUID=$ESPUUID zsh $SYS/efiguard/install.sh"
echo
echo "done. Reboot into macOS 15 once and check: Wi-Fi, Bluetooth, brightness, sound; then Software Update should list macOS 26."
echo "UNDO: sudo bash $HERE/revert-efi-26.sh $BK"
