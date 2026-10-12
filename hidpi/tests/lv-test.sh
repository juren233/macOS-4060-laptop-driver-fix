#!/bin/bash
# Run a catest binary the way WindowServer would load the driver: in a process with LIBRARY VALIDATION (what every Apple platform daemon has).
# A plugin / translator dylib that is unsigned or has an invalid signature loads fine in an ordinary test process but is REJECTED here
# (kernel log: "Library Validation failed: Rejecting ... completely unsigned"), which is exactly what crash-loops WindowServer.
# usage: lv-test.sh <catest binary> [plugin build path]      e.g.  lv-test.sh catest/sarray /path/to/NVMTLDriver   (needs the plugin's neighbours: libnvmtl_translate.dylib ...)
set -eu
BIN=$1; shift
D=$(mktemp -d /private/tmp/lv-test.XXXXXX); trap 'rm -rf "$D"' EXIT
cp "$BIN" "$D/t" && codesign -f -s - -o library "$D/t"
T0=$(date '+%Y-%m-%d %H:%M:%S')
"$D/t" "$@" | tail -1
echo "library-validation rejections during the run: $(/usr/bin/log show --start "$T0" --style compact --predicate 'eventMessage CONTAINS "Library Validation failed"' 2>/dev/null | grep -c Rejecting)"
