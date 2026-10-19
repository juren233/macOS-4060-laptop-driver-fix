#!/bin/bash
# Restore the BTLEFix.kext staged before install-v6.sh and remove -btlfxoff.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
WIFIBT=$(cd "$HERE/.." && pwd)
STAGE="$WIFIBT/kexts/BTLEFix.kext"
LAST="$HERE/backup/last-v6-install.txt"
BACKUP=${1:-}

die() { echo "STOP: $*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "run with sudo"
if [ -z "$BACKUP" ] && [ -f "$LAST" ]; then
	BACKUP=$(sed -n 's/^backup=//p' "$LAST" | head -1)
fi
[ -n "$BACKUP" ] && [ -d "$BACKUP" ] || die "usage: sudo bash $0 <BTLEFix-v5-backup-dir>"
[ -f "$BACKUP/Contents/MacOS/BTLEFix" ] || die "backup has no BTLEFix binary"

TS=$(date +%Y%m%d-%H%M%S)
mkdir -p "$HERE/backup"
cp -R "$STAGE" "$HERE/backup/BTLEFix-before-rollback-$TS"
echo "== local pre-rollback copy: $HERE/backup/BTLEFix-before-rollback-$TS"

bash "$WIFIBT/oc-bootarg.sh" remove -btlfxoff
rm -rf "$STAGE"
cp -R "$BACKUP" "$STAGE"
bash "$WIFIBT/safe-replace-btlefix.sh"
find_efiguard() {
	for candidate in "$HERE/../../../efiguard/install.sh" "$HOME/work/system/efiguard/install.sh"; do
		[ -f "$candidate" ] && { echo "$candidate"; return 0; }
	done
	if [ -n "${SUDO_USER:-}" ]; then
		local uhome
		uhome=$(eval echo "~$SUDO_USER")
		[ -f "$uhome/work/system/efiguard/install.sh" ] && { echo "$uhome/work/system/efiguard/install.sh"; return 0; }
	fi
	return 1
}
EFIGUARD=${EFIGUARD:-$(find_efiguard || true)}
[ -f "$EFIGUARD" ] || die "cannot find $EFIGUARD"
zsh "$EFIGUARD"

echo "Rollback staged. Reboot to load the previous BTLEFix.kext."
