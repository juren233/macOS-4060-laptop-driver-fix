#!/bin/zsh
# ============================================================================================================
# LOCAL HARDENING - DO NOT EDIT, DELETE OR "CLEAN UP" THIS FILE OR /Library/NullMoth/efiguard.
# Keeps the fixes that live on the OpenCore ESP alive: AppleALC + alcid (built-in audio), Wi-Fi/BT kexts,
# NVDSM, BrightnessKeys, VoodooI2C touchpad, SSDT-PS2KEYS ... Run by LaunchDaemon local.efiguard at boot and every 6 h.
# Install / refresh the snapshot after a DELIBERATE EFI change:  sudo -E ESP_DEV=<disk> ESP_UUID=<uuid> zsh efiguard/install.sh
# Policy (same spirit as nvguard): repair only what is MISSING or has lost one of OUR fixes; a file that merely differs
# from the snapshot (a deliberate update?) is left alone and logged as ATTENTION. The ESP is mounted read-only first and
# written only when a repair is needed; every changed file is copied to /Library/NullMoth/efiguard-replaced first.
# Never touches OpenCore.efi, Limine or the boot entries.
# ============================================================================================================
G=${EFIGUARD_SNAP:-/Library/NullMoth/efiguard}
REPL=${EFIGUARD_REPLACED:-/Library/NullMoth/efiguard-replaced}
LOG=${EFIGUARD_LOG:-/var/log/efiguard.log}
DEV=$(sed -n "s/^DEV=//p" $G/esp.conf 2>/dev/null); UUID=$(sed -n "s/^UUID=//p" $G/esp.conf 2>/dev/null)   # written by install.sh from ESP_UUID
# disk numbers move between boots (seen on macOS 26): look the ESP up by its partition UUID, esp.conf DEV is only a hint
[[ -n $UUID && -z $EFIGUARD_ROOT ]] && for d in $(diskutil list 2>/dev/null | awk '/ EFI /{print $NF}'); do [[ "$(diskutil info $d 2>/dev/null | awk -F': *' '/Partition UUID/{print $2}')" == $UUID ]] && { DEV=$d; break; }; done
PB=/usr/libexec/PlistBuddy
log() { print -r -- "$(date '+%F %T') $*" >> $LOG; }
sha() { shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1; }
[[ -n $DEV && -n $UUID || -n $EFIGUARD_ROOT ]] || { log "no esp.conf in $G - run install.sh"; exit 0; }
[[ -f $G/manifest.txt && -f $G/EFI/OC/config.plist ]] || { log "no snapshot in $G - run install.sh"; exit 0; }

MP=; OURS=0
mount_esp() {   # $1 = ro | rw
  if [[ -n $EFIGUARD_ROOT ]]; then MP=$EFIGUARD_ROOT; return 0; fi
  [[ "$(diskutil info $DEV 2>/dev/null | awk -F': *' '/Partition UUID/{print $2}')" == $UUID ]] || { log "STOP: $DEV is not the expected ESP"; return 1; }
  # somebody (the user editing the EFI, an installer) has it mounted: never unmount it under them - read it where it is, repair later
  local there=$(mount | awk -v d=/dev/$DEV '$1==d{print $3; exit}')
  if [[ -n $there ]]; then
    [[ $1 == rw ]] && { log "the ESP is mounted at $there by someone else - NOT repaired now, next run retries"; return 1; }
    MP=$there; OURS=0; return 0
  fi
  MP=$(mktemp -d /private/var/tmp/efig.XXXX); OURS=1
  local opt=; [[ $1 == ro ]] && opt="-o rdonly"
  mount -t msdos ${=opt} /dev/$DEV $MP 2>/dev/null || mount -F -t msdos ${=opt} /dev/$DEV $MP 2>/dev/null || { log "cannot mount $DEV ($1)"; rmdir $MP 2>/dev/null; MP=; OURS=0; return 1; }
}
umount_esp() {   # only ever unmounts a mount we made ourselves
  [[ -n $EFIGUARD_ROOT ]] && return 0
  sync
  if [[ $OURS == 1 && -n $MP ]]; then umount $MP 2>/dev/null || diskutil unmount force $DEV >/dev/null 2>&1; rmdir $MP 2>/dev/null; fi
  MP=; OURS=0
}
trap 'umount_esp' EXIT

# ---- detection (read-only) ------------------------------------------------------------------------------------
detect() {
  missing=(); changed=(); cfg_bad=(); cfg_full=0
  local h p
  while read -r h p; do
    [[ -n $p ]] || continue
    if [[ ! -e $MP/$p ]]; then missing+=($p)
    elif [[ $(sha $MP/$p) != $h ]]; then changed+=($p); fi
  done < $G/manifest.txt
  local C=$MP/EFI/OC/config.plist S=$G/EFI/OC/config.plist
  if [[ ! -f $C ]] || ! plutil -lint $C >/dev/null 2>&1; then cfg_full=1; cfg_bad+=("config.plist missing or does not parse"); return; fi
  local line i en
  while read -r line; do
    [[ -n $line ]] || continue
    i=$(kext_index $C $line)
    if [[ -z $i ]]; then cfg_bad+=("kext entry missing: $line"); [[ $line == Lilu.kext ]] && cfg_full=1
    else en=$($PB -c "Print :Kernel:Add:$i:Enabled" $C 2>/dev/null); [[ $en == true ]] || cfg_bad+=("kext entry disabled: $line"); fi
  done < $G/required-kexts.txt
  local cur=$($PB -c "Print :NVRAM:Add:7C436110-AB2A-4BBB-A880-FE41995C9F82:boot-args" $C 2>/dev/null) tok
  while read -r tok; do
    [[ -n $tok ]] || continue
    if [[ $tok == *= ]]; then [[ " $cur " == *" $tok"* ]] || cfg_bad+=("boot-arg missing: ${tok}<value>")
    else [[ " $cur " == *" $tok "* ]] || cfg_bad+=("boot-arg missing: $tok"); fi
  done < $G/required-bootargs.txt
}
kext_index() {   # $1 plist, $2 BundlePath -> index (empty if absent)
  local i=0 b
  while b=$($PB -c "Print :Kernel:Add:$i:BundlePath" $1 2>/dev/null); do [[ $b == $2 ]] && { print $i; return; }; i=$((i+1)); done
}

# ---- repair (ESP mounted read-write) --------------------------------------------------------------------------
keep() { mkdir -p $REPL/$TS; local d=$REPL/$TS/${1//\//__}; cp -p "$1" "$d" 2>/dev/null; }
repair() {
  local TS=$(date +%Y%m%d-%H%M%S) p C=$MP/EFI/OC/config.plist S=$G/EFI/OC/config.plist
  for p in $missing; do mkdir -p $MP/${p:h}; cp -p $G/$p $MP/$p && log "restored missing file $p" || log "RESTORE FAILED $p"; done
  [[ ${#cfg_bad} -gt 0 ]] || return
  [[ -f $C ]] && { mkdir -p $REPL/$TS; cp -p $C $REPL/$TS/config.plist; }
  if [[ $cfg_full == 1 ]]; then
    cp $S $C && log "config.plist: restored whole snapshot (${cfg_bad[1]}); previous copy in $REPL/$TS"; return; fi
  local line i j tmp=$(mktemp /private/var/tmp/efig-ent.XXXX) n tok cur BA=":NVRAM:Add:7C436110-AB2A-4BBB-A880-FE41995C9F82:boot-args"
  while read -r line; do
    [[ -n $line ]] || continue
    i=$(kext_index $C $line)
    if [[ -z $i ]]; then
      j=$(kext_index $S $line); [[ -n $j ]] || { log "config: snapshot has no entry for $line"; continue; }
      $PB -x -c "Print :Kernel:Add:$j" $S > $tmp
      n=0; while $PB -c "Print :Kernel:Add:$n:BundlePath" $C >/dev/null 2>&1; do n=$((n+1)); done
      $PB -c "Add :Kernel:Add:$n dict" $C; $PB -c "Merge $tmp :Kernel:Add:$n" $C && log "config: re-added Kernel/Add $line (#$n)"
    elif [[ $($PB -c "Print :Kernel:Add:$i:Enabled" $C) != true ]]; then
      $PB -c "Set :Kernel:Add:$i:Enabled true" $C && log "config: re-enabled $line"
    fi
  done < $G/required-kexts.txt
  rm -f $tmp
  cur=$($PB -c "Print $BA" $C 2>/dev/null)
  while read -r tok; do
    [[ -n $tok ]] || continue
    if [[ $tok == *= ]]; then
      [[ " $cur " == *" $tok"* ]] && continue
      tok=$(print -r -- ${=$($PB -c "Print $BA" $S)} | tr ' ' '\n' | grep "^$tok" | head -1)   # value from the snapshot
    else [[ " $cur " == *" $tok "* ]] && continue; fi
    [[ -n $tok ]] || continue
    cur="$cur $tok"; $PB -c "Set $BA $cur" $C && log "config: re-added boot-arg $tok"
  done < $G/required-bootargs.txt
  if ! plutil -lint $C >/dev/null 2>&1; then cp $REPL/$TS/config.plist $C 2>/dev/null; log "config.plist REPAIR PRODUCED AN INVALID FILE - previous copy put back"; fi
}

mount_esp ro || exit 0
# the Recovery rescue config (tahoe/rescue: rescue.sh safe) disables kexts on purpose: hands off until it is restored
[[ -f $MP/EFI/OC/rescue/ACTIVE ]] && { log "rescue config active (EFI/OC/rescue/ACTIVE) - not checking"; exit 0; }
detect
if [[ ${#missing} -eq 0 && ${#cfg_bad} -eq 0 ]]; then
  log "ESP check: all fixes present$([[ ${#changed} -gt 0 ]] && echo "; ATTENTION ${#changed} file(s) differ from the snapshot (deliberate update? re-run install.sh): ${changed[1,3]}")"
  exit 0
fi
log "ESP check: ${#missing} file(s) missing, config problems: ${#cfg_bad}${cfg_bad:+ ($cfg_bad[1])}"
umount_esp; mount_esp rw || { log "cannot mount the ESP read-write - NOT repaired"; exit 0; }
repair
detect
[[ ${#missing} -eq 0 && ${#cfg_bad} -eq 0 ]] && log "ESP repaired: all fixes present again" || log "ATTENTION: still ${#missing} missing, ${#cfg_bad} config problems after repair"
exit 0
