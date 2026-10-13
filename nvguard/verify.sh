#!/bin/zsh
# Read-only health check of every local fix on this Hackintosh (no sudo needed).  zsh ~/work/system/nvguard/verify.sh
# DO NOT EDIT THE EXPECTED HASHES BY HAND: they come from install.sh (GOOD_* values) - keep both in sync.
G=/Library/NullMoth/guard; B=/Library/GPUBundles; M=$B/NVMTLDriver.bundle/Contents/MacOS
ok=0; bad=0
sha() { shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1; }
chk() { local what=$1 got=$2 want=$3
  if [[ $got == $want ]]; then print "  OK     $what"; ok=$((ok+1)); else print "  CHANGED $what  (now ${got[1,12]:-missing}, expected ${want[1,12]})"; bad=$((bad+1)); fi }
inst=${0:A:h}/install.sh
want() { sed -n "s/^$1=\"\{0,1\}\([0-9a-f]\{64\}\).*/\1/p" $inst | head -1 }
echo "== driver files (nvguard restores these automatically if a NullMoth update replaces them)"
chk "Metal plugin NVMTLDriver      " "$(sha $M/NVMTLDriver)"            "$(want GOOD_PLUGIN)"
chk "shader translator             " "$(sha $M/libnvmtl_translate.dylib)" "$(want GOOD_XLATE)"
chk "Vulkan driver (bindfix)       " "$(sha $B/nvmtl/libvulkan_nouveau.dylib)" "$(want GOOD_VK)"
chk "H.264 decoder (NVDEC t2d)     " "$(sha $M/libnvdec_h264.dylib)" "1b5d08ba7cb95804e076d0be30c994bc15121ec4c4345f587dc45e34adffe1bf"
chk "H.264 decoder (t2d, 8-byte)  " "$(sha $M/libnvdec_h264_t2d.dylib)" "$(sed -n 's/^T2D_SRC=.*T2D_SHA=\([0-9a-f]\{64\}\).*/\1/p' $inst | head -1)"
chk "H.264 encoder (NVENC)         " "$(sha $M/libnvenc_h264.dylib)" "2b231d508b2d886afb8de51b950071b905fbd23d88c635bfda968a0855d28231"
echo "== nvrm610.conf knobs (the plugin and NVK use the FIRST line of a key; nvguard keeps these in effect)"
CF=$B/nvmtl/nvrm610.conf
while read -r line; do [[ $line == *=* ]] || continue; k=${line%%=*}
  eff=$(awk -v k="$k" '{ l = $0; sub(/^[ \t]+/, "", l); if (l ~ /^#/) next; i = index(l, "="); if (!i) next; key = substr(l, 1, i - 1); sub(/[ \t]+$/, "", key)
    if (key != k) next; v = substr(l, i + 1); sub(/^[ \t]+/, "", v); sub(/[ \t\r]+$/, "", v); print key "=" v; exit }' $CF 2>/dev/null)
  chk "conf ${(r:30:)line}" "${eff:-unset}" "$line"
done < <(sed -n "s/^printf '%s\\\\n' \(.*\) > \$G\/conf.txt$/\1/p" $inst | tr ' ' '\n')
echo "== guard"
[[ -f /Library/LaunchDaemons/local.nvguard.plist ]] && { print "  OK     guard daemon installed"; ok=$((ok+1)); } || { print "  MISSING guard daemon plist"; bad=$((bad+1)); }
if [[ -f $G/MANIFEST.sha256 ]]; then ( cd $G && shasum -a 256 -c MANIFEST.sha256 >/dev/null 2>&1 ) && { print "  OK     guard snapshot intact"; ok=$((ok+1)); } || { print "  CHANGED guard snapshot does not match its MANIFEST"; bad=$((bad+1)); }
else print "  (no MANIFEST yet - re-run install.sh once)"; fi
print "  last guard log lines:"; tail -3 /var/log/nvguard.log 2>/dev/null | sed 's/^/    /'
echo "== EFI guard (AppleALC, Wi-Fi/BT, touchpad kexts on the ESP; repaired automatically at boot and every 6 h)"
EG=/Library/NullMoth/efiguard
[[ -f /Library/LaunchDaemons/local.efiguard.plist ]] && { print "  OK     efiguard daemon installed"; ok=$((ok+1)); } || { print "  MISSING efiguard daemon - run efiguard/install.sh (see efiguard/README.md)"; bad=$((bad+1)); }
if [[ -f $EG/manifest.txt ]]; then print "  OK     ESP snapshot: $(wc -l < $EG/manifest.txt | tr -d ' ') files, $(wc -l < $EG/required-kexts.txt | tr -d ' ') required kexts"; ok=$((ok+1)); else print "  MISSING ESP snapshot"; bad=$((bad+1)); fi
el=$(tail -1 /var/log/efiguard.log 2>/dev/null); print "  last efiguard log line: ${el:-none yet}"
[[ $el == *ATTENTION* ]] && { print "  ATTENTION efiguard reports a problem on the ESP (see /var/log/efiguard.log); after a deliberate EFI change re-run efiguard/install.sh"; bad=$((bad+1)); }
echo "== kernel side"
for k in com.nullmoth.NVRM com.nullmoth.NVAccel com.nullmoth.NVRMFB com.nullmoth.NVRMAGDC local.juren.NVDSM local.juren.BTLEFix org.b00t0x.CpuTopologyRebuild as.vit9696.Lilu as.vit9696.AppleALC; do
  if kmutil showloaded --list-only 2>/dev/null | grep -q " $k "; then print "  OK     $k loaded"; ok=$((ok+1)); else print "  NOT LOADED $k"; bad=$((bad+1)); fi; done
ba=$(nvram boot-args 2>/dev/null); [[ $ba == *nvaccel=1* && $ba == *nvfb=1* ]] && { print "  OK     boot-args carry nvfb/nvaccel"; ok=$((ok+1)); } || { print "  CHANGED boot-args: $ba"; bad=$((bad+1)); }
[[ $ba == *alcid=* ]] && { print "  OK     boot-args carry alcid (built-in audio layout: ${${ba##*alcid=}%% *})"; ok=$((ok+1)); } || { print "  CHANGED boot-args have no alcid (built-in mic/speakers need it): $ba"; bad=$((bad+1)); }
csr=$(nvram csr-active-config 2>/dev/null | awk '{print $2}'); [[ -n $csr ]] && { print "  OK     csr-active-config set ($csr)"; ok=$((ok+1)); } || { print "  CHANGED csr-active-config is empty (NVRAM was reset? SIP is back to default)"; bad=$((bad+1)); }
echo "== source of truth (git)"
for d in ~/work/system ~/work/nvidia-setup ~/work/nvidia-setup/src/repo; do
  if [[ -d $d/.git ]]; then n=$(git -C $d status --short --untracked-files=no 2>/dev/null | wc -l | tr -d ' '); print "  $( [[ $n == 0 ]] && echo OK || echo UNCOMMITTED ) ${d:t}: $n modified tracked files ($(git -C $d branch --show-current))"; else print "  NO GIT $d"; fi; done
b=$(ls -t ~/work/nvidia-setup/wifibt/backup/esp-OC-*.tar ~/work/nvidia-setup/audio/backup/esp-OC-*.tar 2>/dev/null | head -1)   # newest of the Wi-Fi/BT and audio EFI backups
[[ -n $b ]] && print "  newest EFI backup: ${b:t} ($(stat -f %Sm -t %F $b))" || print "  NO EFI BACKUP found"
echo; echo "result: $ok ok, $bad need attention"; exit $((bad>0))
