#!/bin/bash
# Run with sudo. Installs the HiDPI setup:
#  - pkg-hs: NVRM scales with the head (postcomp) scaler; NVRMFB rebuilt from source with the zero-copy surface cache
#    evicting instead of leaking an NVKMS surface per flip once it holds 16 entries, and purged on every mode switch.
#  - the HiDPI override without "looks like 1920x1080" (refused by IMP at 165 Hz).
#  - LaunchDaemon local.nvflip: turns zero-copy scanout on 60 s after the display pipe arms (-nvrmnoflip stays in boot-args).
# install.sh backs up the previous driver. Undo everything with revert-to-stock.sh.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
[ "$(id -u)" -eq 0 ] || { echo "STOP: run with sudo"; exit 1; }
/bin/bash "$HERE/../pkg-hs/install.sh" || { echo "STOP: install.sh failed (it restores the previous driver itself)"; exit 1; }
O=/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-9e5
mkdir -p "$O" && cp "$HERE/DisplayProductID-b40.final" "$O/DisplayProductID-b40" && chown root:wheel "$O/DisplayProductID-b40" && chmod 644 "$O/DisplayProductID-b40"
cmp -s "$HERE/DisplayProductID-b40.final" "$O/DisplayProductID-b40" && echo "HiDPI override installed (largest: looks like 1792x1008)"
D="/Library/Application Support/nvflip"
mkdir -p "$D" && cp "$HERE/nvflip/nvflip.sh" "$D/nvflip.sh" && chown -R root:wheel "$D" && chmod 755 "$D/nvflip.sh"
cp "$HERE/nvflip/local.nvflip.plist" /Library/LaunchDaemons/local.nvflip.plist && chown root:wheel /Library/LaunchDaemons/local.nvflip.plist && chmod 644 /Library/LaunchDaemons/local.nvflip.plist
plutil -lint /Library/LaunchDaemons/local.nvflip.plist >/dev/null && echo "zero-copy LaunchDaemon installed (log: /var/log/nvflip.log)"
echo; echo "DONE. Reboot now. After the reboot pick the size in System Settings > Displays, then reboot once more so every app starts at it."
