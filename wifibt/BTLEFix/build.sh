#!/bin/bash
# Build BTLEFix.kext (Lilu plugin: bluetoothd LE Read Buffer Size v1). Needs the Lilu 1.7.2 source and MacKernelSDK: LILU=<Lilu-1.7.2> MKSDK=<MacKernelSDK>.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
LILU=${LILU:-$HERE/../../backlight/deps/Lilu-1.7.2}; MKSDK=${MKSDK:-$HERE/../../backlight/deps/MacKernelSDK}
OUT="$HERE/build"; K="$OUT/BTLEFix.kext"; rm -rf "$OUT"; mkdir -p "$K/Contents/MacOS"
DEFS=(-DPRODUCT_NAME=BTLEFix -DMODULE_VERSION=1.0.5 -DKERNEL -DKERNEL_PRIVATE -DDRIVER_PRIVATE -DAPPLE -DNeXT -DLILU_KEXTPATCH_SUPPORT)
INC=(-nostdinc -I"$MKSDK/Headers" -I"$LILU/Lilu")
CXX=(-arch x86_64 -fapple-kext -mkernel -std=c++17 -fno-rtti -fno-exceptions -fno-builtin -fno-common -fno-stack-protector -mno-red-zone -O2
     -Wall -Wno-unused-parameter -Wno-inconsistent-missing-override -Wno-deprecated-declarations)
xcrun clang++ "${CXX[@]}" "${INC[@]}" "${DEFS[@]}" -c "$HERE/kern_btlefix.cpp" -o "$OUT/kern_btlefix.o"
xcrun clang++ "${CXX[@]}" "${INC[@]}" "${DEFS[@]}" -c "$LILU/Lilu/Library/plugin_start.cpp" -o "$OUT/plugin_start.o"
xcrun clang -arch x86_64 -mkernel -nostdinc -I"$MKSDK/Headers" -c "$HERE/kmod_info.c" -o "$OUT/kmod_info.o"
xcrun clang++ -arch x86_64 -fapple-kext -nostdlib -Xlinker -kext -L"$MKSDK/Library/x86_64" -lkmodc++ -lkmod -lcc_kext \
  "$OUT/kern_btlefix.o" "$OUT/plugin_start.o" "$OUT/kmod_info.o" -o "$K/Contents/MacOS/BTLEFix"
cp "$HERE/Info.plist" "$K/Contents/Info.plist"
plutil -lint "$K/Contents/Info.plist" >/dev/null
echo "built $K  $(shasum -a 256 "$K/Contents/MacOS/BTLEFix" | cut -c1-8)"
