#!/bin/zsh
# Install / remove the "unbind pooled connection" fix for NullMoth's Vulkan driver (libvulkan_nouveau.dylib).
# Bug: nvrm_xnu_close() puts a connection back into its pool but leaves it registered in the kernel under the fd number
# it had. The fd itself is closed, the number is handed out again, and a second connection registers under the same number.
# The kernel then finds the OLD connection for that number (first match), puts the mapping context on it, and the mmap on the
# new connection finds none: IOConnectMapMemory64 -> kIOReturnBadArgument, then every further map on that number fails with
# NV_ERR_STATE_IN_USE (0x63) until the old connection is reused. Vulkan reports it as VK_ERROR_OUT_OF_DEVICE_MEMORY, which
# is what killed Chrome's GPU process (pipeline creation failed, readback failed, context lost -> restart) and left
# window surfaces unpublished.
# Patch: before the pool_put, send SEL_BINDFD(-2) (the unbind the "mappings still live" branch already sends). Built on
# top of vk.sandbox.dylib (864c2931) by vk-patched/mk-bindfix.py: 8 bytes at 0x12cc3c hook a 48-byte routine placed over the
# (unused) "PENDING-CLOSE TABLE FULL" message. Re-signed ad hoc.
#   sudo zsh vk-bindfix.sh install|restore
set -e
[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }
HERE=${0:A:h}
V=/Library/GPUBundles/nvmtl/libvulkan_nouveau.dylib
SANDBOX_SHA=864c2931c3634998ecca4ad2493539f1158b4e9d2a4e88df889c86f2fff99ee6
NEW_SHA=4d9ceab1c4ae7c752c9b2f8c1eaa6302de70b337aee24cc2270e550137ac0d75
put() { cp "$1" "$2.new.$$" && chown root:wheel "$2.new.$$" && chmod 755 "$2.new.$$" && mv -f "$2.new.$$" "$2"; }
case "$1" in
  install)
    cur=$(shasum -a 256 $V | cut -d' ' -f1)
    [[ $cur == $SANDBOX_SHA || $cur == $NEW_SHA ]] || { echo "installed Vulkan driver is neither the sandbox build nor this one (${cur[1,8]}) - not installing"; exit 1; }
    [[ $(shasum -a 256 $HERE/vk-patched/vk.bindfix.dylib | cut -d' ' -f1) == $NEW_SHA ]] || { echo "patched file checksum mismatch"; exit 1; }
    put $HERE/vk-patched/vk.bindfix.dylib $V
    echo "Vulkan driver with the pooled-connection unbind fix installed" ;;
  restore)
    [[ $(shasum -a 256 $HERE/vk-patched/vk.sandbox.dylib | cut -d' ' -f1) == $SANDBOX_SHA ]] || { echo "sandbox build checksum mismatch"; exit 1; }
    put $HERE/vk-patched/vk.sandbox.dylib $V
    echo "previous (sandbox-fix) Vulkan driver restored" ;;
  *) echo "usage: $0 install|restore"; exit 1 ;;
esac
shasum -a 256 $V
echo "done - Chrome / Electron pick it up when restarted (WindowServer: after the next reboot)"
