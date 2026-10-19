#!/usr/bin/env python3 -I
# Head-scaler (HiDPI 1792x1008@165) on the official NullMoth 2.3.7 NVRM (11633b6e). Same two edits as
# kext115/patch-nvrm-115.py, re-derived on this binary by byte pattern: each pattern must match exactly once in the
# whole file AND lie inside the named function (range from nm). No fixed offsets. Accepts a stock binary or one already
# patched (idempotent); anything else stops. Usage: patch-nvrm-237.py NVRM
#
# Struct offsets (open-gpu-kernel-modules 610.57.04 nvkms-kapi.h, which 2.3.7 builds against; checked with offsetof):
#   NvKmsKapiHeadRequestedConfig: modeSetConfig.mode.timings.hVisible 0x50, vVisible 0x64, layerRequestedConfig[0].config.srcWidth 0x18e (srcHeight 0x190)
#   NvKmsKapiLayerConfig:         srcWidth 0x4e, srcHeight 0x50, dstWidth 0x56, dstHeight 0x58
# 1. _ApplyModeSetConfig: viewPortSizeIn = main layer source size (one 32-bit load of src W|H) instead of hVisible/vVisible.
#    2.3.7 keeps the request struct in %rbp (1.15.0: %rbx), so the store is 89 85 instead of 89 83.
# 2. _NvKmsKapiLayerConfigToKms: layer sizeOut loaded from srcWidth/srcHeight instead of dstWidth/dstHeight (both copies).
# flip-at-boot (1.15.0 autoGo IOSleep(60000) -> 0) is NOT applied: upstream 8b120f3 already flips right after the release.
import sys, subprocess, re
f = sys.argv[1]
d = bytearray(open(f, 'rb').read())

def func_range(name):
    syms = sorted((int(a, 16), n) for a, t, n in (l.split() for l in subprocess.run(['nm', '-n', f], capture_output=True, text=True, check=True).stdout.splitlines() if len(l.split()) == 3) if t in 'tT')
    for i, (a, n) in enumerate(syms):
        if n == name: return a, syms[i + 1][0]
    sys.exit(f'STOP: symbol {name} not found')

# __TEXT vmaddr == file offset in this kext (fileoff 0, vmaddr 0); checked so a layout change cannot misplace the range test
o = subprocess.run(['otool', '-l', f], capture_output=True, text=True, check=True).stdout
m = re.search(r'segname __TEXT\n\s+vmaddr (0x[0-9a-f]+)\n\s+vmsize 0x[0-9a-f]+\n\s+fileoff (\d+)', o)
assert m and int(m.group(1), 16) == 0 and int(m.group(2)) == 0, 'STOP: __TEXT is not mapped at file offset 0'

def site(func, orig, new, what):
    orig, new = bytes.fromhex(orig.replace(' ', '')), bytes.fromhex(new.replace(' ', ''))
    assert len(orig) == len(new), what
    lo, hi = func_range(func)
    hits = [(m.start(), 'orig') for m in re.finditer(re.escape(orig), d)] + ([(m.start(), 'new') for m in re.finditer(re.escape(new), d)] if new != orig else [])
    assert len(hits) == 1, f'STOP: {what}: {len(hits)} matches (want exactly 1): {[hex(h) for h, _ in hits]}'
    off, state = hits[0]
    assert lo <= off and off + len(orig) <= hi, f'STOP: {what}: match {off:#x} outside {func} [{lo:#x},{hi:#x})'
    d[off:off + len(orig)] = new
    print(f'  {what}: {off:#x} in {func}+{off - lo:#x} ({"patched now" if state == "orig" else "already patched"})')

site('_ApplyModeSetConfig',
     '41 0f b7 44 24 50  66 89 85 10 01 00 00  41 0f b7 44 24 64  66 89 85 12 01 00 00',   # movzwl 0x50(%r12),%eax; movw %ax,0x110(%rbp); movzwl 0x64(%r12),%eax; movw %ax,0x112(%rbp)
     '41 8b 84 24 8e 01 00 00  89 85 10 01 00 00  66 0f 1f 44 00 00  66 0f 1f 44 00 00',   # movl 0x18e(%r12),%eax; movl %eax,0x110(%rbp); nopw x2
     'viewPortSizeIn = layer src')
# layer path: movzwl 0x56(%r15),%ecx; imulq $0x250,%r14,%rdx; movw %cx,0xea(%r8,%rdx); movzwl 0x58(%r15),%ecx; movw %cx,0xec(%r8,%rdx)
site('_NvKmsKapiLayerConfigToKms',
     '41 0f b7 4f 56  49 69 d6 50 02 00 00  66 41 89 8c 10 ea 00 00 00  41 0f b7 4f 58  66 41 89 8c 10 ec 00 00 00',
     '41 0f b7 4f 4e  49 69 d6 50 02 00 00  66 41 89 8c 10 ea 00 00 00  41 0f b7 4f 50  66 41 89 8c 10 ec 00 00 00',
     'sizeOut = src (layer[i])')
# main-layer path: movzwl 0x56(%r15),%edx; movw %dx,0xea(%r8); movzwl 0x58(%r15),%edx; movw %dx,0xec(%r8)
site('_NvKmsKapiLayerConfigToKms',
     '41 0f b7 57 56  66 41 89 90 ea 00 00 00  41 0f b7 57 58  66 41 89 90 ec 00 00 00',
     '41 0f b7 57 4e  66 41 89 90 ea 00 00 00  41 0f b7 57 50  66 41 89 90 ec 00 00 00',
     'sizeOut = src (main layer)')
open(f, 'wb').write(d)
print('patched', f)
