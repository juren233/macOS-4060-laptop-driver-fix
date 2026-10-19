#!/bin/bash
# Read-only post-reboot verification. It does not restart Bluetooth or change NVRAM.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
PASS=0
FAIL=0

ok() { echo "PASS: $*"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $*"; FAIL=$((FAIL + 1)); }

echo "== BTLEFix v6 status"
COW=$(sysctl -n debug.btlefix_cow 2>/dev/null || true)
printf 'debug.btlefix_cow: %s\n' "${COW:-<missing>}"
case "$COW" in
	*"code 6/6"*|*"path 1/1"*) ok "the latest process patch completed" ;;
	*) bad "latest COW status is not a completed 6/6 or 1/1 result" ;;
esac

BOOT_SEC=$(sysctl -n kern.boottime 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="sec") {gsub(/,/,"",$(i+2)); print $(i+2); exit}}')
if [ -n "$BOOT_SEC" ]; then
	LOG_START=$(date -r "$BOOT_SEC" '+%Y-%m-%d %H:%M:%S')
	LOG_RANGE=(--start "$LOG_START")
else
	LOG_RANGE=(--last 1h)
fi
ALL_LOG=$(/usr/bin/log show "${LOG_RANGE[@]}" --style compact \
	--predicate 'process == "kernel" AND (eventMessage CONTAINS "BTLEFix: cow:" OR (eventMessage CONTAINS[c] "apfs_pagein" AND eventMessage CONTAINS[c] "bluetoothd"))' 2>/dev/null || true)
LOG=$(printf '%s\n' "$ALL_LOG" | grep 'BTLEFix: cow:' || true)
RING=$(sysctl -n debug.btlefix_log 2>/dev/null || true)
LOG="$LOG
$RING"
if printf '%s\n' "$LOG" | grep -Eq '(BTLEFix: )?cow: bluetoothd .*code 6/6'; then
	ok "kernel log shows bluetoothd code 6/6"
else
	bad "kernel log has no bluetoothd code 6/6 line"
fi
if printf '%s\n' "$LOG" | grep -Eq '(BTLEFix: )?cow: BlueTool .*path 1/1'; then
	ok "kernel log shows BlueTool path 1/1"
else
	bad "kernel log has no BlueTool path 1/1 line"
fi
if printf '%s\n' "$LOG" | grep -Eqi 'pattern mismatch|scan failed|blocked by code-signing|rule misses [1-9]|COW protect failed|user memory failed|read-back failed|protection restore failed|address overflow|patch crosses a page|image header unreadable|page unreadable|UUID mismatch|stat failed|no task map|no executable vnode|cannot open|cannot read executable'; then
	bad "COW log contains an error"
else
	ok "COW log has no recorded error"
fi

echo
echo "== disk signatures"
if codesign --verify /usr/sbin/bluetoothd >/dev/null 2>&1; then
	ok "bluetoothd signature verifies"
else
	bad "bluetoothd signature still fails"
fi
if codesign --verify /usr/sbin/BlueTool >/dev/null 2>&1; then
	ok "BlueTool signature verifies"
else
	bad "BlueTool signature fails"
fi
if python3 "$HERE/verify_private_patch.py" --expect-pristine /usr/sbin/bluetoothd >/dev/null 2>&1; then
	ok "bluetoothd disk/UBC pages are pristine"
else
	bad "bluetoothd disk/UBC pages still contain patched forms"
fi
if python3 "$HERE/verify_private_patch.py" --expect-pristine /usr/sbin/BlueTool >/dev/null 2>&1; then
	ok "BlueTool disk/UBC pages are pristine"
else
	bad "BlueTool disk/UBC pages still contain patched forms"
fi

echo
echo "== loaded modules and boot args"
LOADED=$(kmutil showloaded --list-only 2>/dev/null || true)
if printf '%s\n' "$LOADED" | grep -q 'local.juren.BTLEFix (1.0.8)'; then
	ok "BTLEFix 1.0.8 is loaded"
else
	bad "BTLEFix 1.0.8 is not loaded"
fi
BARGS=$(sysctl -n kern.bootargs 2>/dev/null || true)
case " $BARGS " in
	*" -btlfxoff "*) ok "-btlfxoff is active" ;;
	*) bad "-btlfxoff is missing from kern.bootargs" ;;
esac

echo
echo "== Bluetooth state"
BT=$(system_profiler SPBluetoothDataType 2>/dev/null || true)
if printf '%s\n' "$BT" | grep -q 'State: On'; then
	ok "Bluetooth reports State: On"
else
	bad "Bluetooth does not report State: On"
fi
if printf '%s\n' "$BT" | grep -Eq 'Address: [0-9A-Fa-f]{2}:'; then
	ok "Bluetooth address is present"
else
	bad "Bluetooth address is missing"
fi

echo
echo "== APFS page-in errors"
ERR=$(printf '%s\n' "$ALL_LOG" | grep -i 'apfs_pagein' | grep -v '^Timestamp' || true)
if [ -n "$ERR" ]; then
	bad "APFS page-in errors for bluetoothd are still present"
	printf '%s\n' "$ERR" | tail -5
else
	ok "no APFS page-in errors for bluetoothd"
fi

echo
printf 'result: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
