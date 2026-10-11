#!/bin/zsh
# Install / remove the sandbox fix for NullMoth's Vulkan driver (libvulkan_nouveau.dylib).
# Bug: nvrm_xnu_open() takes a placeholder fd with open("/dev/null", O_RDWR) for every NVRM connection. Sandboxes that
# only let a process READ /dev/null - Chrome's / Electron's GPU process - refuse it, so every NVRM connection opened after
# the sandbox is up fails: vkCreateGraphicsPipelines fails, ANGLE's Metal display cannot initialise, the GPU process exits
# and Chromium falls back to software compositing (whole windows re-uploaded by WindowServer every frame -> stutter).
# The fd is only a key into the connection table (mapping and calls go through IOKit), so read-only is enough.
# Patch 1: 2 bytes, movl $0x1000002 -> $0x1000000 (O_RDWR|O_CLOEXEC -> O_RDONLY|O_CLOEXEC) at 0x12bfc8 and 0x12c0db.
# Bug 2: Mesa's os_get_total_physical_memory = sysconf(_SC_PHYS_PAGES) * sysconf(_SC_PAGESIZE); the GPU sandbox denies
# sysctl hw.pagesize, _SC_PHYS_PAGES returns -1 and NVK refuses the device ("Failed to query total system memory").
# Patch 2: that function (0x406f10, 70 of its 80 bytes) rewritten as sysctlbyname("hw.memsize") (allowed). Re-signed ad hoc.
# Tested (sandbox_init before the device, denying /dev/null writes + hw.pagesize): stock NO DEVICE / pipeline FAILED,
# patched draws correctly; unsandboxed unchanged.
#   sudo zsh vk-devnull.sh install|restore
set -e
[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }
HERE=${0:A:h}
V=/Library/GPUBundles/nvmtl/libvulkan_nouveau.dylib
K=/Library/NullMoth
ORIG_SHA=bd879ca71229b690a26392fd52d569703febe3dcf9e7b63a8100bd2c872057ec
NEW_SHA=864c2931c3634998ecca4ad2493539f1158b4e9d2a4e88df889c86f2fff99ee6
# New inode (copy beside, then rename): overwriting a loaded dylib in place -> "Code Signature Invalid" SIGKILLs.
put() { cp "$1" "$2.new.$$" && chown root:wheel "$2.new.$$" && chmod 755 "$2.new.$$" && mv -f "$2.new.$$" "$2"; }
[[ -f $K/libvulkan_nouveau.dylib.orig ]] || cp -p $V $K/libvulkan_nouveau.dylib.orig
case "$1" in
  install)
    [[ $(shasum -a 256 $K/libvulkan_nouveau.dylib.orig | cut -d' ' -f1) == $ORIG_SHA ]] || { echo "original Vulkan driver is not the expected build - not installing"; exit 1; }
    [[ $(shasum -a 256 $HERE/vk-patched/vk.sandbox.dylib | cut -d' ' -f1) == $NEW_SHA ]] || { echo "patched file checksum mismatch"; exit 1; }
    put $HERE/vk-patched/vk.sandbox.dylib $V
    echo "patched Vulkan driver installed (read-only /dev/null placeholder fds, memory size via hw.memsize)" ;;
  restore)
    put $K/libvulkan_nouveau.dylib.orig $V
    echo "original Vulkan driver restored" ;;
  *) echo "usage: $0 install|restore"; exit 1 ;;
esac
shasum -a 256 $V
echo "done - running processes keep the old copy until they restart (WindowServer: until the next reboot)"
