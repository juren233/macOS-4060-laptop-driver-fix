#!/bin/bash
# Native Wi-Fi (System Settings / menu bar) for the AX211 (8086:51f1) on Sequoia: replace itlwm.kext (+HeliPort) with
# laobamac's AirportItlwm-Sequoia v2.4.0-alpha (airportitlwm-dl/x, zip sha256 53b4eba2...). Run as root:
#   sudo bash install-airportitlwm.sh            install (itlwm stays on the ESP, disabled)
#   sudo bash install-airportitlwm.sh undo DIR   put back the config.plist saved in DIR (itlwm again)
# OC only: no system volume change. AirportItlwm is limited to Darwin 24.2.0-24.99.99 (as its README says).
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
die() { echo "STOP: $*"; exit 1; }
[ "$(id -u)" -eq 0 ] || die "run with sudo"
KX="$HERE/airportitlwm-dl/x/AirportItlwm.kext"
DEV=${ESP_DEV:?set ESP_DEV to your OpenCore ESP, e.g. disk1s4 (see: diskutil list)}; export PATH=/usr/local/bin:$PATH MTOOLS_SKIP_CHECK=1; I=(-i /dev/$DEV)
[ "$(diskutil info $DEV | awk -F': *' '/Partition UUID/{print $2}')" = ${ESP_UUID:?set ESP_UUID to the Partition UUID of that ESP (diskutil info $ESP_DEV)} ] || die "$DEV is not the expected ESP"
command -v mcopy >/dev/null || die "mtools missing"
diskutil unmount $DEV >/dev/null 2>&1 || true
PB=/usr/libexec/PlistBuddy
T=$(mktemp -d /var/tmp/aitlwm.XXXX)

putcfg() {  # putcfg <file>: write config.plist to the ESP and read back
	plutil -lint "$1" >/dev/null || die "config invalid (ESP untouched)"
	mcopy "${I[@]}" -o -n "$1" ::/EFI/OC/config.plist || die "config write failed"
	sync
	mcopy "${I[@]}" -n ::/EFI/OC/config.plist "$T/readback.plist" && cmp -s "$1" "$T/readback.plist" || die "config read-back differs"
}

if [ "${1:-}" = undo ]; then
	[ -f "${2:-}/config.plist" ] || die "usage: install-airportitlwm.sh undo <backup dir>"
	putcfg "$2/config.plist"
	echo "DONE. previous config.plist (itlwm) restored. Reboot, then start HeliPort."
	exit 0
fi

[ -f "$KX/Contents/MacOS/AirportItlwm" ] || die "AirportItlwm.kext missing"
grep -q 0x51F18086 "$KX/Contents/Info.plist" || die "AirportItlwm does not match 8086:51f1"

BK="$HERE/backup/aitlwm-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$BK"
mcopy "${I[@]}" -n ::/EFI/OC/config.plist "$BK/config.plist" && plutil -lint "$BK/config.plist" >/dev/null || die "config backup failed (nothing changed)"
echo "== backup -> $BK"

echo "== 1. AirportItlwm.kext on the ESP"
mdeltree "${I[@]}" ::/EFI/OC/Kexts/AirportItlwm.kext 2>/dev/null
mcopy "${I[@]}" -s -n "$KX" ::/EFI/OC/Kexts/ || die "ESP copy failed (config untouched)"
sync
mcopy "${I[@]}" -n ::/EFI/OC/Kexts/AirportItlwm.kext/Contents/MacOS/AirportItlwm "$T/bin"
cmp -s "$T/bin" "$KX/Contents/MacOS/AirportItlwm" || die "ESP read-back differs (config untouched)"
echo "   ok"

echo "== 2. config.plist: itlwm off, AirportItlwm on"
C="$T/config.plist"; cp "$BK/config.plist" "$C"
have=0; itl=0; i=0
while $PB -c "Print :Kernel:Add:$i:BundlePath" "$C" >/dev/null 2>&1; do
	case "$($PB -c "Print :Kernel:Add:$i:BundlePath" "$C")" in
	itlwm.kext) $PB -c "Set :Kernel:Add:$i:Enabled false" "$C"; itl=1 ;;
	AirportItlwm.kext) have=1; $PB -c "Set :Kernel:Add:$i:Enabled true" "$C"
		$PB -c "Set :Kernel:Add:$i:MinKernel 24.2.0" "$C"; $PB -c "Set :Kernel:Add:$i:MaxKernel 24.99.99" "$C" ;;
	esac
	i=$((i+1))
done
[ $itl = 1 ] || echo "   note: no itlwm.kext entry found"
if [ $have = 0 ]; then
	J='{"Arch":"x86_64","BundlePath":"AirportItlwm.kext","Comment":"laobamac AirportItlwm-Sequoia 2.4.0-alpha (added-by-install-airportitlwm)","Enabled":true,"ExecutablePath":"Contents/MacOS/AirportItlwm","MaxKernel":"24.99.99","MinKernel":"24.2.0","PlistPath":"Contents/Info.plist"}'
	plutil -insert Kernel.Add -json "$J" -append "$C" || die "config edit failed (ESP config untouched)"
fi
[ "$($PB -c "Print :Kernel:Add:0:BundlePath" "$C")" = Lilu.kext ] || die "Lilu is not first in Kernel/Add (ESP config untouched)"
putcfg "$C"
echo "   ok  itlwm disabled, AirportItlwm entry $([ $have = 1 ] && echo existing || echo "$i (new)")"
rm -rf "$T"
echo
echo "DONE. Quit HeliPort, reboot normally. Undo: sudo bash $HERE/install-airportitlwm.sh undo $BK"
