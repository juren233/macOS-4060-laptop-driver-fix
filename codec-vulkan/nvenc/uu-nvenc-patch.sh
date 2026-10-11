#!/bin/zsh
# Install / remove the NotSync fix for NullMoth's NVENC encoders.
# Bug: on keyframes the encoders set kCMSampleAttachmentKey_NotSync = false. WebRTC-based apps (UU远程)
# test only whether that key EXISTS, so every frame looks like a delta frame and the receiver never
# starts. Patch (10 bytes, H.264 @0x1665, HEVC @0x175c): skip that CFDictionarySetValue on keyframes,
# which is what Apple's encoders do.
#   sudo zsh uu-nvenc-patch.sh install   # install patched encoders + enable NVENC + restart UU
#   sudo zsh uu-nvenc-patch.sh restore   # put the original encoders back
set -e
[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }
HERE=${0:A:h}
M=/Library/GPUBundles/NVMTLDriver.bundle/Contents/MacOS
K=/Library/NullMoth
U=${SUDO_UID:-501}
# Replace a dylib with a NEW inode (copy beside it, then rename). Overwriting it in place while some process
# has it loaded leaves the kernel's cached code signature stale, and every process that loads it afterwards is
# SIGKILLed with "Code Signature Invalid" (UU dies, new Metal apps crash) until reboot.
put() { cp "$1" "$2.new.$$" && chmod 755 "$2.new.$$" && mv -f "$2.new.$$" "$2"; }
[[ -f $K/libnvenc_h264.dylib.orig ]] || cp -p $M/libnvenc_h264.dylib $K/libnvenc_h264.dylib.orig
[[ -f $K/libnvenc_hevc.dylib.orig ]] || cp -p $M/libnvenc_hevc.dylib $K/libnvenc_hevc.dylib.orig
case "$1" in
  install)
    [[ $(xxd -s 0x1665 -l 10 -p $K/libnvenc_h264.dylib.orig) == 4c89fa490f44d44889df ]] || { echo "h264 original is not the expected build - not patching"; exit 1; }
    [[ $(xxd -s 0x175c -l 10 -p $K/libnvenc_hevc.dylib.orig) == 4c89fa490f44d44889df ]] || { echo "hevc original is not the expected build - not patching"; exit 1; }
    for c in h264 hevc; do
      off=$([[ $c == h264 ]] && echo $((0x1665)) || echo $((0x175c)))
      T=$(mktemp /tmp/nvenc.XXXXXX); cp $K/libnvenc_$c.dylib.orig $T
      printf '\x4c\x89\xe2\x48\x89\xdf\x75\x07\x90\x90' | dd of=$T bs=1 seek=$off conv=notrunc 2>/dev/null
      codesign -f -s - $T 2>/dev/null
      put $T $M/libnvenc_$c.dylib; rm -f $T
    done
    zsh "$HERE/uu-nvenc-toggle.sh" on >/dev/null
    echo "patched encoders installed, NVENC enabled" ;;
  restore)
    put $K/libnvenc_h264.dylib.orig $M/libnvenc_h264.dylib
    put $K/libnvenc_hevc.dylib.orig $M/libnvenc_hevc.dylib
    echo "original encoders restored (NVENC on/off unchanged; use uu-nvenc-toggle.sh)" ;;
  *) echo "usage: $0 install|restore"; exit 1 ;;
esac
xxd -s 0x1665 -l 10 $M/libnvenc_h264.dylib; xxd -s 0x175c -l 10 $M/libnvenc_hevc.dylib
zsh "${0:A:h}/uu-restart.sh"
