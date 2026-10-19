#!/bin/bash
# Kernel move: the four NullMoth kexts from 1.15.0 + ours to upstream 2.3.7 + ours (macOS 26 only).
#   NVRM     = official 2.3.7 (11633b6e) + head-scaler (patch-nvrm-237.py, pattern-matched); flip-at-boot is upstream now (8b120f3)
#   NVRMFB   = 2.3.7 source (src/wt-k237, branch kext-2.3.7) + skip the CPU clear of fresh VRAM when it reads zero (build-fb-237.sh)
#   NVAccel  = official 2.3.7 macOS 26 build (15 build kept in the cache, as upstream does); NVRMAGDC = official 2.3.7
#   all four ad-hoc signed. NVDSM on the ESP is NOT touched (2.3.7 NVRM still exports _nvkms_xnu_backlight: NVDSM yields).
# Also: GPU firmware to /Library/NullMoth/nvfw (2.3.7 reads only there, root-owned, size+SHA-1 checked by NVRM);
#       /Users/Shared/nvfw is kept so the 1.15.0 kernel still finds it after a rollback.
#       boot-args (OpenCore config.plist via wifibt/oc-bootarg.sh): -nvrmnopm (no power tree: same as now, sleep stays off),
#       nvrmmapowner=0 (map-owner mismatches counted, not refused, while we watch), nvfbhidpi=1 (2.3.7 sizes the scaler
#       from the panel's own raster list = 2560x1440 here; without it the 1792x1008 / 1760x990 HiDPI backings are refused).
# NOT done: GPUBundles (plugin/translator/NVK/conf), upstream's lastgood fallback job, NVDSM, sleep.
# Usage: sudo bash install-kexts-237.sh [--check]   (--check: payload + test kernel collection + ESP read, changes nothing)
# Undo:  sudo bash rollback-kexts-237.sh <backup dir printed below>   (kexts part also works from Recovery, see that script)
set -u
PATH=/usr/bin:/bin:/usr/sbin:/sbin; export PATH
HERE=$(cd "$(dirname "$0")" && pwd); P="$HERE/payload"; SYS=$(cd "$HERE/../../system" && pwd); NS=$(cd "$HERE/.." && pwd)
KEXTS="NVRM NVAccel NVRMFB NVRMAGDC"; EXT=/Library/Extensions; NM=/Library/NullMoth; FW=$NM/nvfw; FWOLD=/Users/Shared/nvfw
KC=/Library/KernelCollections/AuxiliaryKernelExtensions.kc
KB=/System/Library/KernelCollections/BootKernelExtensions.kc; KS=/System/Library/KernelCollections/SystemKernelExtensions.kc
KARG=(--allow-missing-kdk); [ -f /System/Library/Kernels/kernel ] && KARG+=(--kernel /System/Library/Kernels/kernel)
ESPUUID=${ESP_UUID:?set ESP_UUID to the Partition UUID of your OpenCore ESP (diskutil info <disk>)}; DEV=$(for d in $(diskutil list | awk '/ EFI /{print $NF}'); do [ "$(diskutil info $d | awk -F': *' '/Partition UUID/{print $2}')" = $ESPUUID ] && { echo $d; break; }; done); DEV=${DEV:-ESP-not-found}; export PATH=/usr/local/bin:$PATH MTOOLS_SKIP_CHECK=1; I=(-i /dev/$DEV)
BOOTARGS="-nvrmnopm nvrmmapowner=0 nvfbhidpi=1"; OCBA="$NS/wifibt/oc-bootarg.sh"; NVV=7C436110-AB2A-4BBB-A880-FE41995C9F82
CHECK=0; [ "${1:-}" = --check ] && CHECK=1
BK=""; INSTALLING=0; T=""
die() { echo "   STOP: $*" >&2
  if [ "$INSTALLING" = 1 ]; then echo "   restoring the previous kexts ..." >&2; /bin/bash "$HERE/rollback-kexts-237.sh" "$BK" || echo "   RESTORE INCOMPLETE: run rollback-kexts-237.sh $BK" >&2; fi
  [ -z "$T" ] || rm -rf "$T"; exit 1; }
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
want() { [ "$(sha "$1")" = "$2" ] || die "payload file changed: $1"; }
[ "$(id -u)" -eq 0 ] || die "run with sudo"
[ "$(sw_vers -productVersion | cut -d. -f1)" = 26 ] || die "payload is for macOS 26"

echo "== 0. payload, installed state, ESP"
want "$P/Library/Extensions/NVRM.kext/Contents/MacOS/NVRM"             61bc897fe753e784250a414818f68b7c2ed603b24400332cc1bf0b747ecbcca2
want "$P/Library/Extensions/NVRMFB.kext/Contents/MacOS/NVRMFB"         5dec327c53e6ec0ee3871545a8ddbe53de750bf0c68cad7633747562ddff666d
want "$P/Library/Extensions/NVRMAGDC.kext/Contents/MacOS/NVRMAGDC"     7cb0e0ef35848a1214dc9de41470e18099cb39d996d86a0e67032d326125d476
want "$P/Library/NullMoth/kexts/15/NVAccel.kext/Contents/MacOS/NVAccel" 10041ddc0dd2d83be24cb43f89507712121bc4d91da48ead70e55557116970f3
want "$P/Library/NullMoth/kexts/26/NVAccel.kext/Contents/MacOS/NVAccel" 6600f4719d250a5d6a1fbc5bbbb2001f0a0ee330591a428e0524e9794e9b70a0
F="$P/nvfw/nvidia/610.57.04"
want "$F/gsp_ga10x.bin"    c0156954f3e048d56011524e0c2ae2881bb6db8173b53f9b2f4eb94197f02999
want "$F/gsp_tu10x.bin"    d157e3b7dd5da2ca8d1ccb6ca98958f9e35d10a9ef7326277ebac133e4b0d1a7
want "$F/ucodes_ga10x.bin" 3a36ceb211c20694f3d2e33ade2bbd2c3ae0b61ba2f28eaff4362aac547a632c
want "$F/ucodes_tu10x.bin" dcbdf512ab09b7f6d946e7f415bcfbc9137f5db1cf0c3c576f4b34b5275acb38
for k in Library/Extensions/NVRM.kext Library/Extensions/NVRMFB.kext Library/Extensions/NVRMAGDC.kext Library/NullMoth/kexts/15/NVAccel.kext Library/NullMoth/kexts/26/NVAccel.kext; do
  codesign --verify --strict "$P/$k" 2>/dev/null || die "$k signature invalid"; done
# what is installed now must be the 1.15.0 set this was prepared against (so the backup is a known-good state)
[ "$(sha $EXT/NVRM.kext/Contents/MacOS/NVRM)" = 9794974b35966a89fe90b272ceebcbfa30999e46af314203d0b816f339bae83f ] || die "installed NVRM is not 9794974b (1.15.0 + ours)"
[ "$(sha $EXT/NVRMFB.kext/Contents/MacOS/NVRMFB)" = 5d664f114ffe465796b0a339e4eb0fb42cfdeab3a0e02e0bc8b2bc4e1d6ab165 ] || die "installed NVRMFB is not 5d664f11 (fbwake)"
[ "$(sha $EXT/NVAccel.kext/Contents/MacOS/NVAccel)" = 118c5212ebb1ddddee5016df6b629d2b916773a9f379f1f1ba95e315022d2cef ] || die "installed NVAccel is not 118c5212"
[ "$(sha $EXT/NVRMAGDC.kext/Contents/MacOS/NVRMAGDC)" = 270f9ef9ac9d2482689ed4d63d422e705e439509d0e3b62fc6bc96fdc9e693ed ] || die "installed NVRMAGDC is not 270f9ef9"
[ -f "$KC" ] || die "no auxiliary kernel collection to back up"
[ -d "$FWOLD/nvidia/610.57.04" ] || die "$FWOLD missing: the 1.15.0 kernel (rollback target) reads its firmware there"
[ "$(diskutil info $DEV | awk -F': *' '/Partition UUID/{print $2}')" = $ESPUUID ] || die "$DEV is not the expected ESP"
command -v mcopy >/dev/null || die "mtools missing"
[ -f "$OCBA" ] || die "missing $OCBA"
kp() { [ "$1" = NVAccel ] && echo "$P/Library/NullMoth/kexts/26/NVAccel.kext" || echo "$P/Library/Extensions/$1.kext"; }
echo "   ok: payload pinned + signed, installed set is 1.15.0 + ours, ESP $DEV"

echo "== 1. test kernel collection with the new kexts"
T=$(mktemp -d /var/tmp/nv237.XXXX) && mkdir -p "$T/repo" || die "tmp dir"
for x in "$EXT"/*.kext; do n=$(basename "$x" .kext); case " $KEXTS " in *" $n "*) ;; *) cp -R "$x" "$T/repo/";; esac; done
for k in $KEXTS; do cp -R "$(kp $k)" "$T/repo/" || die "copy $k"; done
# macOS 26 kmutil silently skips kexts not owned by root
chown -R root:wheel "$T/repo" && chmod -R go-w "$T/repo"
kmutil create -n aux --volume-root / "${KARG[@]}" -B $KB -S $KS --repository "$T/repo" -A "$T/aux.kc" -z >"$T/kmutil.log" 2>&1 || { tail -20 "$T/kmutil.log"; die "test collection failed (nothing changed)"; }
[ -s "$T/aux.kc" ] || die "test collection empty (nothing changed)"
INS=$(kmutil inspect -a x86_64 -A "$T/aux.kc" 2>/dev/null) || die "cannot inspect test collection"
for k in $KEXTS; do printf '%s\n' "$INS" | grep -oE 'com\.nullmoth\.[A-Za-z0-9]+' | grep -Fxq "com.nullmoth.$k" || { tail -20 "$T/kmutil.log"; die "kmutil refused $k (nothing changed)"; }; done
U=$(grep -ciE 'unresolved|undefined symbol|failed to bind' "$T/kmutil.log"); [ "$U" = 0 ] || { grep -iE 'unresolved|undefined symbol|failed to bind' "$T/kmutil.log" | head; die "test collection reports $U unresolved symbol lines (nothing changed)"; }
echo "   ok: all four kexts in the test collection, 0 unresolved-symbol lines"
diskutil unmount $DEV >/dev/null 2>&1 || true
mcopy "${I[@]}" -n ::/EFI/OC/config.plist "$T/config.plist" && plutil -lint "$T/config.plist" >/dev/null || die "cannot read the ESP's config.plist (nothing changed)"
mdir "${I[@]}" ::/EFI/OC/Kexts/NVDSM.kext/Contents/MacOS >/dev/null || die "no NVDSM.kext on the ESP (nothing changed)"
CUR=$(/usr/libexec/PlistBuddy -c "Print :NVRAM:Add:$NVV:boot-args" "$T/config.plist") || die "no boot-args in config.plist"
echo "   ok: ESP readable, NVDSM.kext present; config boot-args: $CUR"
for a in $BOOTARGS; do case " $CUR " in *" $a "*) echo "   boot-arg $a: already set";; *) echo "   boot-arg $a: will be added";; esac; done
if [ -e "$FW" ] && [ -n "$(find "$FW" \( ! -user root -o -perm -o+w -o -perm -g+w \) -print -quit 2>/dev/null)" ]; then echo "   note: $FW exists and is not root-only; it will be replaced"; fi
[ "$CHECK" = 1 ] && { rm -rf "$T"; echo; echo "CHECK PASS (nothing changed)"; exit 0; }

BK=$(mktemp -d "$NM/backup-237-$(date +%Y%m%d-%H%M%S).XXXXXX") || die "backup dir"
echo "== 2. backup -> $BK"
for k in $KEXTS; do ditto "$EXT/$k.kext" "$BK/$k.kext" || die "backup $k"; done
cp -p "$KC" "$BK/AuxiliaryKernelExtensions.kc" || die "backup kc"
ditto "$NM/kexts" "$BK/kexts" || die "backup kexts cache"; [ ! -f "$NM/os-major" ] || cp -p "$NM/os-major" "$BK/os-major"
ditto "$FWOLD" "$BK/nvfw" || die "backup firmware"; [ -e "$FW" ] && : > "$BK/had-new-fw-dir"
cp -p "$T/config.plist" "$BK/config.plist" || die "backup config.plist"
printf '%s\n' "$CUR" > "$BK/boot-args.txt"
echo "   ok"

echo "== 3. firmware -> $FW"
INSTALLING=1
if [ -e "$FW" ] && [ -n "$(find "$FW" \( ! -user root -o -perm -o+w -o -perm -g+w \) -print -quit 2>/dev/null)" ]; then rm -rf "$FW" || die "clear a non-root firmware dir"; fi
mkdir -p "$FW" && ditto "$P/nvfw" "$FW" && chown -R root:wheel "$FW" && chmod -R go-w,a+rX "$FW" || die "copy firmware"
for f in gsp_ga10x.bin gsp_tu10x.bin ucodes_ga10x.bin ucodes_tu10x.bin; do cmp -s "$P/nvfw/nvidia/610.57.04/$f" "$FW/nvidia/610.57.04/$f" || die "firmware $f read-back differs"; done
echo "   ok (old copy in $FWOLD kept for the 1.15.0 kernel)"

echo "== 4. kexts + auxiliary kernel collection"
for k in $KEXTS; do rm -rf "$EXT/$k.kext" && ditto "$(kp $k)" "$EXT/$k.kext" || die "copy $k"; done
for t in 15 26; do rm -rf "$NM/kexts/$t/NVAccel.kext" && ditto "$P/Library/NullMoth/kexts/$t/NVAccel.kext" "$NM/kexts/$t/NVAccel.kext" || die "copy accelerator cache $t"
  (cd "$NM/kexts/$t" && find NVAccel.kext -type f -exec shasum -a 256 '{}' \;) > "$NM/kexts/$t/SHA256SUMS" || die "cache manifest"; done
chown -R root:wheel "$NM/kexts" && chmod -R go-w "$NM/kexts"; echo 26 > "$NM/os-major"
for k in $KEXTS; do chown -R root:wheel "$EXT/$k.kext" && chmod -R 755 "$EXT/$k.kext" || die "perms $k"; done
NEWKC="$KC.nv237-new"; rm -f "$NEWKC"
kmutil create -n aux --volume-root / "${KARG[@]}" -B $KB -S $KS --repository "$EXT" -A "$NEWKC" -z >"$T/kmutil2.log" 2>&1 || { tail -20 "$T/kmutil2.log"; die "live collection build failed"; }
[ -s "$NEWKC" ] || die "live collection empty"
INS=$(kmutil inspect -a x86_64 -A "$NEWKC" 2>/dev/null) || die "cannot inspect live collection"
for k in $KEXTS; do printf '%s\n' "$INS" | grep -oE 'com\.nullmoth\.[A-Za-z0-9]+' | grep -Fxq "com.nullmoth.$k" || die "$k missing from live collection"; done
mv -f "$NEWKC" "$KC" || die "cannot publish collection"
echo "   ok"

echo "== 5. boot-args in the ESP's config.plist"
for a in $BOOTARGS; do bash "$OCBA" add "$a" 2>&1 | sed 's/^/   /'; [ "${PIPESTATUS[0]}" = 0 ] || die "boot-arg $a"; done
mcopy "${I[@]}" -n ::/EFI/OC/config.plist "$T/after.plist" || die "re-read config.plist"
NEWBA=$(/usr/libexec/PlistBuddy -c "Print :NVRAM:Add:$NVV:boot-args" "$T/after.plist")
for a in $BOOTARGS; do case " $NEWBA " in *" $a "*) ;; *) die "boot-arg $a not in config.plist after the edit";; esac; done
# a fresh start count for the 2.3.7 boot guard (two starts without a lit display -> driver stays off, firmware framebuffer)
nvram -d $NVV:nullmoth-nv-starts 2>/dev/null; nvram -d $NVV:nullmoth-nv-ok 2>/dev/null; nvram -d $NVV:nullmoth-remove 2>/dev/null
INSTALLING=0; rm -rf "$T"; T=""
echo "   ok  $NEWBA"

echo "== 6. efiguard snapshot (so it keeps the new config.plist)"
zsh "$SYS/efiguard/install.sh" 2>&1 | tail -3 || echo "   NOTE: efiguard refresh failed - run: sudo zsh $SYS/efiguard/install.sh"
echo
echo "installed. Backup: $BK"
echo "REBOOT (do not kill WindowServer): sudo shutdown -r now"
echo "UNDO: sudo bash $HERE/rollback-kexts-237.sh $BK    (screen black / panic: from Recovery, see rollback-kexts-237.sh)"
