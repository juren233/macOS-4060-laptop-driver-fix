/* Per-frame QP rate control for NullMoth's NVENC H.264 VT plugin (injected into the dead enctest_main area).
   Session storage (grown from 0xa0 to 0xb0 bytes): 0x64 QP, 0x6c ExpectedFrameRate, 0x74 target kbps
   (stored by the AverageBitRate hook), 0x94 under-budget streak, 0xa0 last PTS in microseconds. */
typedef struct { long long value; int timescale; unsigned flags; long long epoch; } T;
void rc(char *s, unsigned long len, int key, const T *pts) {
  unsigned kbps = *(unsigned *)(s + 0x74);
  if (!kbps) return;
  long long now = 0, *last = (long long *)(s + 0xa0);
  if ((pts->flags & 1) && pts->timescale > 0)
    now = pts->value / pts->timescale * 1000000 + pts->value % pts->timescale * 1000000 / pts->timescale;
  long long dt = now - *last;
  *last = now;
  if (dt <= 0 || dt > 1000000) { int fps = *(int *)(s + 0x6c); if (fps < 5 || fps > 240) fps = 40; dt = 1000000 / fps; }
  if (dt < 8000) dt = 8000;
  if (dt > 100000) dt = 100000;
  long long budget = (long long)kbps * dt / 8000, b = (long long)len;
  if (key) b /= 4;
  int *qp = (int *)(s + 0x64), *streak = (int *)(s + 0x94), q = *qp;
  if (b > budget * 2) { q += 3; *streak = 0; }
  else if (b > budget * 5 / 4) { q += 1; *streak = 0; }
  else if (b < budget / 2) { if (++*streak >= 4) { q -= 1; *streak = 0; } }
  else *streak = 0;
  if (q < 18) q = 18;
  if (q > 45) q = 45;
  *qp = q;
}
