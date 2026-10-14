#!/bin/bash
# Fix "macOS sees no AC adapter" (ExternalConnected = No while plugged in): \_SB.AC._PSR fails when evaluated by macOS.
# Adds SSDT-ACPSR.aml (replacement _PSR returning ACFG) + an ACPI/Patch renaming the DSDT's AC._PSR to XPSR, in EFI/OC/config.plist.
# Live config, backup first, idempotent.   Run as root:  sudo -E ESP_UUID=<uuid> bash install-acpsr.sh        Undo: sudo bash install-acpsr.sh undo
# Afterwards refresh the guard snapshot:  sudo -E ESP_UUID=<uuid> zsh efiguard/install.sh
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
[ "$(id -u)" -eq 0 ] || { echo "STOP: run with sudo"; exit 1; }
AML=SSDT-ACPSR.aml; PCOMMENT="AC._PSR to XPSR (replacement in SSDT-ACPSR)"
ESPUUID=${ESP_UUID:?set ESP_UUID to the Partition UUID of your OpenCore ESP (diskutil info <disk>)}
DEV=; for d in $(diskutil list | awk '/ EFI /{print $NF}'); do [ "$(diskutil info $d | awk -F': *' '/Partition UUID/{print $2}')" = $ESPUUID ] && { DEV=$d; break; }; done   # disk numbers occasionally change (NVMe probe order): find the ESP by UUID
[ -n "$DEV" ] || { echo "STOP: ESP (partition UUID $ESPUUID) not found"; exit 1; }
echo "== ESP = $DEV"
[ -f "$HERE/acpi/$AML" ] || { echo "STOP: missing acpi/$AML"; exit 1; }
n=0; while mount | grep -q "^/dev/$DEV "; do n=$((n+1)); [ $n -gt 30 ] && { echo "STOP: the ESP is mounted by someone else (efiguard?): try again in a minute"; exit 1; }; sleep 2; done
MP=$(mktemp -d /private/var/tmp/esp.XXXX)
mount -t msdos /dev/$DEV "$MP" 2>/dev/null || mount -F -t msdos /dev/$DEV "$MP"
trap 'sync; umount "$MP" 2>/dev/null || diskutil unmount force $DEV >/dev/null 2>&1; rmdir "$MP" 2>/dev/null || true' EXIT
E="$MP/EFI/OC"; C="$E/config.plist"
[ -f "$E/OpenCore.efi" ] && [ -f "$C" ] || { echo "STOP: unexpected ESP layout"; exit 1; }
plutil -lint "$C" >/dev/null || { echo "STOP: live config.plist does not parse"; exit 1; }
B="$HERE/backup/acpsr-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$B"; cp "$C" "$B/config.plist"; echo "== backup: $B"
PB=/usr/libexec/PlistBuddy
find_idx() { local i=0 v; while v=$($PB -c "Print :$1:$i:$2" "$C" 2>/dev/null); do [ "$v" = "$3" ] && { echo $i; return; }; i=$((i+1)); done; }
aidx=$(find_idx ACPI:Add Path "$AML"); pidx=$(find_idx ACPI:Patch Comment "$PCOMMENT")
if [ "${1:-}" = undo ]; then
  [ -n "$aidx" ] && $PB -c "Set :ACPI:Add:$aidx:Enabled false" "$C" && echo "   ACPI/Add $AML: disabled"
  [ -n "$pidx" ] && $PB -c "Set :ACPI:Patch:$pidx:Enabled false" "$C" && echo "   ACPI/Patch: disabled"
  plutil -lint "$C"; sync; echo "== reverted. Reboot."; exit 0
fi
cp "$HERE/acpi/$AML" "$E/ACPI/$AML"
if [ -n "$aidx" ]; then $PB -c "Set :ACPI:Add:$aidx:Enabled true" "$C"
else a=0; while $PB -c "Print :ACPI:Add:$a:Path" "$C" >/dev/null 2>&1; do a=$((a+1)); done
  $PB -c "Add :ACPI:Add:$a dict" -c "Add :ACPI:Add:$a:Comment string AC adapter _PSR replacement" -c "Add :ACPI:Add:$a:Enabled bool true" -c "Add :ACPI:Add:$a:Path string $AML" "$C"; fi
if [ -n "$pidx" ]; then $PB -c "Delete :ACPI:Patch:$pidx" "$C"; fi   # always rebuilt in full (a half-written entry from an aborted run must not survive)
p=0; while $PB -c "Print :ACPI:Patch:$p:Comment" "$C" >/dev/null 2>&1; do p=$((p+1)); done
  T=$(mktemp /private/var/tmp/acpsr.XXXX)
  cat > "$T" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Base</key><string></string><key>BaseSkip</key><integer>0</integer><key>Comment</key><string>$PCOMMENT</string>
<key>Count</key><integer>1</integer><key>Enabled</key><true/><key>Find</key><data>X1BTUgA=</data><key>Limit</key><integer>0</integer>
<key>Mask</key><data></data><key>OemTableId</key><data></data><key>Replace</key><data>WFBTUgA=</data><key>ReplaceMask</key><data></data>
<key>Skip</key><integer>0</integer><key>TableLength</key><integer>0</integer><key>TableSignature</key><data>RFNEVA==</data>
</dict></plist>
PL
  plutil -lint "$T" >/dev/null || { echo "STOP: patch plist invalid"; exit 1; }
  $PB -c "Add :ACPI:Patch:$p dict" "$C"; $PB -c "Merge $T :ACPI:Patch:$p" "$C"; rm -f "$T"
plutil -lint "$C" || { cp "$B/config.plist" "$C"; echo "STOP: config invalid, previous put back"; exit 1; }
echo "== ACPI/Patch:"; $PB -c 'Print :ACPI:Patch' "$C" | grep -E 'Comment|Enabled|Base ' | paste - - - | tail -3 | cat -v | sed 's/^ */   /'
sync; echo "== done. Reboot, then:  pmset -g ps   (expect 'AC Power')"
