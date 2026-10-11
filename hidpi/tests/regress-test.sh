#!/bin/bash
# Run with bash (sudo bash regress-test.sh all), NOT zsh: the key list below needs word splitting.
# Run with sudo:  regress-test.sh <set>   (sets: all, async, usecount, import, abd, a, b, d, minpx7m, none)
# Bisects the plugin features added after the black-block fix was declared solved (2026-10-09 03:58):
#   async     NVMTL_SURFIN_ASYNC=0     async surface-in upload (build 21172baf)
#   usecount  NVMTL_SURF_USECOUNT=0    IOSurface use counts held by command buffers (build a7c70f39)
#   import    NVMTL_SURFIN_IMPORT_MB=0 direct host-pointer import of IOSurface pages for repeat uploads
# Only touches its own keys in /Library/GPUBundles/nvmtl/nvrm610.conf, every other line is kept.
# Each run first strips every test key, so sets are exclusive; abd/a/b/d are the partial-update/recycle/sampler knob groups from knob-test.sh.
# minpx7m: only surfaces of >= 7.0M px (the 3584x2016 scan-out framebuffers are 7.2M) stay in shared linear VRAM; every smaller one, window backing stores included, becomes a private image.
# Takes effect after a reboot; "none" removes the test keys again.
set -u
[ "$(id -u)" -eq 0 ] || { echo "STOP: run with sudo"; exit 1; }
CONF=/Library/GPUBundles/nvmtl/nvrm610.conf
BAK="$CONF.bak-regress-$(date +%Y%m%d-%H%M%S)"
cp -p "$CONF" "$BAK" || { echo "STOP: could not back up $CONF"; exit 1; }
case "${1:-}" in
  all) K="NVMTL_SURFIN_ASYNC=0 NVMTL_SURF_USECOUNT=0 NVMTL_SURFIN_IMPORT_MB=0";;
  async) K="NVMTL_SURFIN_ASYNC=0";;
  usecount) K="NVMTL_SURF_USECOUNT=0";;
  import) K="NVMTL_SURFIN_IMPORT_MB=0";;
  abd) K="NVMTL_NO_DIRTYONLY=1 NVMTL_NO_HEAPTEX_RECYCLE=1 NVMTL_NO_BUFTEX_RECYCLE=1 NVMTL_NO_BUFREUSE=1 NVMTL_NO_POOL_REUSE=1 NVMTL_NO_HEAP_ALIAS=1 NVMTL_NO_SAMPVAR=1 NVMTL_NO_PARFAST=1 NVMTL_SKIP_EMPTY=0 NVMTL_EVFOLD=0 NVMTL_ASYNC_COMMIT=0";;
  a) K="NVMTL_NO_DIRTYONLY=1";;
  b) K="NVMTL_NO_HEAPTEX_RECYCLE=1 NVMTL_NO_BUFTEX_RECYCLE=1 NVMTL_NO_BUFREUSE=1 NVMTL_NO_POOL_REUSE=1 NVMTL_NO_HEAP_ALIAS=1";;
  d) K="NVMTL_NO_SAMPVAR=1 NVMTL_NO_PARFAST=1 NVMTL_SKIP_EMPTY=0 NVMTL_EVFOLD=0 NVMTL_ASYNC_COMMIT=0";;
  minpx7m) K="NVMTL_SURF_SHARE_MINPX=7000000";;
  none) K="";;
  *) echo "usage: sudo $0 all|async|usecount|import|abd|a|b|d|minpx7m|none"; exit 1;;
esac
case " $K " in *NVMTL_SURF_SHARE_MINPX=*) ;; *) K="$K NVMTL_SURF_SHARE_MINPX=3686400";; esac
read -r -a KS <<< "$K"
# also drop the malformed one-line entry an earlier zsh run wrote
{ grep -v -E '^(NVMTL_SURFIN_ASYNC|NVMTL_SURF_USECOUNT|NVMTL_SURFIN_IMPORT_MB|NVMTL_NO_DIRTYONLY|NVMTL_NO_HEAPTEX_RECYCLE|NVMTL_NO_BUFTEX_RECYCLE|NVMTL_NO_BUFREUSE|NVMTL_NO_POOL_REUSE|NVMTL_NO_HEAP_ALIAS|NVMTL_NO_SAMPVAR|NVMTL_NO_PARFAST|NVMTL_SKIP_EMPTY|NVMTL_EVFOLD|NVMTL_ASYNC_COMMIT|NVMTL_SURF_SHARE_MINPX)=' "$CONF"; for kv in "${KS[@]}"; do echo "$kv"; done; } > "$CONF.new" \
  && chmod 644 "$CONF.new" && mv "$CONF.new" "$CONF" || { echo "STOP: could not write $CONF"; exit 1; }
echo "set '$1' -> $CONF now (backup $BAK):"; cat "$CONF"
echo "$(date '+%F %T') regress set=$1 $K" >> /private/var/tmp/nvmtl-knobtest.txt
echo "DONE. Reboot now."
