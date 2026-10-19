#!/bin/bash
# Install the already built v6 kext and disable BlueToolFixup's in-place page patches.
# This is intentionally separate from the build: it changes the OpenCore ESP and needs sudo.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
WIFIBT=$(cd "$HERE/.." && pwd)
BUILD="$HERE/build/BTLEFix.kext"
STAGE="$WIFIBT/kexts/BTLEFix.kext"
TS=$(date +%Y%m%d-%H%M%S)
BACKUP="$HERE/backup/BTLEFix-before-v6-$TS"
LAST="$HERE/backup/last-v6-install.txt"
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

die() { echo "STOP: $*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "run with sudo"
[ -f "$BUILD/Contents/MacOS/BTLEFix" ] || die "missing $BUILD; run ./build.sh first"
[ -f "$HERE/verify_private_patch.py" ] || die "missing offline checker"

echo "== offline patch-site check"
python3 "$HERE/verify_private_patch.py" /usr/sbin/bluetoothd >/dev/null
python3 "$HERE/verify_private_patch.py" /usr/sbin/BlueTool >/dev/null
echo "   ok"

echo
echo "This will modify the OpenCore ESP, disable BlueToolFixup with -btlfxoff,"
echo "and refresh the efiguard snapshot. It will NOT reboot."
printf "Type install to continue: "
read -r answer
[ "$answer" = install ] || die "not confirmed"

mkdir -p "$HERE/backup"
if [ -d "$STAGE" ]; then
	cp -R "$STAGE" "$BACKUP"
	echo "== local rollback backup: $BACKUP"
else
	die "missing current staging kext $STAGE"
fi

echo "== disable BlueToolFixup's in-place patches"
bash "$WIFIBT/oc-bootarg.sh" add -btlfxoff

echo "== stage v6 kext"
rm -rf "$STAGE"
cp -R "$BUILD" "$STAGE"
shasum -a 256 "$STAGE/Contents/MacOS/BTLEFix"

echo "== replace BTLEFix.kext on the ESP"
bash "$WIFIBT/safe-replace-btlefix.sh"

echo "== refresh the efiguard snapshot"
[ -f "$EFIGUARD" ] || die "cannot find $EFIGUARD"
zsh "$EFIGUARD"

# Reinstalling a v6 build must not move the default rollback target off the
# original pre-v6 kext. Keep the first recorded backup and use an explicit
# directory with rollback-v6.sh if a v6-to-v6 rollback is ever needed.
ROLLBACK_BACKUP=$BACKUP
if [ -f "$LAST" ]; then
	previous=$(sed -n 's/^backup=//p' "$LAST" | head -1)
	if [ -n "$previous" ] && [ -d "$previous" ]; then
		ROLLBACK_BACKUP=$previous
		echo "== keep original rollback backup: $ROLLBACK_BACKUP"
	fi
fi

cat > "$LAST" <<EOF
backup=$ROLLBACK_BACKUP
installed=$TS
kext_sha256=$(shasum -a 256 "$STAGE/Contents/MacOS/BTLEFix" | awk '{print $1}')
EOF

echo
echo "Installed, but not rebooted. The old UBC pages must be cleared by a reboot."
echo "After reboot run:"
echo "  sudo bash $HERE/check-v6.sh"
echo "Rollback:"
echo "  sudo bash $HERE/rollback-v6.sh"
