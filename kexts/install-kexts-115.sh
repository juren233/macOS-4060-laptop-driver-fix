#!/bin/bash
# Stage 3: the four NullMoth kexts (NVRM NVAccel NVRMFB NVRMAGDC) from 1.9.0 + ours to upstream 1.15.0 + ours, and NVDSM on the ESP.
#   NVRM     = 1.15.0 + head-scaler + flip-at-boot (patch-nvrm-115.py; same edits as 1.9.0, the code moved by 0x1590), ad-hoc signed
#   NVRMFB   = 1.15.0 source + patches/nullmoth-1.15.0/0003 (skip the CPU clear of fresh VRAM when it reads zero; build-fb-115.sh)
#   NVAccel / NVRMAGDC = stock 1.15.0 (NVAccel: copied-frame flicker fix c2af33d, display wake retries 79e1c2f; NVRMAGDC unchanged)
#   NVDSM    = v8 + "NVRM keeps the backlight itself": on 1.15.0 NVRM it no longer routes nvkms_(un)register_backlight (upstream
#              NVRMFB's NVRMBacklight handler needs NVRM's own registration); _DSM/_DOD stay ours. On 1.9.0 NVRM it behaves as before.
# GPUBundles (plugin, translator, Vulkan, nvrm610.conf), firmware, boot-args, config.plist, DisplayProductID override and nvflip
# are NOT touched. Backs up the kexts, the kernel collection and the ESP's NVDSM.kext first; any failure puts them back.
# Usage: sudo -E ESP_UUID=<uuid> bash install-kexts-115.sh [--check]   (macOS 15; on 26 see tahoe/update-26.sh)   (--check builds the test collection only, changes nothing)
# Undo:  sudo bash rollback-kexts-115.sh <backup dir printed below>   (kexts part also works from Recovery, see that script)
set -u
HERE=$(cd "$(dirname "$0")" && pwd); P="$HERE/payload"; SYS=$(cd "$HERE/.." && pwd)
KEXTS="NVRM NVAccel NVRMFB NVRMAGDC"; EXT=/Library/Extensions; NM=/Library/NullMoth
KC=/Library/KernelCollections/AuxiliaryKernelExtensions.kc
KB=/System/Library/KernelCollections/BootKernelExtensions.kc; KS=/System/Library/KernelCollections/SystemKernelExtensions.kc
KARG=(--allow-missing-kdk); [ -f /System/Library/Kernels/kernel ] && KARG+=(--kernel /System/Library/Kernels/kernel)
ESPUUID=${ESP_UUID:?set ESP_UUID to the Partition UUID of your OpenCore ESP (diskutil info <disk>)}
DEV=$(for d in $(diskutil list | awk '/ EFI /{print $NF}'); do [ "$(diskutil info $d | awk -F': *' '/Partition UUID/{print $2}')" = $ESPUUID ] && { echo $d; break; }; done); DEV=${DEV:-ESP-not-found}   # disk numbers occasionally change (NVMe probe order): find the ESP by UUID
export PATH=/usr/local/bin:$PATH MTOOLS_SKIP_CHECK=1; I=(-i /dev/$DEV)
DSM="$P/ESP/NVDSM.kext"
BK=""; INSTALLING=0
die() { echo "   STOP: $*" >&2
  if [ "$INSTALLING" = 1 ]; then echo "   restoring the previous kexts ..." >&2; /bin/bash "$HERE/rollback-kexts-115.sh" "$BK" || echo "   RESTORE INCOMPLETE: run rollback-kexts-115.sh $BK" >&2; fi
  exit 1; }
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
[ "$(id -u)" -eq 0 ] || die "run with sudo"
[ "$(sw_vers -productVersion | cut -d. -f1)" = 15 ] || die "payload is for macOS 15"
want() { [ "$(sha "$1")" = "$2" ] || die "payload file changed: $1"; }
want "$P/Library/Extensions/NVRM.kext/Contents/MacOS/NVRM"             9794974b35966a89fe90b272ceebcbfa30999e46af314203d0b816f339bae83f
want "$P/Library/Extensions/NVRMFB.kext/Contents/MacOS/NVRMFB"         79d60d2406ccbe1b42b9bc394212e842e11d7409daade695bd5cdb31f6ca7944
want "$P/Library/Extensions/NVRMAGDC.kext/Contents/MacOS/NVRMAGDC"     270f9ef9ac9d2482689ed4d63d422e705e439509d0e3b62fc6bc96fdc9e693ed
want "$P/Library/NullMoth/kexts/15/NVAccel.kext/Contents/MacOS/NVAccel" 63eba4a8f3ff069d1819b84b9bdd5fb7c53b9f7ce772470a73a8f6a13e07b651
want "$P/Library/NullMoth/kexts/26/NVAccel.kext/Contents/MacOS/NVAccel" 118c5212ebb1ddddee5016df6b629d2b916773a9f379f1f1ba95e315022d2cef
want "$DSM/Contents/MacOS/NVDSM"                                        ea766150375671445416be9f7e450536d8d299cd798d231eed9917484f1a526d
for k in NVRM NVRMFB; do codesign --verify "$P/Library/Extensions/$k.kext" 2>/dev/null || die "$k.kext signature invalid"; done
# what is installed now must be the 1.9.0 set this was built against (so the backup is a known-good state). All hashes in this
# script are the AUTHOR'S builds: put in your own (sha256 of your patched NVRM / NVRMFB / NVDSM and of the stock files).
[ "$(sha $EXT/NVRM.kext/Contents/MacOS/NVRM)" = 27ed43cb82c00d56c4a5b86a088db98fccd5fe42198022e09893aa36c64b66a7 ] || die "installed NVRM is not 27ed43cb (1.9.0 + ours)"
[ "$(sha $EXT/NVRMFB.kext/Contents/MacOS/NVRMFB)" = 3b198714762578a519661b247190aa3e264d5a986880b14ad2ed3d696f357a2c ] || die "installed NVRMFB is not 3b198714"
[ "$(diskutil info $DEV | awk -F': *' '/Partition UUID/{print $2}')" = $ESPUUID ] || die "$DEV is not the expected ESP"
command -v mcopy >/dev/null || die "mtools missing"
kp() { [ "$1" = NVAccel ] && echo "$P/Library/NullMoth/kexts/15/NVAccel.kext" || echo "$P/Library/Extensions/$1.kext"; }

echo "== 1. test kernel collection with the new kexts"
T=$(mktemp -d /var/tmp/nv115.XXXX) && mkdir -p "$T/repo" || die "tmp dir"
for x in "$EXT"/*.kext; do n=$(basename "$x" .kext); case " $KEXTS " in *" $n "*) ;; *) cp -R "$x" "$T/repo/";; esac; done
for k in $KEXTS; do cp -R "$(kp $k)" "$T/repo/" || die "copy $k"; done
chown -R root:wheel "$T/repo" && chmod -R go-w "$T/repo"
kmutil create -n aux --volume-root / "${KARG[@]}" -B $KB -S $KS --repository "$T/repo" -A "$T/aux.kc" -z >"$T/kmutil.log" 2>&1 || { tail -20 "$T/kmutil.log"; die "test collection failed (nothing changed)"; }
INS=$(kmutil inspect -a x86_64 -A "$T/aux.kc" 2>/dev/null) || die "cannot inspect test collection"
for k in $KEXTS; do printf '%s\n' "$INS" | grep -oE 'com\.nullmoth\.[A-Za-z0-9]+' | grep -Fxq "com.nullmoth.$k" || { tail -20 "$T/kmutil.log"; die "kmutil refused $k (nothing changed)"; }; done
echo "   ok: all four kexts accepted"
diskutil unmount $DEV >/dev/null 2>&1 || true
mdir "${I[@]}" ::/EFI/OC/Kexts/NVDSM.kext/Contents/MacOS >/dev/null || die "no NVDSM.kext on the ESP (nothing changed)"
echo "   ok: ESP readable, NVDSM.kext present"
[ "${1:-}" = --check ] && { rm -rf "$T"; echo "CHECK PASS (nothing changed)"; exit 0; }

BK=$(mktemp -d "$NM/backup-115-$(date +%Y%m%d-%H%M%S).XXXXXX") || die "backup dir"
echo "== 2. backup -> $BK"
for k in $KEXTS; do cp -Rp "$EXT/$k.kext" "$BK/" || die "backup $k"; done
cp -p "$KC" "$BK/AuxiliaryKernelExtensions.kc" || die "backup kc"
ditto "$NM/kexts" "$BK/kexts" || die "backup kexts cache"; cp -p "$NM/os-major" "$BK/os-major" 2>/dev/null
mcopy "${I[@]}" -n -s ::/EFI/OC/Kexts/NVDSM.kext "$BK/" && [ -f "$BK/NVDSM.kext/Contents/MacOS/NVDSM" ] || die "ESP NVDSM backup failed (nothing changed)"
echo "   ok"

echo "== 3. kexts + auxiliary kernel collection"
INSTALLING=1
for k in $KEXTS; do rm -rf "$EXT/$k.kext" && ditto "$(kp $k)" "$EXT/$k.kext" || die "copy $k"; done
for t in 15 26; do rm -rf "$NM/kexts/$t/NVAccel.kext" && ditto "$P/Library/NullMoth/kexts/$t/NVAccel.kext" "$NM/kexts/$t/NVAccel.kext" || die "copy accelerator cache $t"
  (cd "$NM/kexts/$t" && find NVAccel.kext -type f -exec shasum -a 256 '{}' \;) > "$NM/kexts/$t/SHA256SUMS" || die "cache manifest"; done
chown -R root:wheel "$NM/kexts" && chmod -R go-w "$NM/kexts"
for k in $KEXTS; do chown -R root:wheel "$EXT/$k.kext" && chmod -R 755 "$EXT/$k.kext" || die "perms $k"; done
NEWKC="$KC.nv115-new"; rm -f "$NEWKC"
kmutil create -n aux --volume-root / "${KARG[@]}" -B $KB -S $KS --repository "$EXT" -A "$NEWKC" -z >"$T/kmutil2.log" 2>&1 || { tail -20 "$T/kmutil2.log"; die "live collection build failed"; }
[ -s "$NEWKC" ] || die "live collection empty"
INS=$(kmutil inspect -a x86_64 -A "$NEWKC" 2>/dev/null) || die "cannot inspect live collection"
for k in $KEXTS; do printf '%s\n' "$INS" | grep -oE 'com\.nullmoth\.[A-Za-z0-9]+' | grep -Fxq "com.nullmoth.$k" || die "$k missing from live collection"; done
mv -f "$NEWKC" "$KC" || die "cannot publish collection"
echo "   ok"

echo "== 4. NVDSM on the ESP"
mdeltree "${I[@]}" ::/EFI/OC/Kexts/NVDSM.kext && mcopy "${I[@]}" -s -n "$DSM" ::/EFI/OC/Kexts/ || die "ESP copy failed"
sync; mcopy "${I[@]}" -n ::/EFI/OC/Kexts/NVDSM.kext/Contents/MacOS/NVDSM "$T/nvdsm" && cmp -s "$T/nvdsm" "$DSM/Contents/MacOS/NVDSM" || die "ESP read-back differs"
mcopy "${I[@]}" -n ::/EFI/OC/Kexts/NVDSM.kext/Contents/Info.plist "$T/nvdsm.plist" && cmp -s "$T/nvdsm.plist" "$DSM/Contents/Info.plist" || die "ESP Info.plist read-back differs"
echo "   ok  NVDSM $(sha "$DSM/Contents/MacOS/NVDSM" | cut -c1-8)"
INSTALLING=0; rm -rf "$T"

echo "== 5. efiguard snapshot (so it keeps the new NVDSM)"
zsh "$SYS/efiguard/install.sh" 2>&1 | tail -3 || echo "   NOTE: efiguard refresh failed - run: sudo zsh $SYS/efiguard/install.sh"
echo
echo "installed. Backup: $BK"
echo "REBOOT (do not kill WindowServer): sudo shutdown -r now"
echo "UNDO: sudo bash $HERE/rollback-kexts-115.sh $BK    (screen black / panic: from Recovery, see rollback-kexts-115.sh)"
