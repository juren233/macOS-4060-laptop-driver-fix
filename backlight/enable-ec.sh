#!/bin/bash
# Re-enable the real embedded controller (EC0) under macOS. Run as root:
#   sudo bash enable-ec.sh            install
#   sudo bash enable-ec.sh undo DIR   put back the SSDT-EC.aml saved in DIR
# The ESP's SSDT-EC.aml hides EC0 from macOS (_STA returns 0 when _OSI("Darwin")), so no EC driver binds and the
# EC's _Qxx events never run: no Fn brightness keys (_Q11/_Q12 -> Notify LCD0/DD1F 0x86/0x87), no battery.
# This renames that one _OSI("Darwin") string inside EC0._STA to "EC0_ON" (never matched, so EC0 always reports 0x0F,
# like on Windows/Linux), fixes the table checksum and keeps the fake "EC" device (ACID0001) for USB power.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
die() { echo "STOP: $*"; exit 1; }
[ "$(id -u)" -eq 0 ] || die "run with sudo"
ESPUUID=${ESP_UUID:?set ESP_UUID to the Partition UUID of your OpenCore ESP (diskutil list; diskutil info <disk>)}; DEV=$(for d in $(diskutil list | awk '/ EFI /{print $NF}'); do [ "$(diskutil info $d | awk -F': *' '/Partition UUID/{print $2}')" = $ESPUUID ] && { echo $d; break; }; done); DEV=${DEV:-ESP-not-found}; export PATH=/usr/local/bin:$PATH MTOOLS_SKIP_CHECK=1; I=(-i /dev/$DEV)
[ "$(diskutil info $DEV | awk -F': *' '/Partition UUID/{print $2}')" = $ESPUUID ] || die "$DEV is not the expected ESP"
command -v mcopy >/dev/null || die "mtools missing"
diskutil unmount $DEV >/dev/null 2>&1 || true
ESPF=::/EFI/OC/ACPI/SSDT-EC.aml
T=$(mktemp -d /var/tmp/ec.XXXX)

put() {  # put <file>: write to the ESP and read back
	mcopy "${I[@]}" -o -n "$1" "$ESPF" || die "ESP write failed"
	sync
	mcopy "${I[@]}" -n "$ESPF" "$T/readback.aml" && cmp -s "$1" "$T/readback.aml" || die "ESP read-back differs"
}

if [ "${1:-}" = undo ]; then
	[ -f "${2:-}/SSDT-EC.aml" ] || die "usage: enable-ec.sh undo <backup dir with SSDT-EC.aml>"
	put "$2/SSDT-EC.aml"
	echo "DONE. original SSDT-EC.aml restored. Reboot."
	exit 0
fi

mcopy "${I[@]}" -n "$ESPF" "$T/orig.aml" || die "no SSDT-EC.aml on the ESP"
BK="$HERE/backup/ec-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$BK" && cp -p "$T/orig.aml" "$BK/SSDT-EC.aml" || die "backup failed"
echo "== backup -> $BK"
/usr/bin/perl -e '
	local $/; open my $f, "<:raw", $ARGV[0] or die; my $d = <$f>; close $f;
	# EC0._STA: If (_OSI ("Darwin")) { Return (Zero) } Else { Return (0x0F) }
	my $pat = "EC0_\x14\x1b_STA\x00\xa0\x0f_OSI\x0dDarwin\x00\xa4\x00\xa1\x04\xa4\x0a\x0f";
	my $n = () = $d =~ /\Q$pat\E/g;
	$n == 1 or die "EC0._STA pattern found $n times (expected 1): not the known SSDT-EC, nothing changed\n";
	$d =~ s/\Q$pat\E/EC0_\x14\x1b_STA\x00\xa0\x0f_OSI\x0dEC0_ON\x00\xa4\x00\xa1\x04\xa4\x0a\x0f/;
	substr($d, 9, 1) = "\0";
	my $s = 0; $s += $_ for unpack("C*", $d);
	substr($d, 9, 1) = chr((256 - $s % 256) % 256);
	$s = 0; $s += $_ for unpack("C*", $d); $s % 256 == 0 or die "checksum\n";
	open my $o, ">:raw", $ARGV[1] or die; print $o $d; close $o;
' "$T/orig.aml" "$T/new.aml" || die "patch failed (ESP untouched)"
[ "$(stat -f %z "$T/orig.aml")" = "$(stat -f %z "$T/new.aml")" ] || die "size changed (ESP untouched)"
put "$T/new.aml"
echo "   ok  EC0 enabled for macOS (SSDT-EC.aml $(shasum -a 256 "$T/new.aml" | cut -c1-8))"
rm -rf "$T"
echo
echo "DONE. Reboot normally. Undo: sudo bash $HERE/enable-ec.sh undo $BK"
