#!/bin/bash
# Run with sudo. Installs the NullMoth package whose NVRM.kext scales with the head (postcomp) scaler:
# KAPI sets ViewPortIn to the primary layer's source size and the layer's sizeOut to that same size,
# so the window is never scaled and the head scales ViewPortIn -> raster. Stock NVRM otherwise.
# Also installs the HiDPI display override with the scaled "looks like" sizes. install.sh backs up the previous driver.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
[ "$(id -u)" -eq 0 ] || { echo "STOP: run with sudo"; exit 1; }
/bin/bash "$HERE/../pkg-hs/install.sh" || { echo "STOP: install.sh failed (it restores the previous driver itself)"; exit 1; }
O=/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-9e5
mkdir -p "$O" && cp "$HERE/DisplayProductID-b40.scaled" "$O/DisplayProductID-b40" && chown root:wheel "$O/DisplayProductID-b40" && chmod 644 "$O/DisplayProductID-b40"
cmp -s "$HERE/DisplayProductID-b40.scaled" "$O/DisplayProductID-b40" && echo "scaled HiDPI override installed"
echo; echo "DONE. Reboot now, and do not change the resolution in System Settings until the probe has run."
