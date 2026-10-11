#!/bin/bash
# Run with sudo. install-final.sh (fixed NVRMFB + zero-copy LaunchDaemon) but with the probe HiDPI list
# (1888x1062 .. 1792x1008 added), so the largest size the head scaler accepts at 165 Hz can be found after one reboot.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
[ "$(id -u)" -eq 0 ] || { echo "STOP: run with sudo"; exit 1; }
/bin/bash "$HERE/install-final.sh" || exit 1
O=/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-9e5
cp "$HERE/DisplayProductID-b40.probe" "$O/DisplayProductID-b40" && chown root:wheel "$O/DisplayProductID-b40" && chmod 644 "$O/DisplayProductID-b40"
cmp -s "$HERE/DisplayProductID-b40.probe" "$O/DisplayProductID-b40" && echo "probe HiDPI list installed (replaces the final one for now)"
echo; echo "DONE. Reboot now."
