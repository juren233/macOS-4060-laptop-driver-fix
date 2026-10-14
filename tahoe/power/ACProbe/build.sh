#!/bin/bash
# Build ACProbe.kext (read-only AC adapter diagnostic). Needs MacKernelSDK: MKSDK=<MacKernelSDK>.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
MKSDK=${MKSDK:-$HERE/../../../backlight/deps/MacKernelSDK}
OUT="$HERE/build"; K="$OUT/ACProbe.kext"; rm -rf "$OUT"; mkdir -p "$K/Contents/MacOS"
DEFS=(-DKERNEL -DKERNEL_PRIVATE -DDRIVER_PRIVATE -DAPPLE -DNeXT)
INC=(-nostdinc -I"$MKSDK/Headers")
CXX=(-arch x86_64 -fapple-kext -mkernel -std=c++17 -fno-rtti -fno-exceptions -fno-builtin -fno-common -fno-stack-protector -mno-red-zone -O2
     -Wall -Wno-unused-parameter -Wno-inconsistent-missing-override -Wno-deprecated-declarations)
xcrun clang++ "${CXX[@]}" "${INC[@]}" "${DEFS[@]}" -c "$HERE/ACProbe.cpp" -o "$OUT/ACProbe.o"
xcrun clang -arch x86_64 -mkernel -nostdinc -I"$MKSDK/Headers" -c "$HERE/kmod_info.c" -o "$OUT/kmod_info.o"
xcrun clang++ -arch x86_64 -fapple-kext -nostdlib -Xlinker -kext -L"$MKSDK/Library/x86_64" -lkmodc++ -lkmod -lcc_kext \
  "$OUT/ACProbe.o" "$OUT/kmod_info.o" -o "$K/Contents/MacOS/ACProbe"
cp "$HERE/Info.plist" "$K/Contents/Info.plist"; plutil -lint "$K/Contents/Info.plist" >/dev/null
echo "built $K"
