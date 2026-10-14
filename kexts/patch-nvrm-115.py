#!/usr/bin/env python3 -I
# Re-applies our patches to the NullMoth 1.15.0 NVRM binary (e15a281a). Accepts a stock binary OR one that already carries
# (a subset of) the patches, so it is safe to re-run on the deployed payload. Every byte is asserted before it is
# written. Usage: patch-nvrm-115.py NVRM
#
# 1. head-scaler (HiDPI 1792x1008@165), same edits as the 1.0.10 patch (0x3f8b95 / 0x3fa11b ...); 1.15.0 has the 1.9.0 code byte for byte, 0x1590 further on; 1.9.0 moved the
#    code and changed registers (rbp->rbx, rdx/ecx).
# 2. flip-at-boot (2026-10-11): autoGo's IOSleep(60000) sits AFTER releaseBootHold, so zero-copy scanout engaged
#    ~60 s into the session -- after login, under live windows. Surfaces already scanned out by the copy path
#    (the Dock) stopped presenting until their process was relaunched. IOSleep(60000) -> IOSleep(0): flip=1 lands
#    microseconds after the hold release, ages before WindowServer's first transaction. No hot switch, no symptom.
import sys
f = sys.argv[1]
d = bytearray(open(f, 'rb').read())
def want(off, orig, new, what):
    orig, new = bytes.fromhex(orig), bytes.fromhex(new)
    cur = bytes(d[off:off + len(orig)])
    assert cur == orig or cur == new, f'{what}: bytes at {off:#x} are neither original nor patched ({cur.hex()})'
    d[off:off + len(orig)] = new
a = 0x3f91c5   # _ApplyModeSetConfig: ViewPortIn = layer source size (32-bit at 0x18e(%r12)) instead of two 16-bit loads
want(a, '410fb744245066898310010000410fb744246466898312010000',
        '418b84248e010000' + '898310010000' + '660f1f440000' * 2, 'viewport block')
# _NvKmsKapiLayerConfigToKms: sizeOut loaded from 0x4e/0x50 (the source size) instead of 0x56/0x58
for off, o, n in ((0x3fa838, 0x56, 0x4e), (0x3fa84d, 0x58, 0x50), (0x3faa3c, 0x56, 0x4e), (0x3faa49, 0x58, 0x50)):
    assert d[off - 2] == 0xb7, hex(off)
    want(off, f'{o:02x}', f'{n:02x}', f'sizeOut byte {off:#x}')
want(0x9467, 'bf60ea0000', 'bf00000000', 'autoGo flip delay')   # movl $0xea60,%edi; call _IOSleep  (60 s -> 0)
want(0x48bbc3, '36302073', '20302073', 'autoGo flip log text')  # "(60 s after the release)" -> "( 0 s after the release)" (same length)
open(f, 'wb').write(d)
print('patched', f)
