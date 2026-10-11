#!/bin/bash
# Run with sudo:  install-surface-fix.sh [min-pixels]   (default 3686400 = 2560x1440)
# Black Finder sidebar header / octagonal selection / black window corners: WindowServer renders its small layer caches into
# IOSurfaces, and NullMoth's driver backs every IOSurface with a shared *linear* VRAM image, which those renders come out
# wrong in. This installs the rebuilt plugin (plugin/surface-guard-diag.patch) and sets NVMTL_SURF_SHARE_MINPX so only
# framebuffer-sized surfaces (the zero-copy scan-out needs them) stay shared; smaller ones get private tiled images.
# Also puts back the NVENC-off block (UU remote) if it is missing. Reboot afterwards.
set -u
[ "$(id -u)" -eq 0 ] || { echo "STOP: run with sudo"; exit 1; }
D=$(cd "$(dirname "$0")" && pwd); CONF=/Library/GPUBundles/nvmtl/nvrm610.conf; MIN="${1:-3686400}"
cp -p "$CONF" "$CONF.bak-$(date +%Y%m%d-%H%M%S)"
grep -v '^NVMTL_SURF_SHARE_MINPX=' "$CONF" > "$CONF.new"; echo "NVMTL_SURF_SHARE_MINPX=$MIN" >> "$CONF.new"
grep -q '^# --- 1401 per-system rules ---$' "$CONF.new" || printf '%s\n' "# --- 1401 per-system rules ---" "NVMTL_NO_NVENC=1" "NVMTL_NO_NVENC_HEVC=1" "# --- end 1401 per-system rules ---" >> "$CONF.new"
chmod 644 "$CONF.new" && mv "$CONF.new" "$CONF" || { echo "STOP: could not write $CONF"; exit 1; }
echo "---- $CONF"; cat "$CONF"; echo "----"
"$D/install-plugin-fix.sh"
