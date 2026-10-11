#!/bin/zsh
# Install / remove the Ada (RTX 40) fix for NullMoth's NVDEC H.264 decoder (striped / blocky video in
# App Store, Safari, QuickTime... — anything that decodes H.264 through VideoToolbox).
# Bug: emit_picture calls nvd264_detile(mode=1) = Blackwell layout (luma bw8, chroma bw16), but the Ada
# NVDEC engine writes the picture in the "t2d" GOB layout (mode 0) -> 16-px vertical stripes.
# Patch: 1 byte at 0x163e (mov $1,%edx -> mov $0,%edx), re-signed ad hoc.
# Measured with nvdec-patched/dectest vs Apple's software decoder: stock 17.5 dB luma / 26.1 dB chroma,
# patched bit-exact at 854x480, 1280x720, 1920x1080, 3840x2160. HEVC decoder already uses t2d (bit-exact) - untouched.
#   sudo zsh nvdec-t2d.sh install|restore
set -e
[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }
HERE=${0:A:h}
M=/Library/GPUBundles/NVMTLDriver.bundle/Contents/MacOS
K=/Library/NullMoth
ORIG_SHA=ebf782888d4663955f6d7ce04dc158b7b5cfb78f48651450305b3e56abf88d15
NEW_SHA=1b5d08ba7cb95804e076d0be30c994bc15121ec4c4345f587dc45e34adffe1bf
# New inode (copy beside, then rename): overwriting a loaded dylib in place -> "Code Signature Invalid" SIGKILLs.
put() { cp "$1" "$2.new.$$" && chmod 755 "$2.new.$$" && mv -f "$2.new.$$" "$2"; }
[[ -f $K/libnvdec_h264.dylib.orig ]] || cp -p $M/libnvdec_h264.dylib $K/libnvdec_h264.dylib.orig
case "$1" in
  install)
    [[ $(shasum -a 256 $K/libnvdec_h264.dylib.orig | cut -d' ' -f1) == $ORIG_SHA ]] || { echo "original decoder is not the expected build - not installing"; exit 1; }
    [[ $(shasum -a 256 $HERE/nvdec-patched/h264.t2d.dylib | cut -d' ' -f1) == $NEW_SHA ]] || { echo "patched file checksum mismatch"; exit 1; }
    put $HERE/nvdec-patched/h264.t2d.dylib $M/libnvdec_h264.dylib
    echo "patched H.264 NVDEC installed" ;;
  restore)
    put $K/libnvdec_h264.dylib.orig $M/libnvdec_h264.dylib
    echo "original H.264 NVDEC restored" ;;
  *) echo "usage: $0 install|restore"; exit 1 ;;
esac
shasum -a 256 $M/libnvdec_h264.dylib
# VTDecoderXPCService instances keep the old copy mapped; kill them so the next video loads the new file.
killall VTDecoderXPCService 2>/dev/null || true
echo "done - quit and reopen apps that were playing video (App Store, Safari...)"
