#!/bin/bash
# macOS 26 (Tahoe) step 2 of 3 - the same idea as NullMoth's own "nullmoth-setup.sh --update prepare|finish" (1.15.0), for our
# patched driver and our EFI:
#   prepare (on macOS 15, right before starting the update in System Settings):
#     park the driver (-nvoff), installer screen settings (ResizeGpuBars -1, ResizeAppleGpuBars 0, IONDRVSupport exclude off),
#     install LaunchDaemon local.nvtahoe that runs "finish" at every start until the update has happened.
#   finish (by itself, at the first start of macOS 26): NVAccel -> the macOS 26 build (/Library/NullMoth/kexts/26, stock 1.15.0),
#     new auxiliary kernel collection (all four NullMoth kexts must be in it), the EFI settings back as they were, one restart.
#     Any failure leaves the driver parked (the screen runs on the firmware framebuffer) and writes why to the log.
#   cancel: undo prepare without updating (or after a failed finish: settings back, NVAccel unchanged).
# Usage: sudo -E ESP_UUID=<uuid> bash update-26.sh prepare | cancel        log: /Library/NullMoth/tahoe/update.log
# Needs prep-efi-26.sh applied and booted once (RestrictEvents, -no_compat_check, AirportItlwm-Tahoe, NVDSM/BTLEFix for 26).
set -u
ST=/Library/NullMoth/tahoe; PEND=$ST/pending; LOG=$ST/update.log; PL=/Library/LaunchDaemons/local.nvtahoe.plist
ESPUUID=${ESP_UUID:-$(cat /Library/NullMoth/tahoe/esp-uuid 2>/dev/null)};   # prepare stores it for the boot-time finish
[ -n "$ESPUUID" ] || { echo "STOP: run with sudo -E ESP_UUID=<Partition UUID of your OpenCore ESP>"; exit 1; }
 PB=/usr/libexec/PlistBuddy
DEV=$(for d in $(diskutil list | awk '/ EFI /{print $NF}'); do [ "$(diskutil info $d | awk -F': *' '/Partition UUID/{print $2}')" = $ESPUUID ] && { echo $d; break; }; done)
DEV=${DEV:-ESP-not-found}   # disk numbers occasionally change (two NVMe drives, probe order varies: disk1s4 / disk0s4): find the ESP by its partition UUID
BA=":NVRAM:Add:7C436110-AB2A-4BBB-A880-FE41995C9F82:boot-args"
NVA26=118c5212ebb1ddddee5016df6b629d2b916773a9f379f1f1ba95e315022d2cef
KC=/Library/KernelCollections/AuxiliaryKernelExtensions.kc
MODE=${1:-}; MAJ=$(sw_vers -productVersion | cut -d. -f1); MP=""
say() { echo "$(date '+%F %T') [$MODE] $*" | tee -a "$LOG"; }
die() { say "STOP: $*"; esp_off; exit 1; }
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
esp_on() {   # mount the ESP read-write at $MP; efiguard may hold it read-only for a few seconds at boot: wait for it
  [ "$(diskutil info $DEV | awk -F': *' '/Partition UUID/{print $2}')" = $ESPUUID ] || die "$DEV is not the expected ESP"
  local n=0; while mount | grep -q "^/dev/$DEV "; do n=$((n+1)); [ $n -gt 60 ] && die "the ESP stays mounted by someone else"; sleep 2; done
  MP=$(mktemp -d /private/var/tmp/esp.XXXX)
  mount -t msdos /dev/$DEV "$MP" 2>/dev/null || mount -F -t msdos /dev/$DEV "$MP" || { rmdir "$MP"; MP=""; die "cannot mount $DEV"; }
  C="$MP/EFI/OC/config.plist"; [ -f "$C" ] && plutil -lint "$C" >/dev/null || die "ESP config.plist missing or does not parse"; }
esp_off() { [ -n "$MP" ] || return 0; sync; umount "$MP" 2>/dev/null || diskutil unmount force $DEV >/dev/null 2>&1; rmdir "$MP" 2>/dev/null; MP=""; }
bidx() { local i=0 p; while p=$($PB -c "Print :Kernel:Block:$i:Identifier" "$1" 2>/dev/null); do [ "$p" = com.apple.iokit.IONDRVSupport ] && { echo $i; return; }; i=$((i+1)); done; }
args() {  # $1 plist, $2 add|del, $3 arg
  local a new="" cur; cur=$($PB -c "Print $BA" "$1")
  for a in $cur; do [ "$a" = "$3" ] || new="$new $a"; done; [ "$2" = add ] && new="$new $3"; $PB -c "Set $BA ${new# }" "$1"; }
write_cfg() {  # $1 = edited copy: lint, back up the live one, write, read back
  plutil -lint "$1" >/dev/null || die "edited config does not parse (nothing written)"
  local bk="$ST/config-$MODE-$(date +%Y%m%d-%H%M%S).plist"; cp -p "$C" "$bk" || die "cannot back up config.plist"
  cp "$1" "$C" && sync && cmp -s "$1" "$C" || { cp -p "$bk" "$C"; die "config.plist write/read-back failed - previous one put back"; }
  say "config.plist written (previous: $bk)"; }

[ "$(id -u)" -eq 0 ] || { echo "STOP: run with sudo"; exit 1; }
mkdir -p "$ST"

case "$MODE" in
prepare)
  [ "$MAJ" = 15 ] || die "prepare runs on macOS 15 (this is $MAJ)"
  [ -f "$PEND" ] && die "already prepared ($PEND) - update now, or: sudo bash $0 cancel"
  [ "$(sha /Library/NullMoth/kexts/26/NVAccel.kext/Contents/MacOS/NVAccel 2>/dev/null)" = $NVA26 ] || die "/Library/NullMoth/kexts/26/NVAccel.kext is not the 1.15.0 macOS 26 build"
  # the EFI for 26 must be in place AND booted once (it was checked on 15 that way)
  bargs=$(sysctl -n kern.bootargs)
  for a in -no_compat_check revpatch=sbvmm; do case " $bargs " in *" $a "*) ;; *) die "this boot has no $a - run prep-efi-26.sh and reboot first";; esac; done
  kmutil showloaded --list-only 2>/dev/null | grep -q as.vit9696.RestrictEvents || die "RestrictEvents is not loaded - run prep-efi-26.sh and reboot first"
  free=$(df -g / | awk 'NR==2{print $4}'); [ "$free" -ge 30 ] || say "WARNING: only ${free} GB free - the macOS 26 update needs about 30-40 GB"
  esp_on
  for k in RestrictEvents AirportItlwm-Tahoe; do [ -d "$MP/EFI/OC/Kexts/$k.kext" ] || die "ESP has no $k.kext - run prep-efi-26.sh"; done
  N=$(mktemp /var/tmp/tahoe-cfg.XXXX); cp "$C" "$N"
  BAR=$($PB -c "Print :UEFI:Quirks:ResizeGpuBars" "$N"); ABAR=$($PB -c "Print :Booter:Quirks:ResizeAppleGpuBars" "$N")
  bi=$(bidx "$N"); BLK=$([ -n "$bi" ] && $PB -c "Print :Kernel:Block:$bi:Enabled" "$N")
  $PB -c "Set :UEFI:Quirks:ResizeGpuBars -1" -c "Set :Booter:Quirks:ResizeAppleGpuBars 0" "$N" || die "PlistBuddy BAR"
  [ -n "$bi" ] && { $PB -c "Set :Kernel:Block:$bi:Enabled false" "$N" || die "PlistBuddy Block"; }
  args "$N" add -nvoff
  printf 'FROM=%s\nBAR=%s\nABAR=%s\nBLK=%s\n' "$MAJ" "$BAR" "$ABAR" "$BLK" > "$PEND"
  write_cfg "$N"; rm -f "$N"; esp_off
  echo "$ESPUUID" > "$ST/esp-uuid"
  cp "$0" "$ST/update-26.sh" && chown root:wheel "$ST" "$ST/update-26.sh" && chmod 755 "$ST" "$ST/update-26.sh" || die "cannot copy myself to $ST"
  cat > "$PL" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>local.nvtahoe</string>
<key>ProgramArguments</key><array><string>/bin/bash</string><string>$ST/update-26.sh</string><string>finish</string></array>
<key>RunAtLoad</key><true/>
</dict></plist>
PLIST
  chown root:wheel "$PL"; chmod 644 "$PL"
  say "prepared: driver parked (-nvoff) and installer screen settings from the next start (was BAR=$BAR ABAR=$ABAR IONDRV-exclude=$BLK)"
  echo "Now: System Settings > General > Software Update > macOS 26. The first start of 26 finishes by itself and restarts once."
  echo "Not updating after all: sudo bash $0 cancel";;

finish|cancel)
  [ -f "$PEND" ] || { [ "$MODE" = cancel ] && echo "nothing prepared"; exit 0; }
  . "$PEND"
  if [ "$MODE" = finish ] && [ "$MAJ" = "${FROM:-15}" ]; then say "still on macOS $MAJ - waiting for the update"; exit 0; fi
  if [ "$MODE" = finish ]; then   # the Recovery rescue config is on: change nothing until it is restored
    esp_on; R=0; [ -f "$MP/EFI/OC/rescue/ACTIVE" ] && R=1; esp_off
    [ $R = 1 ] && { say "rescue config active (EFI/OC/rescue/ACTIVE) - waiting"; exit 0; }
  fi
  if [ "$MODE" = finish ]; then
    [ "$MAJ" = 26 ] || die "macOS $MAJ: this script only knows 26 - the driver stays parked"
    BK=$(mktemp -d "/Library/NullMoth/backup-tahoe-$(date +%Y%m%d-%H%M%S).XXXXXX") || die "backup dir"
    cp -Rp /Library/Extensions/NVAccel.kext "$BK/" && cp -p "$KC" "$BK/" 2>/dev/null; say "backup: $BK"
    S26=/Library/NullMoth/kexts/26/NVAccel.kext
    [ "$(sha $S26/Contents/MacOS/NVAccel)" = $NVA26 ] || die "$S26 is not the 1.15.0 macOS 26 build - the driver stays parked"
    rm -rf /Library/Extensions/NVAccel.kext && ditto $S26 /Library/Extensions/NVAccel.kext || die "NVAccel copy failed - put back with: ditto $BK/NVAccel.kext /Library/Extensions/NVAccel.kext"
    chown -R root:wheel /Library/Extensions/NV*.kext; chmod -R go-w /Library/Extensions/NV*.kext
    KARG=(--allow-missing-kdk); [ -f /System/Library/Kernels/kernel ] && KARG+=(--kernel /System/Library/Kernels/kernel)
    NEWKC="$KC.tahoe-new"; rm -f "$NEWKC"
    kmutil create -n aux --volume-root / "${KARG[@]}" -B /System/Library/KernelCollections/BootKernelExtensions.kc \
      -S /System/Library/KernelCollections/SystemKernelExtensions.kc --repository /Library/Extensions -A "$NEWKC" -z > "$ST/kmutil.log" 2>&1 \
      || die "kmutil failed ($ST/kmutil.log) - the driver stays parked"
    INS=$(kmutil inspect -a x86_64 -A "$NEWKC" 2>/dev/null)
    for k in NVRM NVAccel NVRMFB NVRMAGDC; do printf '%s\n' "$INS" | grep -oE 'com\.nullmoth\.[A-Za-z0-9]+' | grep -Fxq "com.nullmoth.$k" \
      || die "com.nullmoth.$k is not in the new kernel collection ($ST/kmutil.log) - the driver stays parked"; done
    mv -f "$NEWKC" "$KC" || die "cannot publish the kernel collection"
    echo 26 > /Library/NullMoth/os-major
    say "macOS 26 kernel collection built with all four NullMoth kexts (NVAccel ${NVA26:0:8})"
  fi
  esp_on
  N=$(mktemp /var/tmp/tahoe-cfg.XXXX); cp "$C" "$N"
  $PB -c "Set :UEFI:Quirks:ResizeGpuBars ${BAR:-13}" -c "Set :Booter:Quirks:ResizeAppleGpuBars ${ABAR:--1}" "$N" || die "PlistBuddy BAR"
  bi=$(bidx "$N"); [ -n "$bi" ] && [ -n "${BLK:-}" ] && { $PB -c "Set :Kernel:Block:$bi:Enabled $BLK" "$N" || die "PlistBuddy Block"; }
  args "$N" del -nvoff
  write_cfg "$N"; rm -f "$N"; esp_off
  rm -f "$PEND" "$PL"
  say "driver settings back (BAR=${BAR:-13} ABAR=${ABAR:--1} IONDRV-exclude=${BLK:-}), -nvoff removed, LaunchDaemon removed"
  if [ "$MODE" = finish ]; then say "restarting once"; sleep 3; /sbin/shutdown -r now; else echo "Reboot."; fi;;
*) echo "usage: sudo bash $0 prepare | cancel   (finish runs by itself at the first start of macOS 26)"; exit 1;;
esac
