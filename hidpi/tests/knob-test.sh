#!/bin/bash
# Run with sudo:  knob-test.sh <set>   (sets: all, a, b, c, d, none)
# Switches some of NullMoth's Metal-driver optimisations off through the driver's own conf file
# (/Library/GPUBundles/nvmtl/nvrm610.conf - the release driver ignores NVMTL_* environment variables).
# Takes effect at the next reboot and stays until changed; "none" removes the test knobs (other lines are kept).
set -u
[ "$(id -u)" -eq 0 ] || { echo "STOP: run with sudo"; exit 1; }
D=$(cd "$(dirname "$0")" && pwd); CONF=/Library/GPUBundles/nvmtl/nvrm610.conf; ORIG="$D/backup/nvrm610.conf.orig"
[ -f "$ORIG" ] || cp -p "$CONF" "$ORIG" || { echo "STOP: could not back up $CONF"; exit 1; }
A="NVMTL_NO_DIRTYONLY=1"
B="NVMTL_NO_HEAPTEX_RECYCLE=1 NVMTL_NO_BUFTEX_RECYCLE=1 NVMTL_NO_BUFREUSE=1 NVMTL_NO_POOL_REUSE=1 NVMTL_NO_HEAP_ALIAS=1"
C="NVMTL_NO_SURFACE_SHARE=1 NVMTL_NO_SURFACE_PAGEOFF=1"
E="NVMTL_NO_SAMPVAR=1 NVMTL_NO_PARFAST=1 NVMTL_SKIP_EMPTY=0 NVMTL_EVFOLD=0 NVMTL_ASYNC_COMMIT=0"
case "${1:-}" in
  all) K="$A $B $C $E";; p) K="NVMTL_NO_SURFACE_PAGEOFF=1";; s) K="NVMTL_NO_SURFACE_SHARE=1";; a) K="$A";; b) K="$B";; c) K="$C";; d) K="$E";; none) K="";;
  *) echo "usage: sudo $0 all|a|b|c|d|none"; exit 1;;
esac
{ grep -v -E '^(NVMTL_NO_DIRTYONLY|NVMTL_NO_HEAPTEX_RECYCLE|NVMTL_NO_BUFTEX_RECYCLE|NVMTL_NO_BUFREUSE|NVMTL_NO_POOL_REUSE|NVMTL_NO_HEAP_ALIAS|NVMTL_NO_SURFACE_SHARE|NVMTL_NO_SURFACE_PAGEOFF|NVMTL_NO_SAMPVAR|NVMTL_NO_PARFAST|NVMTL_SKIP_EMPTY|NVMTL_EVFOLD|NVMTL_ASYNC_COMMIT)=' "$CONF"; for kv in $K; do echo "$kv"; done; } > "$CONF.new" && chmod 644 "$CONF.new" && mv "$CONF.new" "$CONF" || { echo "STOP: could not write $CONF"; exit 1; }
echo "set '$1' -> $CONF now:"; cat "$CONF"
echo "$(date '+%F %T') set=$1 $K" >> /private/var/tmp/nvmtl-knobtest.txt
echo "DONE. Reboot now."
