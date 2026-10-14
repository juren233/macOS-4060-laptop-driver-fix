#!/bin/zsh
# Install / remove ZCULL (hierarchical Z) for NullMoth 1.15.0's Vulkan driver (libvulkan_nouveau.dylib, stock sha256 403d4d40...).
# Mesa 26.x NVK already carries upstream zcull, but the NullMoth NVRM backend hard-codes has_zcull_info = false, so the GPU never
# culled hidden fragments before shading. That hurts every fragment shader that writes sample_mask, which includes all of ANGLE's MSAA
# WebGL in Chrome: those shaders get late Z. mk-zcull-115.py turns it on: a cave fills the info from NV2080_CTRL_CMD_GR_GET_ZCULL_INFO.
# Results on the author's machine:
#   catest/earlyz occluded sample-mask pass   2.98 -> 0.06 ms
#   three.js chess main pass                  4.4 -> 2.4 ms
#   whole frame                               11.6 -> 7.2 ms GPU
# Off switch without uninstalling: ZCULL_RGN=0 in /Library/GPUBundles/nvmtl/nvrm610.conf (restart the app).
# The patched file is generated here from YOUR installed stock driver: no binary is shipped. Ad-hoc signed under its own file name,
# it is byte-identical to the author's build (sha256 c866c85d...).
#   sudo zsh vk-zcull.sh install|restore
set -e
[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }
HERE=${0:A:h}
V=/Library/GPUBundles/nvmtl/libvulkan_nouveau.dylib
B=/Library/NullMoth/vk-zcull-backup
STOCK_SHA=403d4d40ff7b53d2d3ee72b4dd8b0e3ec0a4db5def34570ac098b32b18836ddb
NEW_SHA=c866c85d695d21c8497f14e9672f6beac97172d86df7c77473b344bbaad5bdf2
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
put() { cp "$1" "$2.new.$$" && chown root:wheel "$2.new.$$" && chmod 755 "$2.new.$$" && mv -f "$2.new.$$" "$2"; }
case "$1" in
  install)
    cur=$(sha $V)
    [[ $cur == $NEW_SHA ]] && { echo "ZCULL build already installed"; exit 0; }
    [[ $cur == $STOCK_SHA ]] || { echo "installed Vulkan driver is not stock NullMoth 1.15.0 (${cur[1,8]}) - not installing"; exit 1; }
    T=$(mktemp -d /private/tmp/vk-zcull.XXXXXX); trap 'rm -rf $T' EXIT
    /usr/bin/python3 -I $HERE/mk-zcull-115.py $V $T/libvulkan_nouveau.dylib
    codesign -f -s - $T/libvulkan_nouveau.dylib 2>/dev/null
    [[ $(sha $T/libvulkan_nouveau.dylib) == $NEW_SHA ]] || { echo "patched file is not the expected build - not installing"; exit 1; }
    mkdir -p $B && cp -p $V $B/libvulkan_nouveau.$STOCK_SHA[1,8].dylib
    put $T/libvulkan_nouveau.dylib $V
    echo "Vulkan driver with ZCULL installed (backup: $B). Restart apps, or reboot for WindowServer." ;;
  restore)
    [[ $(sha $B/libvulkan_nouveau.$STOCK_SHA[1,8].dylib) == $STOCK_SHA ]] || { echo "no valid backup in $B"; exit 1; }
    put $B/libvulkan_nouveau.$STOCK_SHA[1,8].dylib $V
    echo "stock Vulkan driver restored. Restart apps, or reboot for WindowServer." ;;
  *) echo "usage: sudo zsh vk-zcull.sh install|restore"; exit 2 ;;
esac
