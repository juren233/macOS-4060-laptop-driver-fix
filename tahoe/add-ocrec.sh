#!/bin/bash
# Adds a Limine menu entry "macOS Recovery" between "macOS" and "macOS safe mode":
#   EFI/OCREC = a copy of EFI/OC (same kexts / ACPI / drivers / boot-args, so macOS 26 still starts: -no_compat_check, RestrictEvents)
#   whose config.plist shows the OpenCore picker at once (ShowPicker = true, Timeout = 0, HideAuxiliary = false): you choose the
#   "Recovery ..." entry there. EFI/OC itself is not touched. Limine entry:  boot():/EFI/OCREC/OpenCore.efi
# Run as root:  sudo -E ESP_UUID=<uuid> bash add-ocrec.sh          Undo: sudo bash add-ocrec.sh undo   (removes EFI/OCREC and the Limine entry)
# efiguard only watches EFI/OC; it does not touch EFI/OCREC or limine.conf.
set -u
ESPUUID=${ESP_UUID:?set ESP_UUID to the Partition UUID of your OpenCore ESP (diskutil info <disk>)}; PB=/usr/libexec/PlistBuddy
DEV=$(for d in $(diskutil list | awk '/ EFI /{print $NF}'); do [ "$(diskutil info $d | awk -F': *' '/Partition UUID/{print $2}')" = $ESPUUID ] && { echo $d; break; }; done)
DEV=${DEV:-ESP-not-found}   # disk numbers occasionally change (two NVMe drives, probe order varies: disk1s4 / disk0s4): find the ESP by its partition UUID
HERE=$(cd "$(dirname "$0")" && pwd); MODE=${1:-add}
die() { echo "STOP: $*"; [ -n "${MP:-}" ] && { sync; umount "$MP" 2>/dev/null; rmdir "$MP" 2>/dev/null; }; exit 1; }
[ "$(id -u)" -eq 0 ] || die "run with sudo"
[ "$(diskutil info $DEV | awk -F': *' '/Partition UUID/{print $2}')" = $ESPUUID ] || die "$DEV is not the expected ESP"
n=0; while mount | grep -q "^/dev/$DEV "; do n=$((n+1)); [ $n -gt 30 ] && die "the ESP is mounted by someone else (efiguard?): try again in a minute"; sleep 2; done
MP=$(mktemp -d /private/var/tmp/esp.XXXX)
mount -t msdos /dev/$DEV "$MP" 2>/dev/null || mount -F -t msdos /dev/$DEV "$MP" || die "cannot mount $DEV"
L=$MP/limine.conf; [ -f "$L" ] || die "no limine.conf on the ESP"
[ -f "$MP/EFI/OC/config.plist" ] && plutil -lint "$MP/EFI/OC/config.plist" >/dev/null || die "EFI/OC/config.plist missing or does not parse"
TS=$(date +%Y%m%d-%H%M%S); B="$HERE/backup/ocrec-$TS"; mkdir -p "$B"; cp "$L" "$B/limine.conf"; cp "$MP/EFI/OC/config.plist" "$B/config.plist"
echo "== backup: $B"

edit_limine() {   # edit_limine add|remove
  python3 -I - "$L" "$1" <<'PY'
import sys,re
p,mode=sys.argv[1:3]
s=open(p,encoding='utf-8').read()
entry="""/macOS Recovery
comment: OpenCore in EFI/OCREC: picker shown at once, choose "Recovery ..." (macOS Recovery, Terminal under Utilities)
protocol: efi
path: boot():/EFI/OCREC/OpenCore.efi

"""
s=re.sub(r"/macOS Recovery\n(?:(?!\n\n).)*\n\n","",s,flags=re.S)   # idempotent: drop an existing block first
if mode=="add":
    m=re.search(r"^/macOS safe mode",s,flags=re.M)
    if not m: sys.exit("no '/macOS safe mode' entry found in limine.conf")
    s=s[:m.start()]+entry+s[m.start():]
open(p,"w",encoding="utf-8").write(s)
PY
}

if [ "$MODE" = undo ]; then
  rm -rf "$MP/EFI/OCREC"; edit_limine remove || die "limine.conf edit failed"
  sync; umount "$MP"; rmdir "$MP"; echo "== removed EFI/OCREC and the Limine entry"; exit 0
fi

R=$MP/EFI/OCREC; rm -rf "$R"; mkdir -p "$R"
for d in ACPI Drivers Kexts Tools; do [ -d "$MP/EFI/OC/$d" ] && cp -R "$MP/EFI/OC/$d" "$R/"; done
cp "$MP/EFI/OC/OpenCore.efi" "$R/" || die "cannot copy OpenCore.efi"
[ -d "$MP/EFI/OC/Resources" ] && cp -R "$MP/EFI/OC/Resources" "$R/"
cp "$MP/EFI/OC/config.plist" "$R/config.plist"
$PB -c "Set :Misc:Boot:ShowPicker true" -c "Set :Misc:Boot:Timeout 0" -c "Set :Misc:Boot:HideAuxiliary false" "$R/config.plist" || die "PlistBuddy"
plutil -lint "$R/config.plist" >/dev/null || die "new config.plist does not parse"
# the copy must keep everything that makes macOS 26 start
BA=$($PB -c "Print :NVRAM:Add:7C436110-AB2A-4BBB-A880-FE41995C9F82:boot-args" "$R/config.plist")
case $BA in *-no_compat_check*revpatch=sbvmm*) ;; *) die "boot-args lost -no_compat_check / revpatch: $BA";; esac
for f in OpenCore.efi config.plist; do [ -f "$R/$f" ] || die "EFI/OCREC/$f missing"; done
cp "$L" "$B/limine.conf.before"; edit_limine add || die "limine.conf edit failed (backup $B/limine.conf)"
grep -q 'path: boot():/EFI/OCREC/OpenCore.efi' "$L" || die "Limine entry not written"
sync; echo "== EFI/OCREC ready; boot-args: $BA"; grep -n -B1 -A4 '^/macOS' "$L" | sed 's/^/   /'
umount "$MP" && rmdir "$MP" || echo "WARN: could not unmount $MP"
echo "== done. Reboot: Limine menu now has 'macOS Recovery' between 'macOS' and 'macOS safe mode'."
