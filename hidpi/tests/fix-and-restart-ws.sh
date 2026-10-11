#!/bin/bash
HERE=$(cd "$(dirname "$0")" && pwd)
O=/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-9e5
cp "$HERE/DisplayProductID-b40" "$O/DisplayProductID-b40" && chown root:wheel "$O/DisplayProductID-b40" && chmod 644 "$O/DisplayProductID-b40"
sysctl -w debug.nvaccel_iop=1
sleep 1
killall -9 WindowServer
