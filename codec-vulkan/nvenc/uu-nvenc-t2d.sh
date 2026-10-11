#!/bin/zsh
# Install / remove the Ada (RTX 40) fix for NullMoth's NVENC H.264 encoder.
# Bug: nve264_encode writes luma in the Blackwell "bw8" block layout and chroma in "bw16", but the
# Ada NVENC engine (class 0xc9b7) reads both planes in the "t2d" GOB layout -> garbled picture.
# Measured on a test frame: original 12 dB luma / 12 dB chroma PSNR, patched 50.4 / 47.2 dB.
# Patched file (nvenc-patched/h264.final.dylib) = original +
#   - both copy loops rewritten to t2d (0x626a, 0x6399)
#   - NotSync fix (0x1665)
#   - buffer zeroing with AVX stores instead of bzero on the vidmem mapping (0x3939 -> 0x1d00): session start 2.6 s -> 0.1 s
#   - per-frame QP rate control from AverageBitRate (hooks 0x1691 / 0xdbb, code at 0x1d40, storage 0xa0 -> 0xb0)
#   - keyframe QP = frame QP instead of 0.8x (0x640e), default keyframe interval 60 -> 3600 (0x8ad)
# Sources: nvenc-patched/{luma.s,chroma.s,fz2.s,cave.s,rc.c}. HEVC is NOT fixed, so it stays disabled.
#   sudo zsh uu-nvenc-t2d.sh install   # patched H.264 NVENC on, HEVC NVENC off, restart UU
#   sudo zsh uu-nvenc-t2d.sh restore   # original encoder back, all NVENC off (software encode), restart UU
set -e
[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }
HERE=${0:A:h}
M=/Library/GPUBundles/NVMTLDriver.bundle/Contents/MacOS
K=/Library/NullMoth
CONF=/Library/GPUBundles/nvmtl/nvrm610.conf
U=${SUDO_UID:-501}
ORIG_SHA=164f6dfa409352e90b079659578a012dc37d1fba364067b99cb8c7bf337b1b5d
NEW_SHA=2b231d508b2d886afb8de51b950071b905fbd23d88c635bfda968a0855d28231
# Replace a dylib with a NEW inode (copy beside it, then rename). Overwriting it in place while some process
# has it loaded leaves the kernel's cached code signature stale, and every process that loads it afterwards is
# SIGKILLed with "Code Signature Invalid" (UU dies, new Metal apps crash) until reboot.
put() { cp "$1" "$2.new.$$" && chmod 755 "$2.new.$$" && mv -f "$2.new.$$" "$2"; }
[[ -f $K/libnvenc_h264.dylib.orig ]] || cp -p $M/libnvenc_h264.dylib $K/libnvenc_h264.dylib.orig
case "$1" in
  install)
    [[ $(shasum -a 256 $K/libnvenc_h264.dylib.orig | cut -d' ' -f1) == $ORIG_SHA ]] || { echo "original encoder is not the expected build - not installing"; exit 1; }
    [[ $(shasum -a 256 $HERE/nvenc-patched/h264.final.dylib | cut -d' ' -f1) == $NEW_SHA ]] || { echo "patched file checksum mismatch"; exit 1; }
    put $HERE/nvenc-patched/h264.final.dylib $M/libnvenc_h264.dylib
    cp -p "$CONF" "$CONF.bak-$(date +%Y%m%d-%H%M%S)"
    sed -i '' '/^# --- 1401 per-system rules ---$/,/^# --- end 1401 per-system rules ---$/d' "$CONF"
    { echo "# --- 1401 per-system rules ---"; echo "NVMTL_NO_NVENC_HEVC=1"; echo "# --- end 1401 per-system rules ---"; } >> "$CONF"
    echo "patched H.264 NVENC installed and enabled; HEVC NVENC stays off" ;;
  restore)
    put $K/libnvenc_h264.dylib.orig $M/libnvenc_h264.dylib
    zsh "$HERE/uu-nvenc-toggle.sh" off >/dev/null
    echo "original encoder restored, NVENC off (software encode)" ;;
  *) echo "usage: $0 install|restore"; exit 1 ;;
esac
shasum -a 256 $M/libnvenc_h264.dylib; grep -n NVENC "$CONF" || true
zsh "${0:A:h}/uu-restart.sh"
