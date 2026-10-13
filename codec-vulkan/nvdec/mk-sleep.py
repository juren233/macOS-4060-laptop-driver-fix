#!/usr/bin/env python3
# mk-sleep.py <in h264 t2d8 dylib> <out>: the H.264 decoder waits for NVDEC by spinning on the semaphore + clock_gettime for the
# whole decode (~8 ms of a core per 4K frame). Like the HEVC decoder (0.1 ms spin, then nanosleep 50 us), poll every 50 us:
# 0x77e4 `movsd timeout,%xmm1; ucomisd; ja loop` -> jmp to code in the header padding (0x7c0..0x800, after the load commands,
# inside the r-x __TEXT segment) that exits on timeout as before, else sleeps 50 us and jumps back to the semaphore check.
# The library imports no sleep function: the cave reads CLOCK_UPTIME_RAW through its own clock_gettime stub (= mach_absolute_time
# on Intel, timebase 1/1) and calls the mach_wait_until trap (-90) with now + 50 us. (__semwait_signal needs libc's private
# clock_sem - with 0 it returns EINVAL at once.) Chrome's seatbelt profiles filter no syscalls/traps. Then re-sign ad hoc.
import struct, sys
d = bytearray(open(sys.argv[1], 'rb').read())
LOOP, EXIT, SITE, CAVE, TMO, CLOCK = 0x7794, 0x77f2, 0x77e4, 0x7c0, 0xa4a0, 0x97e4
assert d[CLOCK:CLOCK + 2] == b'\xff\x25', 'clock_gettime stub moved'
assert d[SITE:SITE + 14] == bytes.fromhex('f20f100db42c0000660f2ec877a2'), 'unexpected wait loop bytes'
assert struct.unpack_from('<d', d, TMO)[0] == 2000.0
ncmds, sizeofcmds = struct.unpack_from('<II', d, 16)
assert 32 + sizeofcmds <= CAVE and d[CAVE:0x800] == bytes(0x800 - CAVE), 'header padding not free'
def rel(frm, to): return struct.pack('<i', to - frm)
c = bytearray()
c += b'\xf2\x0f\x10\x0d' + rel(CAVE + 8, TMO)            # movsd timeout(%rip), %xmm1
c += b'\x66\x0f\x2e\xc8'                                   # ucomisd %xmm0, %xmm1
c += b'\x0f\x86' + rel(CAVE + len(c) + 6, EXIT)            # jbe exit (timed out: as the original fall-through)
c += b'\x4c\x89\xe6\xbf\x08\x00\x00\x00'                   # movq %r12, %rsi (r12 = the loop's timespec); movl $CLOCK_UPTIME_RAW, %edi
c += b'\xe8' + rel(CAVE + len(c) + 5, CLOCK)                      # call clock_gettime (stub)
c += b'\x49\x69\x3c\x24' + struct.pack('<I', 1000000000)        # imulq $1e9, (%r12), %rdi
c += b'\x49\x03\x7c\x24\x08'                                    # addq 8(%r12), %rdi
c += b'\x48\x81\xc7' + struct.pack('<I', 50000)                  # addq $50000, %rdi  (deadline = now + 50 us)
c += b'\xb8\x5a\x00\x00\x01\x0f\x05'                            # syscall mach_wait_until (Mach trap 90)
c += b'\xe9' + rel(CAVE + len(c) + 5, LOOP)                # jmp loop (re-read the semaphore)
assert CAVE + len(c) <= 0x800
d[CAVE:CAVE + len(c)] = c
d[SITE:SITE + 14] = b'\xe9' + rel(SITE + 5, CAVE) + b'\xcc' * 9
open(sys.argv[2], 'wb').write(d)
print('cave %d bytes' % len(c))
