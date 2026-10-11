#!/bin/bash
# Add or remove one boot-arg in the ESP's OpenCore config.plist (NVRAM/Add/7C436110-.../boot-args). Run as root:
#   sudo bash oc-bootarg.sh add itlwm_he=1
#   sudo bash oc-bootarg.sh remove itlwm_he=1
# Backs up config.plist to backup/bootarg-<ts> first; mtools only (works in safe mode too).
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
die() { echo "STOP: $*"; exit 1; }
[ "$(id -u)" -eq 0 ] || die "run with sudo"
ACT=${1:-}; ARG=${2:-}
{ [ "$ACT" = add ] || [ "$ACT" = remove ]; } && [ -n "$ARG" ] || die "usage: oc-bootarg.sh add|remove <arg>"
DEV=${ESP_DEV:?set ESP_DEV to your OpenCore ESP, e.g. disk1s4 (see: diskutil list)}; export PATH=/usr/local/bin:$PATH MTOOLS_SKIP_CHECK=1; I=(-i /dev/$DEV)
[ "$(diskutil info $DEV | awk -F': *' '/Partition UUID/{print $2}')" = ${ESP_UUID:?set ESP_UUID to the Partition UUID of that ESP (diskutil info $ESP_DEV)} ] || die "$DEV is not the expected ESP"
diskutil unmount $DEV >/dev/null 2>&1 || true
PB=/usr/libexec/PlistBuddy; K=":NVRAM:Add:7C436110-AB2A-4BBB-A880-FE41995C9F82:boot-args"
T=$(mktemp -d /var/tmp/bootarg.XXXX)
BK="$HERE/backup/bootarg-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$BK"
mcopy "${I[@]}" -n ::/EFI/OC/config.plist "$BK/config.plist" && plutil -lint "$BK/config.plist" >/dev/null || die "config backup failed"
C="$T/config.plist"; cp "$BK/config.plist" "$C"
OLD=$($PB -c "Print $K" "$C") || die "no boot-args in config"
key=${ARG%%=*}
NEW=$(for a in $OLD; do [ "${a%%=*}" = "$key" ] || printf '%s ' "$a"; done)
[ "$ACT" = add ] && NEW="$NEW$ARG"
NEW=$(echo $NEW)
[ "$NEW" = "$OLD" ] && { echo "boot-args unchanged: $OLD"; rm -rf "$T" "$BK"; exit 0; }
$PB -c "Set $K $NEW" "$C" && plutil -lint "$C" >/dev/null || die "config edit failed (ESP untouched)"
mcopy "${I[@]}" -o -n "$C" ::/EFI/OC/config.plist || die "config write failed: restore $BK/config.plist"
sync
mcopy "${I[@]}" -n ::/EFI/OC/config.plist "$T/rb.plist" && cmp -s "$C" "$T/rb.plist" || die "read-back differs: restore $BK/config.plist"
rm -rf "$T"
echo "boot-args: $OLD"
echo "        -> $NEW"
echo "(backup $BK) Reboot normally."
