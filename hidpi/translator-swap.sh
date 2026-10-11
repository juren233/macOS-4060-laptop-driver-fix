#!/bin/zsh
# Swap the installed shader translator (libnvmtl_translate.dylib) for another build WITHOUT touching running processes:
# copy beside, then rename (a loaded dylib overwritten in place gets its users SIGKILLed for an invalid code signature).
# Running apps keep the old translator until they restart; new processes load the new one. The previous file is kept in
# backup/, the new one is self-tested in a fresh process and rolled back if a test fails.
# usage: sudo zsh translator-swap.sh [dylib]     (default: plugin/libnvmtl_translate.dylib)
set -u
[[ $(id -u) == 0 ]] || { echo "run with sudo"; exit 1; }
HERE=${0:A:h}; SRC=${1:-$HERE/plugin/libnvmtl_translate.dylib}; M=/Library/GPUBundles/NVMTLDriver.bundle/Contents/MacOS
U=${SUDO_USER:-$(stat -f %Su /dev/console)}
[[ -f $SRC ]] || { echo "no such file: $SRC"; exit 1; }
swap() { cp "$1" "$M/libnvmtl_translate.dylib.new.$$" && chown root:wheel "$M/libnvmtl_translate.dylib.new.$$" &&
         chmod 755 "$M/libnvmtl_translate.dylib.new.$$" && mv -f "$M/libnvmtl_translate.dylib.new.$$" "$M/libnvmtl_translate.dylib"; }
OLD=$(shasum -a256 $M/libnvmtl_translate.dylib | cut -c1-8); BK=$HERE/backup/libnvmtl_translate.dylib.$OLD
mkdir -p $HERE/backup; [[ -f $BK ]] || cp $M/libnvmtl_translate.dylib $BK || { echo "STOP: backup failed"; exit 1; }
echo "before: $OLD (backup $BK)"
swap "$SRC" || { echo "STOP: copy failed"; exit 1; }
echo "after:  $(shasum -a256 $M/libnvmtl_translate.dylib | cut -c1-8)  ($SRC)"
t() { launchctl asuser "$(id -u "$U")" sudo -u "$U" "$@" 2>/dev/null | tail -1; }
T1=$(t $HERE/catest/cikl); T2=$(t $HERE/catest/nsamp); T3=$(t $HERE/catest/gfx2 6); T4=$(t $HERE/catest/mipt)
echo "self-test: Core Image Lanczos + CIKL kernels, GPU vs CPU (cikl) -> $T1"
echo "           get_num_samples at 1x/4x (nsamp) -> $T2; partial redraws (gfx2) -> $T3; mipmaps (mipt) -> $T4"
if [[ $T1 == PASS && $T2 == PASS && $T3 == PASS && $T4 == PASS ]]; then echo "self-test OK"
else echo "self-test FAILED -- restoring $OLD"; swap $BK; exit 1; fi
