#!/bin/zsh
# Swap the installed NVMTLDriver for another build WITHOUT touching running processes: copy beside, then rename
# (a loaded binary overwritten in place gets its users SIGKILLed for an invalid code signature).
# Already-running apps (WindowServer!) keep the old file until they restart; new processes load the new one.
# usage: sudo zsh plugin-swap.sh <NVMTLDriver build>
set -eu
[[ $(id -u) == 0 ]] || { echo "run with sudo"; exit 1; }
SRC=$1; M=/Library/GPUBundles/NVMTLDriver.bundle/Contents/MacOS
[[ -f $SRC ]] || { echo "no such file: $SRC"; exit 1; }
echo "before: $(shasum -a256 $M/NVMTLDriver | cut -c1-16)"
cp "$SRC" "$M/NVMTLDriver.new.$$" && chown root:wheel "$M/NVMTLDriver.new.$$" && chmod 755 "$M/NVMTLDriver.new.$$" && mv -f "$M/NVMTLDriver.new.$$" "$M/NVMTLDriver"
echo "after:  $(shasum -a256 $M/NVMTLDriver | cut -c1-16)  ($SRC)"
