#!/bin/zsh
# ============================================================================================================
# LOCAL HARDENING - DO NOT EDIT, DELETE OR "CLEAN UP" THIS FILE OR /Library/NullMoth/guard.
# It is what keeps this Hackintosh's GPU fixes (Chrome/Electron flicker, H.264 stripes, WS shader cache, ...)
# alive after a NullMoth reinstall/update. The sources live in ~/work/system (git) and ~/work/nvidia-setup/src/repo
# (git branch local-mods). Re-install: sudo zsh ~/work/system/nvguard/install.sh   Check: zsh ~/work/system/nvguard/verify.sh
# ============================================================================================================
# Keeps the RTX 4060 (Ada) fixes in NullMoth's driver bundle. Run by LaunchDaemon local.nvguard at boot and whenever
# the bundle's MacOS folder changes (driver reinstall, plugin installer...). For each file: already patched -> nothing;
# a replaceable build (NullMoth's stock, or a known build that lacks our fixes) -> put the patched copy back; any other
# build (e.g. a NullMoth update) -> leave it, log it. files.txt: name  sha-of-replaceable-build [more shas...]
G=${NVGUARD_DIR:-/Library/NullMoth/guard}
M=/Library/GPUBundles/NVMTLDriver.bundle/Contents/MacOS
CONF=${NVGUARD_CONF:-/Library/GPUBundles/nvmtl/nvrm610.conf}
LOG=${NVGUARD_LOG:-/var/log/nvguard.log}
log() { print -r -- "$(date '+%F %T') $*" >> $LOG; }
sha() { shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1; }
# New inode (copy beside, then rename): overwriting a loaded dylib in place -> "Code Signature Invalid" SIGKILLs.
put() { cp "$1" "$2.new.$$" && chown root:wheel "$2.new.$$" && chmod 755 "$2.new.$$" && mv -f "$2.new.$$" "$2"; }
sleep 3   # let an installer finish writing the bundle
[[ -d $M ]] || exit 0
# name  stock-sha  patched-copy.  A name with a "/" (nvmtl/libvulkan_nouveau.dylib) lives under /Library/GPUBundles, else in the plugin bundle;
# the snapshot in $G is always stored under the basename.
bad=0; n=0
while read -r f stocks; do
  [[ -n $f ]] || continue
  b=${f:t}; p=$G/$b; [[ -f $p ]] || continue
  if [[ $f == */* ]]; then T=/Library/GPUBundles/$f; else T=$M/$f; fi
  [[ -e $T ]] || { log "$f: MISSING from the driver (reinstall removed it?) - restoring"; put $p $T && log "$f: restored" || { log "$f: RESTORE FAILED"; bad=1; }; continue; }
  n=$((n+1)); cur=$(sha $T); want=$(sha $p)
  if [[ $cur == $want ]]; then :
  elif [[ " $stocks " == *" $cur "* ]]; then put $p $T && log "$f: replaceable build found -> patched copy restored" || { log "$f: RESTORE FAILED"; bad=1; }
  else log "$f: unknown build ${cur[1,16]} - left alone (NullMoth update? re-run nvguard install after re-checking the patch)"; bad=1; fi
done < $G/files.txt
log "integrity check: $n files, $([[ $bad == 0 ]] && echo 'all match or restored' || echo 'ATTENTION - see lines above')"
# conf.txt: KEY=VALUE lines that must be in effect. The plugin and NVK take the FIRST non-comment line of a key and ignore later
# ones, so appending a line is not enough when the key is already there with another value: every line of the key is removed
# and the wanted one appended. The file is only rewritten (after a dated backup beside it) when the key is not exactly that one line.
keylines() { awk -v k="$1" '{ l = $0; sub(/^[ \t]+/, "", l); if (l ~ /^#/) next; i = index(l, "="); if (!i) next
  key = substr(l, 1, i - 1); sub(/[ \t]+$/, "", key); if (key == k) print $0 }' $CONF; }
bak=
[[ -f $CONF ]] && while read -r line; do
  [[ $line == *=* ]] || continue
  k=${line%%=*}; cur=$(keylines $k)
  [[ $cur == $line ]] && continue
  [[ -n $bak ]] || { bak=$CONF.guard-bak.$(date +%Y%m%d-%H%M%S); cp -p $CONF $bak; }   # once per run: the file as found
  awk -v k="$k" '{ l = $0; sub(/^[ \t]+/, "", l); if (l !~ /^#/) { i = index(l, "="); if (i) { key = substr(l, 1, i - 1); sub(/[ \t]+$/, "", key)
    if (key == k) next } } print }' $CONF > $CONF.new.$$ && print -r -- "$line" >> $CONF.new.$$ &&
    chown $(stat -f %u:%g $CONF) $CONF.new.$$ && chmod $(stat -f %Lp $CONF) $CONF.new.$$ && mv -f $CONF.new.$$ $CONF &&
    log "conf: $line in effect (was: ${${cur:-unset}//$'\n'/ | })" || { rm -f $CONF.new.$$; log "conf: FAILED to set $line"; }
done < $G/conf.txt
exit 0
