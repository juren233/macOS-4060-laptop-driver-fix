#!/bin/bash
# Capture VoodooPS2 scancode log (LogScanCodes must be on). Run: sudo bash keycap.sh
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }
echo ">>> 现在 8 秒内只按一次 PrtSc，然后什么都别按"
for i in 8 7 6 5 4 3 2 1; do printf "%s " $i; sleep 1; done; echo
dmesg | grep -a -E 'ApplePS2Keyboard: sending key|VoodooPS2Keyboard' | tail -40 > "$(dirname "$0")/keycap.txt"
chmod 644 "$(dirname "$0")/keycap.txt"; echo "saved $(wc -l < "$(dirname "$0")/keycap.txt") lines"
