# pngmean.py FILE [x0 y0 x1 y1] : mean R G B (0..1) of an 8-bit RGB/RGBA non-interlaced PNG (screencapture output), stdlib only
import struct, sys, zlib
d = open(sys.argv[1], 'rb').read()
assert d[:8] == b'\x89PNG\r\n\x1a\n'
p, idat = 8, b''
while p < len(d):
    n, t = struct.unpack('>I4s', d[p:p + 8]); c = d[p + 8:p + 8 + n]; p += 12 + n
    if t == b'IHDR': W, H, bd, ct, _, _, il = struct.unpack('>IIBBBBB', c)
    elif t == b'IDAT': idat += c
assert bd == 8 and ct in (2, 6) and il == 0, (bd, ct, il)
bpp = 4 if ct == 6 else 3; raw = zlib.decompress(idat); st = W * bpp
x0, y0, x1, y1 = (int(a) for a in sys.argv[2:6]) if len(sys.argv) >= 6 else (0, 0, W, H)
prev = bytearray(st); s = [0, 0, 0]; cnt = 0; q = 0
for y in range(H):
    f = raw[q]; line = bytearray(raw[q + 1:q + 1 + st]); q += 1 + st
    for i in range(st):
        a = line[i - bpp] if i >= bpp else 0; b = prev[i]; c = prev[i - bpp] if i >= bpp else 0
        if f == 1: line[i] = (line[i] + a) & 255
        elif f == 2: line[i] = (line[i] + b) & 255
        elif f == 3: line[i] = (line[i] + (a + b) // 2) & 255
        elif f == 4:
            pp = a + b - c; pa, pb, pc = abs(pp - a), abs(pp - b), abs(pp - c)
            line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
    prev = line
    if y0 <= y < y1:
        for x in range(max(x0, 0), min(x1, W), 4):
            o = x * bpp; s[0] += line[o]; s[1] += line[o + 1]; s[2] += line[o + 2]; cnt += 1
print('%dx%d mean %.3f %.3f %.3f' % (W, H, s[0] / cnt / 255, s[1] / cnt / 255, s[2] / cnt / 255))
