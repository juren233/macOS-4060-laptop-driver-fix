#!/bin/bash
# read-only: show ACPI/Add + ACPI/Patch of the live OpenCore config and the SSDT files on the ESP
PB=/usr/libexec/PlistBuddy
ESPUUID=${ESP_UUID:?set ESP_UUID to the Partition UUID of your OpenCore ESP (diskutil info <disk>)}
DEV=; for d in $(diskutil list | awk '/ EFI /{print $NF}'); do [ "$(diskutil info $d | awk -F': *' '/Partition UUID/{print $2}')" = $ESPUUID ] && { DEV=$d; break; }; done   # disk numbers occasionally change (NVMe probe order): find the ESP by UUID
[ -n "$DEV" ] || { echo "STOP: ESP (partition UUID $ESPUUID) not found"; exit 1; }
diskutil mount $DEV >/dev/null; M=$(diskutil info $DEV | awk -F': +' '/Mount Point/{print $2}')
C="$M/EFI/OC/config.plist"
echo "== ACPI/Add"; i=0; while p=$($PB -c "Print :ACPI:Add:$i:Path" "$C" 2>/dev/null); do printf '%2d %-34s enabled=%s  %s\n' $i "$p" "$($PB -c "Print :ACPI:Add:$i:Enabled" "$C")" "$($PB -c "Print :ACPI:Add:$i:Comment" "$C" 2>/dev/null)"; i=$((i+1)); done
echo "== ACPI/Patch"; i=0; while c=$($PB -c "Print :ACPI:Patch:$i:Comment" "$C" 2>/dev/null); do printf '%2d %s | enabled=%s count=%s\n' $i "$c" "$($PB -c "Print :ACPI:Patch:$i:Enabled" "$C")" "$($PB -c "Print :ACPI:Patch:$i:Count" "$C")"; i=$((i+1)); done
echo "== files"; ls -l "$M/EFI/OC/ACPI" | cat -v
diskutil unmount $DEV >/dev/null
