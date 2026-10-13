#!/bin/zsh
# regress.sh <plugindir> test [args...]  -> last line of output (plugshim)
C=~/work/nvidia-setup/hidpi/catest
D=$1; shift; t=$1; shift
out=$(cd /private/tmp && DYLD_INSERT_LIBRARIES=$C/plugshim.dylib NVMTL_TEST_PLUGIN=$D/NVMTLDriver perl -e "alarm 120; exec @ARGV" $C/$t "$@" 2>&1); rc=$?
print -r -- "rc=$rc | $(print -r -- "$out" | grep -v '^plugshim' | tail -1 | cut -c1-150)"
