#!/bin/bash
# Run with sudo. Test for the garbled/black UI patches: until the next reboot, start WindowServer with
# NVMTL_NO_SURFACE_SHARE=1 so NullMoth's Metal driver keeps IOSurface textures private (copies) instead of sharing one
# VRAM copy per surface across processes. Restarts WindowServer (you get the login screen). A reboot undoes it.
set -u
[ "$(id -u)" -eq 0 ] || { echo "STOP: run with sudo"; exit 1; }
K=NVMTL_NO_SURFACE_SHARE
# launchctl setenv acts on the caller's bootstrap; run it in launchd's own (system) bootstrap so WindowServer inherits it.
launchctl bsexec 1 /bin/launchctl setenv $K 1
V=$(launchctl bsexec 1 /bin/launchctl getenv $K)
echo "system bootstrap: $K='$V'"
if [ "$V" != 1 ]; then
  # Fallback: a one-shot job in the system domain.
  launchctl submit -l local.nvmtlenv -- /bin/launchctl setenv $K 1; sleep 2; launchctl remove local.nvmtlenv 2>/dev/null
  launchctl submit -l local.nvmtlenv2 -- /bin/sh -c "/bin/launchctl getenv $K > /private/var/tmp/nvmtlenv.txt"; sleep 2; launchctl remove local.nvmtlenv2 2>/dev/null
  V=$(cat /private/var/tmp/nvmtlenv.txt 2>/dev/null); echo "system domain via job: $K='$V'"
fi
[ "$V" = 1 ] || { echo "STOP: could not set $K for WindowServer"; exit 1; }
echo "restarting WindowServer in 3 s"; sleep 3; sysctl -w debug.nvaccel_iop=1 >/dev/null; killall -9 WindowServer
