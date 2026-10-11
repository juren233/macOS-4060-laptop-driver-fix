#!/bin/bash
# Run with sudo. Adds "looks like" 1888x1062 / 1856x1044 / 1840x1035 / 1824x1026 / 1792x1008 to the HiDPI list
# so probe-scaled.sh can find the largest one the head scaler accepts at 165 Hz, then restarts WindowServer
# (you get the login screen) so the new list is read.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
[ "$(id -u)" -eq 0 ] || { echo "STOP: run with sudo"; exit 1; }
O=/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-9e5
cp "$HERE/DisplayProductID-b40.probe" "$O/DisplayProductID-b40" && chown root:wheel "$O/DisplayProductID-b40" && chmod 644 "$O/DisplayProductID-b40"
cmp -s "$HERE/DisplayProductID-b40.probe" "$O/DisplayProductID-b40" || { echo "STOP: copy failed"; exit 1; }
echo "probe HiDPI list installed; restarting WindowServer in 3 s"
sleep 3; killall -9 WindowServer
