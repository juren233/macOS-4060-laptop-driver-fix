#!/bin/bash
# TRIAL: replaces only the four NullMoth kexts (NVRM NVAccel NVRMFB NVRMAGDC) with upstream 1.9.0 + our changes:
#   NVRM   = 1.9.0 + head-scaler patch + flip-at-boot patch (patch-nvrm-190.py)      NVRMFB = 1.9.0 source merged with our backlight/internal-panel code
# GPUBundles (plugin v48, Vulkan, nvrm610.conf), firmware, boot-args, DisplayProductID override and nvflip are NOT touched.
# Backs up the current kexts + kernel collection first; undo with rollback-kexts-190.sh <backup dir> (also works from Recovery).
# Usage: sudo ./install-kexts-190.sh [--check]   (--check builds the test collection only, changes nothing)
set -u
HERE=$(cd "$(dirname "$0")" && pwd); P="$HERE/payload"
KEXTS="NVRM NVAccel NVRMFB NVRMAGDC"; EXT=/Library/Extensions; NM=/Library/NullMoth
KC=/Library/KernelCollections/AuxiliaryKernelExtensions.kc
KB=/System/Library/KernelCollections/BootKernelExtensions.kc; KS=/System/Library/KernelCollections/SystemKernelExtensions.kc
KARG=(--allow-missing-kdk); [ -f /System/Library/Kernels/kernel ] && KARG+=(--kernel /System/Library/Kernels/kernel)
BK=""; INSTALLING=0; NEWKC=""
die() { echo "   STOP: $*" >&2
  if [ "$INSTALLING" = 1 ]; then echo "   restoring the previous kexts ..." >&2; /bin/bash "$HERE/rollback-kexts-190.sh" "$BK" || echo "   RESTORE INCOMPLETE: run rollback-kexts-190.sh $BK" >&2; fi
  exit 1; }
[ "$(id -u)" -eq 0 ] || die "run with sudo"
[ "$(sw_vers -productVersion | cut -d. -f1)" = 15 ] || die "payload is for macOS 15"
want() { [ "$(shasum -a 256 "$1" | cut -d' ' -f1)" = "$2" ] || die "payload file changed: $1"; }
want "$P/Library/Extensions/NVRM.kext/Contents/MacOS/NVRM"       27ed43cb82c00d56c4a5b86a088db98fccd5fe42198022e09893aa36c64b66a7
want "$P/Library/Extensions/NVRMFB.kext/Contents/MacOS/NVRMFB"   a33a35a9342601a536fabc6473a47a078021fd98a045c4faaf013e3cee43665d
want "$P/Library/Extensions/NVRMAGDC.kext/Contents/MacOS/NVRMAGDC" 270f9ef9ac9d2482689ed4d63d422e705e439509d0e3b62fc6bc96fdc9e693ed
want "$P/Library/NullMoth/kexts/15/NVAccel.kext/Contents/MacOS/NVAccel" ed6b1fbf360d7b44a2aa6a037f52036c8fc22a16393a9ddf932dfc4357d1e681
for k in NVRM NVRMFB; do codesign --verify "$P/Library/Extensions/$k.kext" 2>/dev/null || die "$k.kext signature invalid"; done
kp() { [ "$1" = NVAccel ] && echo "$P/Library/NullMoth/kexts/15/NVAccel.kext" || echo "$P/Library/Extensions/$1.kext"; }

echo "== 1. test kernel collection with the new kexts"
T=$(mktemp -d /var/tmp/nv190.XXXX) && mkdir -p "$T/repo" || die "tmp dir"
for x in "$EXT"/*.kext; do n=$(basename "$x" .kext); case " $KEXTS " in *" $n "*) ;; *) cp -R "$x" "$T/repo/";; esac; done
for k in $KEXTS; do cp -R "$(kp $k)" "$T/repo/" || die "copy $k"; done
chown -R root:wheel "$T/repo" && chmod -R go-w "$T/repo"
kmutil create -n aux --volume-root / "${KARG[@]}" -B $KB -S $KS --repository "$T/repo" -A "$T/aux.kc" -z >"$T/kmutil.log" 2>&1 || { tail -20 "$T/kmutil.log"; die "test collection failed (nothing changed)"; }
INS=$(kmutil inspect -a x86_64 -A "$T/aux.kc" 2>/dev/null) || die "cannot inspect test collection"
for k in $KEXTS; do printf '%s\n' "$INS" | grep -oE 'com\.nullmoth\.[A-Za-z0-9]+' | grep -Fxq "com.nullmoth.$k" || die "kmutil refused $k (nothing changed)"; done
echo "   ok: all four kexts accepted"
[ "${1:-}" = --check ] && { rm -rf "$T"; echo "CHECK PASS (nothing changed)"; exit 0; }

BK=$(mktemp -d "$NM/backup-190-$(date +%Y%m%d-%H%M%S).XXXXXX") || die "backup dir"
echo "== 2. backup -> $BK"
for k in $KEXTS; do cp -Rp "$EXT/$k.kext" "$BK/" || die "backup $k"; done
cp -p "$KC" "$BK/AuxiliaryKernelExtensions.kc" || die "backup kc"
ditto "$NM/kexts" "$BK/kexts" || die "backup kexts cache"; cp -p "$NM/os-major" "$BK/os-major" 2>/dev/null
echo "   ok"
echo "== 3. install"
INSTALLING=1
for k in $KEXTS; do rm -rf "$EXT/$k.kext" && ditto "$(kp $k)" "$EXT/$k.kext" || die "copy $k"; done
rm -rf "$NM/kexts" && ditto "$P/Library/NullMoth/kexts" "$NM/kexts" || die "copy accelerator cache"
for t in 15 26; do (cd "$NM/kexts/$t" && find NVAccel.kext -type f -exec shasum -a 256 '{}' \;) > "$NM/kexts/$t/SHA256SUMS" || die "cache manifest"; done
chown -R root:wheel "$NM/kexts" && chmod -R go-w "$NM/kexts"
for k in $KEXTS; do chown -R root:wheel "$EXT/$k.kext" && chmod -R 755 "$EXT/$k.kext" || die "perms $k"; done
NEWKC="$KC.nv190-new"; rm -f "$NEWKC"
kmutil create -n aux --volume-root / "${KARG[@]}" -B $KB -S $KS --repository "$EXT" -A "$NEWKC" -z >"$T/kmutil2.log" 2>&1 || die "live collection build failed"
[ -s "$NEWKC" ] || die "live collection empty"
INS=$(kmutil inspect -a x86_64 -A "$NEWKC" 2>/dev/null) || die "cannot inspect live collection"
for k in $KEXTS local.juren.NVDSM; do :; done
for k in $KEXTS; do printf '%s\n' "$INS" | grep -oE 'com\.nullmoth\.[A-Za-z0-9]+' | grep -Fxq "com.nullmoth.$k" || die "$k missing from live collection"; done
mv -f "$NEWKC" "$KC" || die "cannot publish collection"
INSTALLING=0; rm -rf "$T"
echo "   installed. Backup: $BK"
echo "REBOOT: sudo shutdown -r now"
echo "UNDO (screen black / panic): from SSH, or macOS Recovery Terminal after mounting Data: sudo $HERE/rollback-kexts-190.sh $BK"
