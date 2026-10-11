import struct, sys, shutil
src, dst = "vk.in.dylib", "vk.bindfix.dylib"
b = bytearray(open(src, "rb").read())
def rel(frm, to, n=5): return struct.pack("<i", to - (frm + n))
LOCK, UNLOCK, IOCALL = 0x7fe0b8, 0x7fe0c4, 0x7fdb2a
SITE1, OLD, CAVE, RESUME, TAIL = 0x12cc3c, 0x12cbf7, 0x12cbfc, 0x12cc44, 0x12ccce
# --- verify the bytes we are about to overwrite
assert b[SITE1:SITE1+3] == bytes.fromhex("4c89f7") and b[SITE1+3] == 0xe8, "site1 mismatch"
assert struct.unpack("<i", b[SITE1+4:SITE1+8])[0] + (SITE1 + 8) == LOCK, "site1 call target"
assert b[OLD:OLD+2] == bytes.fromhex("803d"), "old block start"           # cmpb $0, told(%rip)
assert b[0x12cc28] == 0xe9 and struct.unpack("<i", b[0x12cc29:0x12cc2d])[0] + 0x12cc2d == TAIL, "old block end jmp"
assert b[0x12cc44:0x12cc47] == bytes.fromhex("480fbf"), "resume point"  # movslq _gPoolN(%rip),%rax -> 48 63 05? check below
