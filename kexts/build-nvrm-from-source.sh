#!/bin/zsh
# build-nvrm.sh [rev] [out] - build NVRM.kext from NullMoth kexts/NVRM at <rev> (default v2.0.4) against NVIDIA
# open-gpu-kernel-modules 610.57.04 (src/ogkm610). Upstream ships no NVRM build script (rmcc.py names a private
# build-nvrm.sh); this rebuilds it: RM + nvidia-modeset with NVIDIA's own Makefiles (CFLAGS -DNV_BSD -DNV_UNIX:
# Apple clang defines neither; the official binary carries the Linux/BSD-only nvBldVer strings, and its nvlink_lib_*lock* stubs
# are the non-Linux branch of nvlink_lock.c, so NV_BSD - the only other RM difference is nv-ioctl-numa.h, kernel layer only), archived as
# libnvkernel.a / libnvkms.a (the ELF ld -r steps do not apply on macOS), then the xnu layer + kext link.
set -euo pipefail
H=${0:A:h}; S=${H:h}/src; REV=${1:-v2.0.4}; O=${2:-$H/out-${REV}}
export OGKM=$S/ogkm610; NV=$OGKM/src/nvidia; KMS=$OGKM/src/nvidia-modeset; RO=$NV/_out/Darwin_x86_64; KO=$KMS/_out/Darwin_x86_64
LOG=$O/log; rm -rf $O; mkdir -p $O/src $LOG
git -C $S/repo archive $REV kexts/NVRM | tar -x -C $O/src; SRC=$O/src/kexts/NVRM
# optional: NVRM_SRC_HOOK=<script> edits the exported kexts/NVRM copy (e.g. kext237/hs-hook.sh adds the head-scaler patch)
if [[ -n ${NVRM_SRC_HOOK:-} ]]; then zsh $NVRM_SRC_HOOK $SRC || { echo "STOP: source hook"; exit 1; }; fi
# --- 1. RM and modeset libraries (NVIDIA Makefiles, objects reused when already built with these flags) ---
mk() { (cd $1 && CFLAGS='-DNV_BSD -DNV_UNIX' make -k -j16 NV_VERBOSE=1 CC=clang CXX=clang++ LD=ld "${@:2}") }
if [[ ! -f $RO/compile_cmds.sh ]]; then
  mk $NV > $LOG/rm-make.log 2>&1 || true   # fails only at the ELF 'ld -r' step
  mk $NV -n -B 2>/dev/null | grep -E '^clang(\+\+)? .* -c ' > $RO/compile_cmds.sh
fi
if [[ ! -f $KO/compile_cmds.sh ]]; then
  mk $KMS > $LOG/kms-make.log 2>&1 || true
  mk $KMS SHADER_OBJS= _out/Darwin_x86_64/g_nvid_string.o >> $LOG/kms-make.log 2>&1   # shaders: NullMoth embeds them (nvkms_shaders.cpp)
  mk $KMS -n -B SHADER_OBJS= 2>/dev/null | grep -E '^clang(\+\+)? .* -c ' > $KO/compile_cmds.sh
fi
n=$(grep -c ' -c ' $RO/compile_cmds.sh); m=$(ls $RO/*.o | wc -l | tr -d ' '); [[ $n == $m ]] || { echo "STOP: RM $m objects for $n compile lines"; exit 1; }
n=$(grep -c ' -c ' $KO/compile_cmds.sh); m=$(ls $KO/*.o | grep -v _shaders | wc -l | tr -d ' '); [[ $n == $m ]] || { echo "STOP: modeset $m objects for $n compile lines"; exit 1; }
# the archives live in the vendor _out dirs: build-completion-archive.py reads _out/Darwin_x86_64/libnvkms.a from there
rm -f $RO/libnvkernel.a $KO/libnvkms.a
ar rcs $RO/libnvkernel.a $RO/*.o
ar rcs $KO/libnvkms.a $(ls $KO/*.o | grep -v _shaders)
cp $RO/libnvkernel.a $KO/libnvkms.a $O/
if [[ -f $SRC/build-completion-archive.py ]]; then   # 2.0.x: paired display completion (patched nvkms-kapi.o + release id)
  python3 $SRC/build-completion-archive.py --vendor $KMS --output $O/completion > $LOG/completion.log 2>&1
  cp $O/completion/libnvkms.a $O/libnvkms.a
fi
echo "libs: libnvkernel.a $(stat -f %z $O/libnvkernel.a) B, libnvkms.a $(stat -f %z $O/libnvkms.a) B"
# --- 2. the xnu layer (flags as upstream build/accel_build.sh) + kext link ---
SDK=$(xcrun --show-sdk-path); KHDR=$SDK/System/Library/Frameworks/Kernel.framework/Headers
RMINC=( -I$NV/arch/nvalloc/unix/include -I$NV/arch/nvalloc/common/inc -I$NV/arch/nvalloc/common/inc/gsp
  -I$OGKM/src/common/sdk/nvidia/inc -I$OGKM/src/common/sdk/nvidia/inc/hw -I$OGKM/src/common/inc
  -I$OGKM/src/common/shared/inc -I$NV/inc -I$NV/inc/os -I$NV/inc/kernel -I$NV/kernel/inc -I$NV/interface
  -I$OGKM/src/common/nvlink/interface -I$OGKM/src/common/inc/swref -I$OGKM/src/common/inc/swref/published
  -I$NV/inc/libraries -I$NV/src/libraries -I$NV/generated -I$NV/src/mm/uvm/interface
  -I$OGKM/src/common/uproc/os/libos-v2.0.0/include -I$OGKM/src/common/uproc/os/common/include
  -I$OGKM/src/common/inc/displayport -I$OGKM/src/common/nvlink/inband/interface )
KMSINC=( -I$KMS/os-interface/include -I$KMS/kapi/interface -I$KMS/kapi/include -I$OGKM/src/common/unix/nvidia-push/interface -I$KMS/interface -I$KMS/include
  -I$OGKM/src/common/unix/common/inc -I$OGKM/src/common/modeset -I$OGKM/src/common/unix/common/utils/interface )
RMDEFS=( $(head -1 $RO/compile_cmds.sh | tr ' ' '\n' | grep -E '^-D' | sed -e 's/"//g' | grep -v -E '^-D(NVRM|_LANGUAGE_C)$') )
CXXFLAGS=( -arch x86_64 -fapple-kext -mkernel -nostdinc -I$KHDR -I$SRC "${RMINC[@]}" "${KMSINC[@]}"
  -DKERNEL -DKERNEL_PRIVATE -DDRIVER_PRIVATE -DAPPLE -DNeXT "${RMDEFS[@]}"
  -std=c++17 -fno-rtti -fno-exceptions -fno-builtin -fno-common
  -Wall -Wno-unused-parameter -Wno-inconsistent-missing-override -Wno-unused-function -O2 )
OBJS=()
for f in $SRC/*.cpp; do
  b=${f:t:r}; xcrun clang++ "${CXXFLAGS[@]}" -c $f -o $O/$b.o 2> $LOG/$b.err || { echo "STOP: $b"; grep error: $LOG/$b.err | head; exit 1; }
  OBJS+=$O/$b.o
done
python3 $SRC/rmcc.py $SRC/nvrm_pageoff.c $O/nvrm_pageoff.o 2> $LOG/nvrm_pageoff.err || { echo "STOP: nvrm_pageoff"; tail $LOG/nvrm_pageoff.err; exit 1; }
OBJS+=$O/nvrm_pageoff.o
# nvrm_kapi_fields.c (NVKMS kapi struct fields): kext flags as C - the official object has the -mkernel frame-pointer
# prologue and no endbr64, i.e. not modeset's own command line
CFLAGS_C=( ${CXXFLAGS:#-std=c++17} ); CFLAGS_C=( ${CFLAGS_C:#-fno-rtti} ); CFLAGS_C=( ${CFLAGS_C:#-fno-exceptions} ); CFLAGS_C=( ${CFLAGS_C:#-Wno-inconsistent-missing-override} )
xcrun clang -x c -std=gnu11 "${CFLAGS_C[@]}" -c $SRC/nvrm_kapi_fields.c -o $O/nvrm_kapi_fields.o 2> $LOG/nvrm_kapi_fields.err || { echo "STOP: nvrm_kapi_fields"; tail $LOG/nvrm_kapi_fields.err; exit 1; }
OBJS+=$O/nvrm_kapi_fields.o
mkdir -p $O/NVRM.kext/Contents/MacOS
xcrun clang++ -arch x86_64 -fapple-kext -nostdlib -Xlinker -kext "${OBJS[@]}" $O/libnvkernel.a $O/libnvkms.a -lkmodc++ -lkmod -lcc_kext \
  -o $O/NVRM.kext/Contents/MacOS/NVRM 2> $LOG/ld.err || { echo "STOP: link"; head -30 $LOG/ld.err; exit 1; }
cp $SRC/Info.plist $O/NVRM.kext/Contents/Info.plist
echo "NVRM $(shasum -a 256 $O/NVRM.kext/Contents/MacOS/NVRM | cut -c1-8) $(stat -f %z $O/NVRM.kext/Contents/MacOS/NVRM) B  ($(xcrun clang++ --version | head -1))"
