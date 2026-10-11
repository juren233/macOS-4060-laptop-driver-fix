#!/usr/bin/env python3
# Make a measurement ("diag") variant of the plugin sources: passtime per-pass GPU timing that a sandboxed WindowServer can
# use, plus self-bind refresh counters. Lives outside the scratchpad on purpose: reboots wipe /private/tmp.
#   python3 -I mkdiag.py <plugin-build dir> <out dir>      then build in <out dir> with the usual clang line.
# Arm:    touch /Users/Shared/nvmtl-passtime-request; chflags uchg /Users/Shared/nvmtl-passtime-request
#         (uchg: no process can unlink it, so every plugin client keeps re-arming 6000 passes until it is removed)
# Disarm: chflags nouchg /Users/Shared/nvmtl-passtime-request; rm /Users/Shared/nvmtl-passtime-request
# Logs:   /private/var/tmp/nvmtl-passtime-<pid>.log (WindowServer's sandbox allows writes there, not to /Users/Shared)
#         lines: cb N pass i WxH fmt F x FLAGS sets S gpu_us G gap_us P   FLAGS: 0x100 linear colour target, load<<16
#         self-bind counters: /private/var/tmp/nvmtl-selfrect-<pid>.log (rewritten every 3000 refreshes)
import os, shutil, sys

src, out = sys.argv[1], sys.argv[2]
os.makedirs(out, exist_ok=True)
for f in os.listdir(src):
    if f.endswith(('.m', '.c', '.h', '.metal')) and '.pre-' not in f and '.diag' not in f:
        shutil.copy(os.path.join(src, f), out)
for f in ('air-runtime', 'libnvmtl_translate.dylib'):
    p = os.path.join(out, f)
    if not os.path.lexists(p): os.symlink('/Library/GPUBundles/NVMTLDriver.bundle/Contents/MacOS/' + f, p)

def rep(f, a, b):
    p = os.path.join(out, f); s = open(p).read()
    assert s.count(a) == 1, (f, a[:70]); open(p, 'w').write(s.replace(a, b))

f = 'nvmtl_vk.c'
rep(f, 'c->pt_w[c->pt_n] = ps->w; c->pt_h[c->pt_n] = ps->h; c->pt_f[c->pt_n]',
    'c->pt_w[c->pt_n] = ps->w; c->pt_h[c->pt_n] = ps->h; { nvk_image *r0 = ps->res[0]; nvk_image *c0 = ps->col[0]; c->pt_x[c->pt_n] = (c0 ? (c0->samples & 0xff) | (c0->linear ? 0x100u : 0) | (c0->sysmem ? 0x800u : 0) : 0) | (r0 ? 0x400u | (r0->linear ? 0x200u : 0) : 0) | ((ps->load & 0xffu) << 16); c->pt_s0[c->pt_n] = c->nsets; } c->pt_f[c->pt_n]')
rep(f, 'if (access("/tmp/nvmtl-passtime-request", F_OK) == 0) { unlink("/tmp/nvmtl-passtime-request"); g_pt_left = 400; nvlog("passtime: ARMED for 400 passes"); }',
    'if (access("/Users/Shared/nvmtl-passtime-request", F_OK) == 0) { unlink("/Users/Shared/nvmtl-passtime-request"); g_pt_left = 6000; nvlog("passtime: ARMED for 6000 passes (diag)"); }')
rep(f, 'if (c->pt_open && c->pt_pool) { pvkCmdWriteTimestamp', 'if (c->pt_open && c->pt_pool) { c->pt_s1[c->pt_n] = c->nsets; pvkCmdWriteTimestamp')
rep(f, 'const char *td = getenv("TMPDIR"); snprintf(fp, sizeof fp, "%s/nvmtl-passtime-%d.log", td && *td ? td : "/tmp", (int)getpid());',
    'snprintf(fp, sizeof fp, "/private/var/tmp/nvmtl-passtime-%d.log", (int)getpid());')
rep(f, '"cb %llu pass %u %ux%u fmt %u gpu_us', '"cb %llu pass %u %ux%u fmt %u x %08x sets %u gpu_us')
rep(f, 'c->pt_w[i], c->pt_h[i], c->pt_f[i], gpu, gap,', 'c->pt_w[i], c->pt_h[i], c->pt_f[i], c->pt_x[i], c->pt_s1[i] - c->pt_s0[i], gpu, gap,')
rep(f, 'out->fmt = vkfmt; out->bpp = bpp;\n', 'out->fmt = vkfmt; out->bpp = bpp; out->linear = 1;\n')
f = 'nvmtl_vk.h'
rep(f, 'uint32_t vpair;  } nvk_image;', 'uint32_t vpair; uint32_t linear; } nvk_image;')
rep(f, 'uint32_t pt_fs[128][4];', 'uint32_t pt_fs[128][4]; uint32_t pt_x[128], pt_s0[128], pt_s1[128];')

# self-bind refresh counters, rewritten to a file every 3000 refreshes (and at 64, 128, 256... for short tests)
f = 'NVMTLObjects.m'
rep(f, '// What the draw about to be recorded can write: its scissor rect', '''static uint64_t g_sr[20];   // diag: 0 refreshes 1 partial 2 skip 3 full:unsynced 4 full:live 5 full:all 6 nopass 7 notes 8 notes w/o SC 9 >8 rects 10 why-mark 11 why-surf 12 why-nopass 13 why-patch 14 why-fail 15 partial px 16 noSC draws whose viewport is smaller than the target 17 their summed viewport area (permille)
static void sr_dump(void) { ++g_sr[0]; if (g_sr[0] % 3000 && (g_sr[0] < 64 || (g_sr[0] & (g_sr[0] - 1)))) return;   // every 3000, and at 64, 128, 256...
    char fp[96]; snprintf(fp, sizeof fp, "/private/var/tmp/nvmtl-selfrect-%d.log", (int)getpid()); FILE *lf = fopen(fp, "w"); if (!lf) return;
    fprintf(lf, "selfrect refresh %llu partial %llu skip %llu full(unsynced %llu live %llu all %llu) nopass %llu | draws %llu noSC %llu over8 %llu | unsync why: mark %llu surf %llu nopass %llu patch %llu fail %llu | partial avg px %llu | noSC small-viewport draws %llu avg area %llu permille | fetch-barrier draws %llu\\n",
        g_sr[0], g_sr[1], g_sr[2], g_sr[3], g_sr[4], g_sr[5], g_sr[6], g_sr[7], g_sr[8], g_sr[9], g_sr[10], g_sr[11], g_sr[12], g_sr[13], g_sr[14], g_sr[1] ? g_sr[15] / g_sr[1] : 0, g_sr[16], g_sr[16] ? g_sr[17] / g_sr[16] : 0, g_sr[18]); fclose(lf); }
// What the draw about to be recorded can write: its scissor rect''')
rep(f, '''    nvk_image *a = [_selfSurf nvi];
    if (_selfDirtyAll || !_hasSC''', '''    nvk_image *a = [_selfSurf nvi]; g_sr[7]++; if (!_hasSC) g_sr[8]++;
    if (!_hasSC && _hasVP && a && (_vp[2] < a->w || _vp[3] < a->h)) { g_sr[16]++; g_sr[17] += (uint64_t)(1000.0 * _vp[2] * _vp[3] / ((double)a->w * a->h)); }
    if (_selfDirtyAll || !_hasSC''')
rep(f, '    if (_selfDirtyN == 8) { _selfDirtyAll = YES; return; }', '    if (_selfDirtyN == 8) { _selfDirtyAll = YES; g_sr[9]++; return; }')
rep(f, '    if (!_selfMark || _selfSurf != sr) _selfSynced = NO;', '    if (!_selfMark || _selfSurf != sr) { if (_selfSynced) g_sr[_selfMark ? 11 : 10]++; _selfSynced = NO; }')
rep(f, '''        if (part && !_selfDirtyN) { [self nvmtlSelfNoteDraw]; return YES; }''', '''        sr_dump();
        if (part && !_selfDirtyN) { g_sr[2]++; [self nvmtlSelfNoteDraw]; return YES; }
        if (part) { g_sr[1]++; for (uint32_t k = 0; k < _selfDirtyN; k++) g_sr[15] += (uint64_t)_selfDirty[k][2] * _selfDirty[k][3]; }
        else g_sr[!_selfSynced ? 3 : live != _selfSyncImg ? 4 : 5]++;''')
rep(f, '_selfSynced = NO; }\n        else { _selfSynced = YES;', '_selfSynced = NO; g_sr[14]++; }\n        else { _selfSynced = YES;')
rep(f, '        _selfSynced = NO;   // the pass has not begun', '        sr_dump(); g_sr[6]++; if (_selfSynced) g_sr[12]++;\n        _selfSynced = NO;   // the pass has not begun')
rep(f, '    _selfSynced = NO;   // patch draws skip', '    if (_selfSynced) g_sr[13]++;\n    _selfSynced = NO;   // patch draws skip')
rep(f, '        nvtrace("SELFFETCH', '        g_sr[18]++; sr_dump();\n        nvtrace("SELFFETCH')
print('diag sources in', out)
