#!/bin/zsh
# Experiment: change NullMoth NVENC H.264's built-in constant QP (default 23).
# The default lives in NVEncH264_CreateInstance: movabsq $0x3c00000017,%rax at file offset 0x8a7 (QP byte at 0x8a9).
#   sudo zsh uu-nvenc-qp.sh 38      # patch default QP to 38, ad-hoc re-sign, restart UU agent
#   sudo zsh uu-nvenc-qp.sh restore # put the original dylib back
set -e
[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }
B=/Library/GPUBundles/NVMTLDriver.bundle/Contents/MacOS/libnvenc_h264.dylib
ORIG=/Library/NullMoth/libnvenc_h264.dylib.orig
U=${SUDO_UID:-501}
# Replace a dylib with a NEW inode (copy beside it, then rename). Overwriting it in place while some process
# has it loaded leaves the kernel's cached code signature stale, and every process that loads it afterwards is
# SIGKILLed with "Code Signature Invalid" (UU dies, new Metal apps crash) until reboot.
put() { cp "$1" "$2.new.$$" && chmod 755 "$2.new.$$" && mv -f "$2.new.$$" "$2"; }
[[ -f $ORIG ]] || cp -p "$B" "$ORIG"
if [[ $1 == restore ]]; then
  put "$ORIG" "$B"
else
  QP=$1
  [[ $QP == <10-51> ]] || { echo "usage: $0 <QP 10..51>|restore"; exit 1; }
  [[ $(xxd -s 0x8a7 -l 2 -p "$ORIG") == 48b8 ]] || { echo "unexpected bytes at 0x8a7 - not patching"; exit 1; }
  T=$(mktemp /tmp/nvenc.XXXXXX)
  cp "$ORIG" "$T"
  printf "$(printf '\\x%02x' $QP)" | dd of="$T" bs=1 seek=$((0x8a9)) conv=notrunc 2>/dev/null
  codesign -f -s - "$T" 2>/dev/null
  put "$T" "$B"; rm -f "$T"
fi
xxd -s 0x8a7 -l 10 "$B"
zsh "${0:A:h}/uu-restart.sh"
