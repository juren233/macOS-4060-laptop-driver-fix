#!/bin/bash
# Run with sudo. Puts back the unmodified NullMoth 1.0.10 package and the HiDPI list without scaled sizes,
# so no display mode in System Settings can reach the scaling path that hung the GPU.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
[ "$(id -u)" -eq 0 ] || { echo "STOP: run with sudo"; exit 1; }
O=/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-9e5
cp "$HERE/DisplayProductID-b40.safe" "$O/DisplayProductID-b40" && chown root:wheel "$O/DisplayProductID-b40" && chmod 644 "$O/DisplayProductID-b40"
cmp -s "$HERE/DisplayProductID-b40.safe" "$O/DisplayProductID-b40" && echo "safe HiDPI list installed"
rm -f /Library/LaunchDaemons/local.nvflip.plist && rm -rf "/Library/Application Support/nvflip" && echo "zero-copy LaunchDaemon removed"
/bin/bash "$HERE/../pkg/pkgroot/install.sh" || { echo "STOP: install.sh failed"; exit 1; }
echo; echo "DONE. Reboot now."
