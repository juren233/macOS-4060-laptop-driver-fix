#!/bin/bash
# Run with sudo:  deny-test.sh <process>   (or: deny-test.sh restore)
# Keeps NullMoth's Metal driver away from one app (it then draws on the CPU) and relaunches it, to see whether the app's own
# GPU drawing is what WindowServer later shows wrongly. No reboot needed.
set -u
[ "$(id -u)" -eq 0 ] || { echo "STOP: run with sudo"; exit 1; }
D=$(cd "$(dirname "$0")" && pwd); AL=/Library/GPUBundles/nvmtl-allow.txt; ORIG="$D/backup/nvmtl-allow.txt.orig"
[ -f "$ORIG" ] || cp -p "$AL" "$ORIG" || { echo "STOP: could not back up $AL"; exit 1; }
N="${1:-}"; [ -n "$N" ] || { echo "usage: sudo $0 <process>|restore"; exit 1; }
if [ "$N" = restore ]; then cp "$ORIG" "$AL"; else { echo "-$N"; cat "$ORIG"; } > "$AL"; fi
chmod 644 "$AL"; echo "allow list now:"; cat "$AL"
[ "$N" = restore ] || { killall "$N" 2>/dev/null; echo "relaunched $N"; }
echo "DONE"
