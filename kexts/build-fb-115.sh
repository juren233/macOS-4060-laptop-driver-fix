#!/bin/bash
# Build NVRMFB from a NullMoth v1.15.0 tree with patches/nullmoth-1.15.0/0003 applied. Needs NVIDIA open-gpu-kernel-modules in $SRC/ogkm
# (default SRC = ../../src next to this repo - change it to your layout). Usage: build-fb-115.sh [out-dir] <patched source tree>
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); S=$(cd "${SRC:-$HERE/../../src}" && pwd); O=${1:-$HERE/out}; R=${2:?give the patched v1.15.0 source tree}; mkdir -p "$O"
SDK=$(xcrun --show-sdk-path); K=$S/ogkm/src/nvidia-modeset; G=$S/ogkm/src
xcrun clang++ -arch x86_64 -mmacosx-version-min=15.0 -fapple-kext -mkernel -nostdinc -I"$SDK/System/Library/Frameworks/Kernel.framework/Headers" \
  -I$R/kexts/NVRMFB/fb -I$R/kexts/NVRMFB -I$K/kapi/interface -I$K/interface -I$K/include -I$K/os-interface/include \
  -I$G/nvidia/arch/nvalloc/unix/include -I$G/nvidia/arch/nvalloc/common/inc -I$G/common/sdk/nvidia/inc -I$G/common/inc \
  -I$G/common/shared/inc -I$G/common/unix/common/inc -I$G/common/unix/common/utils/interface \
  -DKERNEL -DKERNEL_PRIVATE -DDRIVER_PRIVATE -DAPPLE -DNeXT -std=c++17 -fno-rtti -fno-exceptions -fno-builtin -fno-common \
  -Wall -Wno-unused-parameter -Wno-inconsistent-missing-override -Wno-unused-function -O2 \
  -c $R/kexts/NVRMFB/fb/nvrm-fb.cpp -o "$O/fb.o"
xcrun clang++ -arch x86_64 -mmacosx-version-min=15.0 -fapple-kext -nostdlib -Xlinker -kext -lkmodc++ -lkmod -lcc_kext "$O/fb.o" -o "$O/NVRMFB" 2>&1 | grep -v "built for newer" || true
echo "built $O/NVRMFB $(shasum -a 256 "$O/NVRMFB" | cut -c1-8)"
