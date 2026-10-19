# mk-zcull-236.py IN OUT : NVK 2.0.5 as shipped in NullMoth 2.3.6 (a3a6451e, release build: no asserts) -> ZCULL on.
# Same patch as mk-zcull-204.py. The release build keeps the same frame and registers at the site: nvkmd_nvrm_enum_pdev
# still stores `movb $0, 0xe0(%r14)` (has_zcull_info) right after nvrm_init_shared_mem_sizes / util_cache_granularity,
# r14 = pdev, NvRmApi rm at -0xa00(%rbp) (its other nvRmApiControl calls pass leaq -0xa00(%rbp)), hSubdevice 0x1c8(%r14);
# dev_info (+0x10) is zeroed 0x98..0xe7 just before, so zcull_info +0xb0 / has_zcull_info +0xe0 are the 2.0.4 layout
# (same Mesa base 17ca6174). Only caller-saved registers that are dead at the site are touched (the next instructions load
# edx/rdi/rsi for __strcpy_chk). nvrm610_on: the copy this function calls (0x10d370, used for USERMODE / BOOST);
# nvRmApiControl 0x10ea70; the cave is 0x100 after the end of __eh_frame (0xf92c80) in __TEXT's zero tail (ends 0xf93000).
# --- 1.15.0 notes, still true for 2.0.4 ---
# Mesa 26.x NVK already carries upstream zcull (nvk_cmd_draw.c: region/storage/subregions, CLEAR_ZCULL_REGION at a cleared
# depth pass, LOAD/STORE_ZCULL for images with a zcull plane), gated on pdev->info.has_zcull_info. On Linux the nouveau
# ioctl DRM_NOUVEAU_GET_ZCULL_INFO fills it; the NullMoth NVRM backend sets has_zcull_info = false (nvkmd_nvrm_pdev.c), so
# hierarchical Z never ran and every late-Z fragment (sample-mask writers: all of ANGLE's MSAA WebGL) was fully shaded.
# Patch: the `movb $0, has_zcull_info` store in the (inlined) pdev create at 0x12893e (2.0.4: 0x12cf3e) becomes a call to a cave at the end
# of __TEXT (zero padding after __eh_frame) that does
#     has_zcull_info = 0;
#     if (nvrm610_on("ZCULL_RGN"))   /* env NVRM_610_ZCULL_RGN / nvrm610.conf ZCULL_RGN=0 turns it off, default on */
#        has_zcull_info = nvRmApiControl(&rm, hSubdevice, NV2080_CTRL_CMD_GR_GET_ZCULL_INFO, &dev_info.zcull_info, 40) == NV_OK;
# NV2080_CTRL_GR_GET_ZCULL_INFO_PARAMS has exactly the 10 leading fields of nv_zcull_device_info (the nouveau ioctl
# copies it the same way); ctxsw_size/align are not read by NVK. The context's zcull buffer is already bound by the
# backend (ZCULL_BIND SEPARATE_BUFFER, nvrm610 ZCULL).
# Offsets (from nvkmd_nvrm.h / nv_device_info.h of the 1.15.0 source): r14 = pdev, dev_info at +0x10, zcull_info +0xb0,
# has_zcull_info +0xe0, hSubdevice +0x1c8, NvRmApi rm at -0xa00(%rbp).
import sys, hashlib, struct
src, dst = sys.argv[1], sys.argv[2]
b = bytearray(open(src, 'rb').read())
h = hashlib.sha256(b).hexdigest()[:8]
assert h == 'a3a6451e', 'not NVK 2.0.5 (2.3.6 package) a3a6451e: ' + h
SITE, CAVE = 0x10c65a, 0xf92d80
NVRM610_ON, RMCONTROL = 0x10d370, 0x10ea70
assert b[SITE:SITE + 8] == bytes.fromhex('41c686e000000000'), b[SITE:SITE + 8].hex()
assert b[CAVE - 0x80:CAVE + 0x100] == bytes(0x180), 'cave not empty'
assert CAVE + 0x100 <= 0xf93000, 'cave past __TEXT'
def rel32(at_next, to): return struct.pack('<i', to - at_next)
c = bytearray()
def emit(x): c.extend(x)
def here(): return CAVE + len(c)
emit(b'\x53')                                            # push %rbx (align the stack)
emit(bytes.fromhex('41c686e000000000'))                  # movb $0,0xe0(%r14)
lea_str = len(c); emit(bytes.fromhex('488d3d') + b'\0\0\0\0')   # leaq str(%rip),%rdi
emit(b'\xe8'); emit(rel32(here() + 4, NVRM610_ON))       # call nvrm610_on
emit(bytes.fromhex('84c0'))                              # test %al,%al
je_at = len(c); emit(bytes.fromhex('7400'))              # je out
emit(bytes.fromhex('488dbd00f6ffff'))                    # leaq -0xa00(%rbp),%rdi
emit(bytes.fromhex('418bb6c8010000'))                    # movl 0x1c8(%r14),%esi
emit(b'\xba' + struct.pack('<I', 0x20801206))            # movl $NV2080_CTRL_CMD_GR_GET_ZCULL_INFO,%edx
emit(bytes.fromhex('498d8eb0000000'))                    # leaq 0xb0(%r14),%rcx
emit(b'\x41\xb8' + struct.pack('<I', 40))                # movl $40,%r8d
emit(b'\xe8'); emit(rel32(here() + 4, RMCONTROL))        # call nvRmApiControl
emit(bytes.fromhex('85c0'))                              # test %eax,%eax
emit(bytes.fromhex('410f9486e0000000'))                  # sete 0xe0(%r14)
out = len(c); c[je_at + 1] = out - (je_at + 2)
emit(b'\x5b\xc3')                                        # pop %rbx; ret
while len(c) % 8: emit(b'\xcc')
s = len(c); emit(b'ZCULL_RGN\0')
c[lea_str + 3:lea_str + 7] = struct.pack('<i', (CAVE + s) - (CAVE + lea_str + 7))
b[CAVE:CAVE + len(c)] = c
b[SITE:SITE + 8] = b'\xe8' + rel32(SITE + 5, CAVE) + bytes.fromhex('0f1f00')   # call cave; nopl (%rax)
open(dst, 'wb').write(b)
print('cave', hex(CAVE), len(c), 'bytes')
