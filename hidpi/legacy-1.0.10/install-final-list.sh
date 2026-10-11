#!/bin/bash
# Run with sudo. Replaces the probe HiDPI list with the final one: largest "looks like" 1792x1008, the biggest size
# the head scaler accepts at 165 Hz (1824x1026 and up are refused by IMP). Takes effect after a reboot.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
[ "$(id -u)" -eq 0 ] || { echo "STOP: run with sudo"; exit 1; }
O=/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-9e5
cp "$HERE/DisplayProductID-b40.final" "$O/DisplayProductID-b40" && chown root:wheel "$O/DisplayProductID-b40" && chmod 644 "$O/DisplayProductID-b40"
cmp -s "$HERE/DisplayProductID-b40.final" "$O/DisplayProductID-b40" && echo "final HiDPI list installed (largest: looks like 1792x1008). Reboot now."
