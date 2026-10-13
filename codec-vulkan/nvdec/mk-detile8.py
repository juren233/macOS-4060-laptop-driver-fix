#!/usr/bin/env python3
# mk-detile8.py IN OUT: H.264 NVDEC detile, 1 byte -> 8 bytes per iteration (nvd264_detile in libnvdec_h264[_t2d].dylib).
# Every block-linear layout the routine handles keeps at least 8 consecutive x bytes contiguous (x[2:0] or x[3:0] are the
# low address bits) and the row width is a multiple of 16, so loading/storing a qword at x = 0, 8, 16, ... copies exactly
# the bytes the byte loop copied. Luma loop: same length (12 bytes). Chroma loop needs one byte more: its "row done" je
# goes through the unreachable alignment padding at 0x8305 (je rel8 -> jmp rel8 0x82b0).
import sys, hashlib
src, dst = sys.argv[1], sys.argv[2]
b = bytearray(open(src, 'rb').read())
def put(off, old, new):
    old, new = bytes.fromhex(old), bytes.fromhex(new)
    assert len(old) == len(new), hex(off)
    assert b[off:off+len(old)] == old, (hex(off), b[off:off+len(old)].hex())
    b[off:off+len(new)] = new
# luma: movzbl (%r12,%rax),%eax / movb %al,(%rcx,%r8) / incq %r8  ->  movq (%r12,%rax),%rax / movq %rax,(%rcx,%r8) / addq $8,%r8
put(0x8219, '410fb604044288040149ffc0', '498b04044a8904014983c008')
# chroma: movzbl (%rdx,%rcx),%eax / movb %al,(%r9,%r13) / incq %r13 / cmpq %r13,%rsi / je 0x82b0
#      -> movq (%rdx,%rcx),%rax / movq %rax,(%r9,%r13) / addq $8,%r13 / cmpq %r13,%rsi / je 0x8305 / nopl (%rax)
put(0x8333, '0fb6040a4388042949ffc54c39ee0f8469ffffff', '488b040a4b8904294983c5084c39ee74c10f1f00')
# padding after "jmp 0x8347" (never executed): jmp 0x82b0
put(0x8305, '6666', 'eba9')
open(dst, 'wb').write(b)
print(dst, hashlib.sha256(b).hexdigest()[:8], '(unsigned - codesign -f -s - it)')
