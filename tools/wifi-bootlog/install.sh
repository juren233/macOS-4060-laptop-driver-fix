#!/bin/bash
# sudo bash install.sh          install (captures from the next boot on)
# sudo bash install.sh spindump install + sample kernel stacks once on the next boot
# sudo bash install.sh remove   uninstall (logs in /var/log/wifi-bootlog are kept)
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "STOP: run with sudo"; exit 1; }
HERE=$(cd "$(dirname "$0")" && pwd); PL=/Library/LaunchDaemons/local.wifibootlog.plist
if [ "${1:-}" = remove ]; then
  launchctl bootout system "$PL" 2>/dev/null || true; rm -f "$PL" /usr/local/sbin/wifi-bootlog.sh; echo "removed"; exit 0
fi
mkdir -p /usr/local/sbin
install -m 755 -o root -g wheel "$HERE/wifi-bootlog.sh" /usr/local/sbin/wifi-bootlog.sh
install -m 644 -o root -g wheel "$HERE/local.wifibootlog.plist" "$PL"
plutil -lint "$PL" >/dev/null
launchctl bootout system "$PL" 2>/dev/null || true
[ "${1:-}" = spindump ] || launchctl bootstrap system "$PL"
[ "${1:-}" = spindump ] && { mkdir -p /var/log/wifi-bootlog; touch /var/log/wifi-bootlog/do-spindump; echo "spindump armed for the next boot"; }
echo "installed; logs go to /var/log/wifi-bootlog/ (first run now, for the current boot)"
