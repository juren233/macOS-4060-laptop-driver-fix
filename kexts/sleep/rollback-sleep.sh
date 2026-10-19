#!/bin/bash
# Undo enable-sleep.sh: sleep off, -nvrmnopm back in the boot-args (NVRM out of the power tree, as before),
# efiguard requires it again, power settings back from the enable backup. Then reboot.
#   sudo bash ~/work/nvidia-setup/sleep/rollback-sleep.sh
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); NS=$(dirname "$HERE"); SYS=$(dirname "$NS")/system
OCBA=$NS/wifibt/oc-bootarg.sh; EFIG=$SYS/efiguard/install.sh; REQ=/Library/NullMoth/efiguard/required-bootargs.txt
die() { echo "STOP: $*"; exit 1; }
[ "$(id -u)" -eq 0 ] || die "run with sudo"

echo "== 1. sleep off"
# sleepguard (system/sleepguard) would open sleep again at the next boot while NVRM still runs: switch it to off first
[ -f /Library/LaunchDaemons/local.sleepguard.plist ] && { zsh "$SYS/sleepguard/install.sh" off >/dev/null && echo "   sleepguard: off" || die "sleepguard install.sh off failed"; }
pmset -a disablesleep 1 || die "pmset disablesleep 1 failed"
rm -f /Library/NullMoth/sleeptest-active /Library/LaunchDaemons/local.sleeptest.guard.plist
echo "   SleepDisabled 1"

echo "== 2. boot-args: add -nvrmnopm"
OUT=$(bash "$OCBA" add -nvrmnopm 2>&1); RC=$?; echo "$OUT" | sed 's/^/   /'
[ $RC -eq 0 ] || die "oc-bootarg.sh failed"
NEWBA=$(echo "$OUT" | sed -n 's/^ *-> //p'); [ -z "$NEWBA" ] && NEWBA=$(echo "$OUT" | sed -n 's/^boot-args unchanged: //p')
case " $NEWBA " in *" -nvrmnopm "*) echo "   ok";; *) die "-nvrmnopm not in config.plist after the edit";; esac

echo "== 3. efiguard snapshot (requires -nvrmnopm again)"
zsh "$EFIG" 2>&1 | tail -3 | sed 's/^/   /'
grep -qx -- "-nvrmnopm" "$REQ" && echo "   ok" || echo "   NOTE: efiguard does not list -nvrmnopm: run sudo zsh $EFIG"

echo "== 4. power settings from the newest enable backup"
BK=$(ls -d "$HERE"/backup/enable-* 2>/dev/null | sort | tail -1)
if [ -n "$BK" ] && [ -f "$BK/pmset-custom.txt" ]; then
  # pmset -g custom lists "Battery Power:" then "AC Power:"; restore only the keys enable-sleep.sh changes
  awk '/^Battery Power:/{p="-b"} /^AC Power:/{p="-c"} $1~/^(hibernatemode|powernap|proximitywake|standby|autopoweroff)$/ && p!=""{print p, $1, $2}' "$BK/pmset-custom.txt" |
  while read -r p k v; do pmset $p "$k" "$v" && echo "   pmset $p $k $v" || echo "   NOTE: pmset $p $k $v failed"; done
else
  echo "   no enable backup found - power settings left as they are"
fi

echo
echo "done. Reboot now; after it: ioreg -r -c NVRM -d1 -l | grep nvrm-pm   should say off (-nvrmnopm)"
