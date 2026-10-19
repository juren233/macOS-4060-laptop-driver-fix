#!/bin/bash
# System sleep, step 1: let NVRM join the power tree (drop the -nvrmnopm boot-arg) so the NullMoth 2.3.7 kernel's
# S3 support (upstream 2.0.3 5583ee9, PR #182: RM standby with all VRAM kept, PCI/ReBAR restore, NVRMFB wake work)
# runs on the next boot. Sleep ITSELF stays off (SleepDisabled=1) until sleep-test.sh opens it for one timed test.
#   sudo bash ~/work/nvidia-setup/sleep/enable-sleep.sh      then reboot, then: zsh check-sleep.sh
# Undo: sudo bash rollback-sleep.sh (puts -nvrmnopm back).
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); NS=$(dirname "$HERE"); SYS=$(dirname "$NS")/system
OCBA=$NS/wifibt/oc-bootarg.sh; EFIG=$SYS/efiguard/install.sh; REQ=/Library/NullMoth/efiguard/required-bootargs.txt
die() { echo "STOP: $*"; exit 1; }
[ "$(id -u)" -eq 0 ] || die "run with sudo"

echo "== 1. preconditions"
for k in NVRM NVRMFB NVAccel; do
  kextstat 2>/dev/null | grep -q "com.nullmoth.$k (2.3.7)" || die "com.nullmoth.$k 2.3.7 is not loaded"
done
PM=$(ioreg -r -c NVRM -d1 -l | awk -F'"' '/"nvrm-pm"/{print $4; exit}')
echo "   NVRM nvrm-pm: ${PM:-?}"
case " $(sysctl -n kern.bootargs) " in *" -nvrmnopm "*) ;; *) echo "   NOTE: this boot already runs without -nvrmnopm";; esac
[ -f "$OCBA" ] && [ -f "$EFIG" ] || die "missing $OCBA or $EFIG"
[ -f /Library/LaunchDaemons/local.efiguard.plist ] || die "efiguard is not installed (it would not keep the change)"
pmset -g | grep -Eq "SleepDisabled[[:space:]]+1" || die "SleepDisabled is not 1 - not touching anything"
echo "   ok"

echo "== 2. backup"
BK=$HERE/backup/enable-$(date +%Y%m%d-%H%M%S); mkdir -p "$BK" || die "cannot create $BK"
sysctl -n kern.bootargs > "$BK/boot-args.txt"
pmset -g custom > "$BK/pmset-custom.txt"; pmset -g > "$BK/pmset.txt"
echo "   $BK"

echo "== 3. boot-args: remove -nvrmnopm from the ESP's config.plist"
OUT=$(bash "$OCBA" remove -nvrmnopm 2>&1); RC=$?; echo "$OUT" | sed 's/^/   /'
[ $RC -eq 0 ] || die "oc-bootarg.sh failed (ESP restore copy is in its backup line above)"
NEWBA=$(echo "$OUT" | sed -n 's/^ *-> //p'); [ -z "$NEWBA" ] && NEWBA=$(echo "$OUT" | sed -n 's/^boot-args unchanged: //p')
[ -n "$NEWBA" ] || die "could not read the new boot-args back"
case " $NEWBA " in *" -nvrmnopm "*) die "-nvrmnopm still in config.plist";; esac
for a in nvfbhidpi=1 nvrmmapowner=0 nvfb=1 nvaccel=1; do case " $NEWBA " in *" $a "*) ;; *) die "boot-arg $a went missing";; esac; done
echo "   ok"

echo "== 4. efiguard snapshot (otherwise its required list puts -nvrmnopm back)"
zsh "$EFIG" 2>&1 | tail -3 | sed 's/^/   /'
[ -f "$REQ" ] || die "efiguard snapshot missing: run sudo zsh $EFIG"
grep -qx -- "-nvrmnopm" "$REQ" && die "efiguard still requires -nvrmnopm: run sudo zsh $EFIG"
echo "   ok: efiguard requires $(tr '\n' ' ' < "$REQ")"

echo "== 5. power settings for the trial (old values in $BK/pmset-custom.txt)"
# hibernatemode 0: S3 only, never a hibernate image (hibernation is untested upstream).
# powernap / proximitywake / standby / autopoweroff off: fewer dark wakes and no deep standby while we test.
# Only keys this Mac's pmset lists are set (macOS 26 on this board does not list standby/autopoweroff).
for kv in "hibernatemode 0" "powernap 0" "proximitywake 0" "standby 0" "autopoweroff 0"; do
  k=${kv% *}
  if grep -Eq "^[[:space:]]*$k[[:space:]]" "$BK/pmset-custom.txt"; then pmset -a $kv && echo "   $kv" || echo "   NOTE: pmset -a $kv failed"; fi
done
pmset -g | grep -Eq "SleepDisabled[[:space:]]+1" || die "SleepDisabled changed unexpectedly"
echo "   SleepDisabled stays 1 (lid and Apple menu still do not sleep)"

echo
echo "done. Reboot now, then run:  zsh $HERE/check-sleep.sh"
echo "undo: sudo bash $HERE/rollback-sleep.sh"
