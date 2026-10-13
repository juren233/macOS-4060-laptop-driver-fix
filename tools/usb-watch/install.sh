#!/bin/bash
# sudo bash install.sh          install and start (log: /var/log/usb-watch/usb-watch.log)
# sudo bash install.sh remove   uninstall (logs are kept)
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "STOP: run with sudo"; exit 1; }
HERE=$(cd "$(dirname "$0")" && pwd); PL=/Library/LaunchDaemons/local.usbwatch.plist
if [ "${1:-}" = remove ]; then
  launchctl bootout system "$PL" 2>/dev/null || true; pkill -f "log stream.*usbd" 2>/dev/null || true
  rm -f "$PL" /usr/local/sbin/usb-watch.sh; echo "removed"; exit 0
fi
mkdir -p /usr/local/sbin
install -m 755 -o root -g wheel "$HERE/usb-watch.sh" /usr/local/sbin/usb-watch.sh
install -m 644 -o root -g wheel "$HERE/local.usbwatch.plist" "$PL"
plutil -lint "$PL" >/dev/null
launchctl bootout system "$PL" 2>/dev/null || true; pkill -f "log stream.*usbd" 2>/dev/null || true   # the old version's live stream
launchctl bootstrap system "$PL"
sleep 3; echo "installed; log: /var/log/usb-watch/usb-watch.log"; tail -15 /var/log/usb-watch/usb-watch.log
