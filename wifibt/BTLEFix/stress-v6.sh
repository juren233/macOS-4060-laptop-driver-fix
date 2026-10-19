#!/bin/bash
# Bounded Bluetooth restart test. Run only after check-v6.sh passes.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
WITH_SLEEP=0
[ "${1:-}" = "--with-sleep" ] && WITH_SLEEP=1

die() { echo "STOP: $*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "run with sudo"

COW=$(sysctl -n debug.btlefix_cow 2>/dev/null || true)
case "$COW" in
	*"code 6/6"*|*"path 1/1"*) ;;
	*) die "debug.btlefix_cow has no completed process patch yet: $COW" ;;
esac

START=$(date '+%Y-%m-%d %H:%M:%S')
echo "== bounded stress test, start $START"
purge
LAST_PID=$(pgrep -x bluetoothd | head -1)
for i in $(seq 1 10); do
	launchctl kickstart -k system/com.apple.bluetoothd >/dev/null 2>&1 || true
	sleep 2
	STATUS=$(sysctl -n debug.btlefix_cow 2>/dev/null || true)
	PID=$(pgrep -x bluetoothd | head -1)
	case "$STATUS" in
		*"code 6/6"*)
			[ -n "$PID" ] && [ "$PID" != "$LAST_PID" ] || {
				echo "   $i/10 FAIL pid did not change (${PID:-none})"
				exit 1
			}
			echo "   $i/10 ok pid=$PID $STATUS"
			LAST_PID=$PID
			;;
		*)
			echo "   $i/10 FAIL pid=${PID:-none} $STATUS"
			exit 1
			;;
	esac
done

echo "== check errors since $START"
if /usr/bin/log show --start "$START" --style compact \
	--predicate 'process == "kernel" AND eventMessage CONTAINS[c] "apfs_pagein" AND eventMessage CONTAINS[c] "bluetoothd"' 2>/dev/null | grep -v '^Timestamp' | grep -q .; then
	echo "FAIL: APFS page-in errors appeared during stress"
	exit 1
fi
echo "PASS: 10 restarts and no APFS page-in errors"

if [ "$WITH_SLEEP" -eq 1 ]; then
	echo
	echo "== one timed sleep test"
	SLEEP_TEST=${SLEEP_TEST:-$HOME/work/nvidia-setup/sleep/sleep-test.sh}
	if [ ! -x "$SLEEP_TEST" ] && [ -n "${SUDO_USER:-}" ]; then
		SLEEP_TEST=$(eval echo "~$SUDO_USER")/work/nvidia-setup/sleep/sleep-test.sh
	fi
	[ -x "$SLEEP_TEST" ] || die "sleep-test.sh is missing"
	bash "$SLEEP_TEST" 45
fi
