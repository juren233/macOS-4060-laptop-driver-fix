#!/bin/bash
# Build the nvbl CLI (NVKMS backlight attribute through NVRM's user client).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); O="$HERE/../src/ogkm/src"
xcrun clang -O2 -Wall -Wno-unused -I"$O/nvidia-modeset/interface" -I"$O/common/unix/common/inc" -I"$O/common/sdk/nvidia/inc" -I"$O/common/inc" \
  -framework IOKit "$HERE/nvbl.c" -o "$HERE/nvbl"
echo "built $HERE/nvbl"
