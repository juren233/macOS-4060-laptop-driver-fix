# Re-derives our three Vulkan-driver patches (sandbox /dev/null read-only, hw.memsize, pooled-connection unbind) on the
# NullMoth 1.9.0 libvulkan_nouveau.dylib. In 1.9.0 the text moved +0xC0 and the stubs +0xF0, so every call rel32 changes by +0x30;
# the patch bytes are taken from the proven 1.0.10 build (vk.bindfix.dylib) and every location is asserted first.
# usage: python3 -I mk-bindfix-190.py vk.orig.dylib vk.bindfix.dylib NEW_1.9.0.dylib OUT.dylib
import sys, struct
orig, fixed, new = (open(p, "rb").read() for p in sys.argv[1:4])
out_path = sys.argv[4]
T, S = 0xC0, 0xF0
d = bytearray(new)
def same(off, n):   # bytes of the old stock build at off == new build at off+T (position independent code only)
    return orig[off:off+n] == bytes(d[off+T:off+T+n])
# --- 1. /dev/null placeholder fd read-only (2 sites, low byte of the open() flags immediate)
for o in (0x12bfc8, 0x12c0db):
    assert orig[o-1] == 0xbe and orig[o] == 0x02 and fixed[o] == 0x00
    assert d[o+T-1] == 0xbe and d[o+T] == 0x02 and d[o+T+3] == 0x01, hex(o)
    d[o+T] = 0x00
# --- 2. os_get_total_physical_memory -> sysctlbyname("hw.memsize")   (76 bytes at 0x406f14)
o, n = 0x406f14, 76
assert same(0x406f10, 4) and orig[0x406f10:0x406f14] == fixed[0x406f10:0x406f14]
blk = bytearray(fixed[o:o+n])
call = 0x406f37 - o                     # e8 rel32 inside the block
assert blk[call] == 0xe8
tgt_old = 0x406f37 + 5 + struct.unpack('<i', blk[call+1:call+5])[0]
assert tgt_old == 0x7fe2b6
blk[call+1:call+5] = struct.pack('<i', (tgt_old + S) - (0x406f37 + T + 5))
# the old function owned bytes up to 0x406f52; the sysconf call in the new build must target the sysconf stub
assert d[0x406f1f+T] == 0xe8 and 0x406f1f+T+5+struct.unpack('<i', d[0x406f1f+T+1:0x406f1f+T+5])[0] == 0x7fe2b0 + S
assert orig[o:o+n] != fixed[o:o+n]
d[o+T:o+T+n] = blk
# --- 3. nvrm_xnu_close: unbind the fd before pooling the connection (54 + 8 bytes)
blk = bytearray(fixed[0x12cbf7:0x12cbf7+54])
for p in range(54):                      # relocate every e8 call that targets a stub
    if blk[p] == 0xe8:
        a = 0x12cbf7 + p
        t = a + 5 + struct.unpack('<i', blk[p+1:p+5])[0]
        if t in (0x7fdb2a, 0x7fe0b8):
            blk[p+1:p+5] = struct.pack('<i', (t + S) - (a + T + 5))
assert any(blk[p] == 0xe8 for p in range(54))
assert same(0x12cb10, 0x10) and same(0x12cc44, 3)       # function start and the resume opcode are unchanged (rip-relative operands differ)
d[0x12cbf7+T:0x12cbf7+T+54] = blk
assert orig[0x12cc3c:0x12cc44] == bytes.fromhex('4c89f7e8') + orig[0x12cc40:0x12cc44]
d[0x12cc3c+T:0x12cc44+T] = fixed[0x12cc3c:0x12cc44]       # jmp rel8/rel32 inside the function: position independent
open(out_path, 'wb').write(d)
print('wrote', out_path)
