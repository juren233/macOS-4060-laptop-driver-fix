#!/bin/bash
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
O=/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-9e5
mkdir -p "$O"
cp "$HERE/DisplayProductID-b40" "$O/DisplayProductID-b40"
chown root:wheel "$O/DisplayProductID-b40"; chmod 644 "$O/DisplayProductID-b40"
defaults write /Library/Preferences/com.apple.windowserver DisplayResolutionEnabled -bool true
cmp "$HERE/DisplayProductID-b40" "$O/DisplayProductID-b40" && echo "override installed"
