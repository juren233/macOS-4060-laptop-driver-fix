#!/bin/zsh
# LOCAL HARDENING - DO NOT EDIT BY HAND WITHOUT UPDATING THE HASHES BELOW. Registers the exact builds that carry this machine's fixes;
# nvguard.sh restores them if a NullMoth install/update replaces them. Source of truth: git in ~/work/system and ~/work/nvidia-setup/src/repo.
# sudo zsh ~/work/system/nvguard/install.sh          install/refresh the guard (snapshots the current plugin build)
# sudo zsh ~/work/system/nvguard/install.sh previous  ROLLBACK to the 2.0.4 merge (before the 2.3.6 follow-up): plugin 302fa176 + translator a649e150 + Vulkan driver 8003fbba, NVMTL_RES2_WS=0 (alias m236prev)
# sudo zsh ~/work/system/nvguard/install.sh wsmarkprev ROLLBACK only the plugin to f153c579 (before the WindowServer GPU marks of 79f47d0/e75be1e; translator + Vulkan driver stay)
# sudo zsh ~/work/system/nvguard/install.sh sec237prev ROLLBACK plugin + translator to 854b82c8 + 3b42129d (before the 2.3.7 bounds fixes; Vulkan driver stays)
# sudo zsh ~/work/system/nvguard/install.sh fcfastprev ROLLBACK only the translator to 793acd8e (before the Core Animation function-constant config fold; plugin b220dfe2 + Vulkan driver b81c1cb8 stay)
# sudo zsh ~/work/system/nvguard/install.sh itexprev  ROLLBACK only the plugin to b220dfe2 (before the integer-texture reflection fix; translator + Vulkan driver stay)
# sudo zsh ~/work/system/nvguard/install.sh gl236     ROLLBACK only the plugin to 05658421 (the 2.3.6 OpenGL path before the vblank-wait fix; translator + Vulkan driver stay)
# sudo zsh ~/work/system/nvguard/install.sh m236gl    ROLLBACK only the plugin to 3492ac34 (before the 2.3.6 OpenGL draw path; translator 3b42129d + Vulkan driver b81c1cb8 stay)
# sudo zsh ~/work/system/nvguard/install.sh m236xlate ROLLBACK only the translator to a649e150 (plugin 3492ac34 + Vulkan driver b81c1cb8 stay, NVMTL_RES2_WS=1)
# sudo zsh ~/work/system/nvguard/install.sh m204prev  ROLLBACK to the stack before the NullMoth 2.0.4 merge: plugin 9952f874 + translator 183ddb7c + Vulkan driver c866c85d
# sudo zsh ~/work/system/nvguard/install.sh zcullprev ROLLBACK plugin + Vulkan driver to b4041b08 + 403d4d40 (before cross-process IOSurface sync and ZCULL; translator 183ddb7c)
# sudo zsh ~/work/system/nvguard/install.sh sampler1prev ROLLBACK the translator to 70c04748 (before the one-element sampler array fix) + Vulkan driver 403d4d40
# sudo zsh ~/work/system/nvguard/install.sh tiledprev ROLLBACK the plugin to e8328b6a (before the tiled-texture mip chain fix; translator and Vulkan driver unchanged)
# sudo zsh ~/work/system/nvguard/install.sh vtfix133 ROLLBACK the plugin to 133fa823 (before the descriptor-set reuse fix)
# sudo zsh ~/work/system/nvguard/install.sh drawcost  ROLLBACK to the stack before the 1.15.0 merge (plugin 93c3be14 + translator 2a3e7ea7 + Vulkan driver 19bbfc23)
# sudo zsh ~/work/system/nvguard/install.sh sbfd      ROLLBACK plugin + translator to dbbc77ec + f62a16e5 (before the per-draw cost work; Vulkan driver 19bbfc23)
# sudo zsh ~/work/system/nvguard/install.sh sampler   ROLLBACK to the builds before the 1.14.2 merge (sampler-array: dc90cf35 + aa11ce8d)
# sudo zsh ~/work/system/nvguard/install.sh remove   stop guarding (files in the bundle are left as they are)
set -e
[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }
HERE=${0:A:h}; SYS=${HERE:h}; NVS=$SYS/nv
G=/Library/NullMoth/guard; M=/Library/GPUBundles/NVMTLDriver.bundle/Contents/MacOS
PL=/Library/LaunchDaemons/local.nvguard.plist
if [[ $1 == remove ]]; then launchctl bootout system $PL 2>/dev/null || true; rm -f $PL; chflags -R noschg $G 2>/dev/null; rm -rf $G; echo "guard removed"; exit 0; fi
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
STOCK_PLUGIN=a542789155628a94ed281558471cabe09144b5985ac68fd19a84966bfb3b9a27
# builds that must be replaced: NullMoth's stock, and upstream+ResSet-only (b0ad864) which lacks all our plugin fixes
UPSTREAM_RESSET=b31a2c5798702fdea6cb6f201dbf1cc861b9949652589c5b623e421ef4301b57
# stock NullMoth 1.15.0 plugin (if the 1401 app updates the driver, the guard puts ours back)
UPSTREAM_RESSET="$UPSTREAM_RESSET 7199b2af5acdff0831eb2d859ae1035a1a03e2ebdf602421425830ce05e13944"
# v48 = v47 + upstream NullMoth 1.9.0 plugin/translator fixes merged (branch merge-1.9.0). Merged build (viewport clamp + tiled-copy + stale-texture + diag + ResSet fix + async surface-in + scheduled-wait
# + raster-sample spec constant + IOSurface use count, 2026-10-10), kept in the project; the previous merged builds are replaceable too
# 2026-10-11: v48 + self-bind guard (cornerfix, ba00854b) + tiled render shadow for shared-VRAM render targets (NVMTL_TILED_RT, Chrome frame
# 13.6 -> 3.2 ms; src/plugin-build, patch hidpi/plugin/tiled-render-shadow.patch). Replaceable: v48 1bb7a019, cornerfix, and the passtime/tiledrt test builds.
# 2026-10-11 7e74f345 = aaa7f9fd + self-bind guard without copies for Core Animation framebuffer fetch (fixed_frag_*: pass
# restart + barrier instead of a 28 MB framebuffer snapshot per draw; WindowServer cbs over 6 ms 536 -> 6) and dirty-rect
# snapshots otherwise (patch hidpi/plugin/selfbind-fetch.patch). Replaceable: aaa7f9fd and the selfrect/selffetch/wsdiag test builds.
# 2026-10-11 c8f50277 = 7e74f345 + Apple GL-on-Metal multisample passes no longer refused: AppleMetalOpenGLRenderer names an
# all-zero sample-position placeholder on every MSAA pass and there is no sample-locations backend, so the pass (and all of its draws)
# was dropped - Steam/CEF (ANGLE on OpenGL) drew white/black/missing UI. Runs on the standard pattern now (patch
# hidpi/plugin/gl-sample-positions.patch, test hidpi/catest/gldiff). Replaceable: 7e74f345.
# 2026-10-12 78715fbf = c8f50277 + NullMoth 1.13.0 plugin sources (branch merge-1.13.0; NVENC registered on all GPUs, -[MTLBinding access] fix,
# dispatch chunking, viewport clamp upstream). Replaceable: c8f50277.
# 2026-10-12 ab73ca61 = 78715fbf + compute stage_in (SceneKit/Memoji skinning kernels; MSL gather kernel, all formats; branch compute-stagein in
# nvidia-setup/src/repo-stagein, test hidpi/catest/sitest). Replaceable: 78715fbf.
# 2026-10-12 04842a7d = ab73ca61 + MTLTextureUsageUnknown (0) read as ShaderRead|ShaderWrite|RenderTarget (QuartzCore gives 0 for a
# framebufferOnly=NO CAMetalLayer drawable; Core Image / compute writes into it were dropped: Photo Booth live preview black). Branch
# unknown-usage-all in nvidia-setup/src/repo-stagein; knob NVMTL_UNKNOWN_USAGE=0 in nvrm610.conf restores the old reading. Replaceable: ab73ca61.
# 2026-10-12 d8aa6e31 = dc90cf35 + NullMoth 1.14.2 plugin sources (branch merge-1.14.2 in nvidia-setup/src/repo-stagein: IOSurface overwrite
# sync #98, 3D blits #84, swizzle #79, HDR argument encoders, sample positions, mediaanalysisd use-after-free; our render shadow kept).
# 2026-10-13 ac789120 = d8aa6e31 + surface-in staging buffers parked for reuse (nvmtl_vk_buffer_retire) instead of freed, and cached
# IOSurface tag keys: Chrome composites the 4K video itself under danmaku and uploaded each frame into a NEW 12 MB staging buffer
# (~10 -> 2.8 ms main-thread CPU per 4K NV12 frame, hidpi/catest upbench). Branch surfin-stage-reuse in nvidia-setup/src/repo-stagein,
# patch hidpi/plugin/surfin-stage-reuse.patch. Replaceable: d8aa6e31.
# 2026-10-13 dbbc77ec = 4eb05cf4 + upstream 1.14.5/1.14.6 sandbox fallbacks (Firefox's GPU sandbox denies even reading /dev/null: the
# placeholder fd comes from a pipe; _SC_PHYS_PAGES via host_info) + 1.14.5 Unity lock fix (@synchronized(cb/queue) around
# commit+wait hung the execution queue). Branch sandbox-fd in nvidia-setup/src/repo-stagein. Goes with Vulkan driver 19bbfc23 (below).
# 2026-10-13 93c3be14 = dbbc77ec + per-draw cost (branch draw-cost in nvidia-setup/src/repo-stagein): trace arguments only evaluated
# when tracing; a draw whose only changes are bytes-ring offsets reuses its descriptor set with a new address table (dynamic offset);
# binding masks ignore the bindless heap. Goes with translator 2a3e7ea7 (below). drawbench ANGLE-like draws 3.13 -> 1.56 us/draw.
# 2026-10-13 133fa823 = 93c3be14 + from upstream 1.15.0 (branch merge-1.15.0 in nvidia-setup/src/repo-stagein): surface uploads read the
# IOSurface pages with streaming loads (1baebac, write-combining pages) and the sysconf rebind bounds checks (b25058b). Goes with
# translator 70c04748 and the stock 1.15.0 Vulkan driver 403d4d40 (below). Replaceable: 93c3be14.
# 2026-10-13 e8328b6a = 133fa823 + a changed storage texture stops the descriptor-set reuse of 93c3be14 (the pipeline masks hold no storage
# textures): VideoToolbox's two-pass scaler wrote its output into the first pass's intermediate, every scaled image (Photos/Preview
# thumbnails) came out blank; catest/vtxfer 3 of 3 bad -> 0. Also the change bits cover storage slots >= 63 (they wrote past chg[][4]).
# 93c3be14 and 133fa823 carry that bug. Replaceable: 133fa823.
# 2026-10-14 b4041b08 = e8328b6a + a tiled (client-storage) texture with a mipmapped descriptor gets its mip chain generated after the
# level-0 upload and after every re-upload from its buffer (src/wt-m115 branch tiled-mips 4b385b2). Core Animation makes trilinear layer
# contents that way (Dock badge numbers: 108 px image in a 21 pt badge, minificationFilterBias -0.5) and levels 1+ stayed empty, so the
# numbers faded out below magnified size. Built with -mmacosx-version-min=15.0 like e8328b6a (same toolchain rebuild of e8328b6a's source
# differs only in LC_UUID). Test: catest/tiledmips. Replaceable: e8328b6a.
# 2026-10-14 9952f874 = b4041b08 + cross-process IOSurface write sync (src/wt-m115 branch xsurf-sync e76b6ac): with NVMTL_SCHEDULED_WAIT=0 a
# producer hands a surface over while its GPU writes still run, and a consumer on another channel read the previous frame (catest/gfx4
# 1-55 of 60 frames wrong in 7 of 10 runs). Encoded/published write counts are mirrored into the surface ("NVMTLWr:p<plane>"); readers
# wait for the publish (at surface-in, or before submission for shared VRAM). gfx4 60/60 PASS (debug build). NVMTL_XSURF_SYNC=0: off.
# 2026-10-14 d6d309f8 = 9952f874 + WindowServer flip gate (src/wt-m115 branch ws-flip-gate): WindowServer's commitAndWaitUntilSubmitted
# waited for GPU completion every frame (4-5 ms of its main thread under load, panel 49-58 fps for a 65 fps page). With an NVAccel that
# gates the swap (debug.nvaccel_iop_gate=1, src/repo branch flip-gate) a command buffer that writes only surfaces NVAccel scanned out in
# the last second returns at submission; the swap thread waits for the surface's write record instead. Inert while the sysctl is 0 or
# the NVAccel lacks it. NVMTL_WS_FLIP_GATE=0: off. Test: catest/wsgate. Replaceable: 9952f874.
# 2026-10-15 d6d309f8 ROLLED BACK (debug.nvaccel_iop_gate=1 worked but gave no on-screen gain: GPU time-slicing is the limit; NVAccel with the
# gate first panicked on a null copyValue seed pointer, fixed in 8efdb757 but not kept). GOOD = 9952f874 again; d6d309f8 is replaceable.
# 2026-10-16 ac5df567 = 9952f874 + NullMoth 2.0.x plugin fixes (src/wt-m204 branch merge-2.0.4): resource set made in -init and taken in one
# locked step (4434649, 6fd675b), done command buffers free scratch/ring/resources without a pool drain (3e960e8, 9a81e05, 1f58202 - our
# locked dealloc kept), encoder-named resources across an event split (7f36d5f), IOSurface plane bound check (25d085a), SPIR-V cache in a
# writable folder + one AIR hash (635eae7, 08ce634), parallel async pipelines (d45839d), host-copy texture sync on every submission
# (deadee2, 569797c: upstream bench_copy_coherence texture->host 16/16 bad -> 0), MSAA sample locations (8b39ecc), robustBufferAccess +
# imageCubeArray (c69856f), optional async replaceRegion (5dfe8da, off), a surface's private image writable whenever possible (61f5bff part).
# Not taken: e57a132 (xsurf-sync kept), 236f664 (Chrome stays on the GPU), e12eaf3/a76b3c4 (RTX 50 only). Built with
# -mmacosx-version-min=15.0, SDK 26.5 (26.2 is gone since Xcode 26.5). Plus 1b8a24f: one VRAM import of a surface per process (later
# textures alias it; a second import was refused now and then -> fresh private image) and the surface-in guard skips the upload only
# for the storage the in-flight writes land in (catest/gfx4 read zeros 1 run in 20-50, installed stack too). Replaceable: 9952f874.
# 2026-10-18 3492ac34 = 302fa176 + the selective NullMoth 2.0.4 -> 2.3.6 user-space follow-up (src/wt-m204, hidpi/install-m236.sh): hardware
# decoders registered in VTDecoderXPCService (ff6f12b/9501d07; Ada keeps our libnvdec_h264_t2d), passes with no attachments + layered 3D
# targets (82afc75), sampler heap / [[color(n)]] fetch through input attachments / stencil export emulation / GPU grid flag (d17e509,
# 416ee60, 5092fcb), fetch draws that lack attachments + per-triangle order (351f5ed), never a missing view or sampler (cf92c5a), a late
# fence waits in slices instead of disabling the backend (f2b899d), fetch-off colour reads a zeroed image (#270), A8 targets in the red
# lane (#271), GPU profile read when NVRM publishes one (3f117ab, inert here), #274's _mipsWritten guard on our tiled-mip re-sync.
# Not taken: #263 (our ANGLE constructor covers it), #274's CPU mip fill (b4041b08 stays),
# kernel-ABI marks (e75be1e, 79f47d0, 40daaa6), the 2.3.6 OpenGL draw path. Tests: catest/a8target, fetchpart, tiledmipsown. Replaceable: 302fa176.
# 2026-10-19 05658421 = 3492ac34 + the 2.3.6 OpenGL draw path (6372823, plugin part): depth bias enable, provoking vertex
# (dynamic, and Apple GL's NVIDIA profile told the encoder takes it), per-instance step rates (vertex attribute divisor),
# primitive restart off, texture-buffer views, GL vblank wait by the display period, buffer bindings in arrays, sampler-key
# cache, texel-buffer pipelines on the set-reuse path, graphics set/pipeline binds skipped when unchanged; plus OUR fix: the
# IOSurface use count is held from commit to completion, not from encode (every windowed NSOpenGLContext app hung on its
# first flushBuffer). Tests: catest/gl236 glfeat (5/6, R8I through Apple's swizzled view still wrong), glvsync, usecount.
# Replaceable: 3492ac34. Rollback: 'install.sh m236gl' = plugin 3492ac34 only.
# 2026-10-19 b220dfe2 = 05658421 + the GL vblank wait waits until the window server has TAKEN the previous frame, not just
# to the vblank (it takes it 0.4-2.7 ms after): a vsync'd GL window ran ~200 fps on 165 Hz and every other frame was
# dropped unseen; now ~152 fps, 0 frames replaced (catest/gl236/glvsync gate: fps <= display Hz). Replaceable: 05658421.
# Rollback: 'install.sh gl236' = plugin 05658421 only.
# 2026-10-19 854b82c8 = b220dfe2 + integer textures: reflection answers textureDataType Int/UInt from the translator's
# texture_shape (was Float for every texture, so Apple's GL bound R8Snorm/R8Unorm views to isampler/usampler and read float
# bits), textureType from its fields (was 2D for all but cubes), and a texel-buffer view whose swizzle is the format's own
# fill (Apple's GL asks r,0,0,1) is the identity instead of nil. Tests: catest/gl236 glfeat 6/6, itex 7/7.
# Replaceable: b220dfe2. Rollback: 'install.sh itexprev' = plugin b220dfe2 only.
# 2026-10-19 f153c579 = 854b82c8 + NullMoth 2.3.7 bounds fixes: 5d8f92d (shader bitcode outside [4 B, 64 MB] not read in
# process, a bitcode-reader ERROR refuses the module, argument-encoder setBuffer offset past the buffer refused), 4151e0d (texture
# region/level/slice that does not fit 32 bits refused before narrowing; texel-buffer region bound by subtraction) and the
# nvmtl_vk.c image read/write region bound by subtraction (1321113). catest/secreg 7/7 (854b82c8: 5 FAIL + 2 SIGBUS).
# Replaceable: 854b82c8. Rollback: 'install.sh sec237prev' = plugin 854b82c8 + translator 3b42129d.
# 2026-10-19 1eae68fa = f153c579 + the plugin side of NullMoth 79f47d0 / e75be1e / 40daaa6 (the kernel side came with the 2.3.7
# kernel): in WindowServer every surface a command buffer renders is marked pending in NVAccel at commit and ready after the last
# part that writes it (NVRM_SS_PLANE_GPU_MARK), its shared VRAM marked newest at commit so a capture/lock-screen lock pages it off
# and waits (black screenshots, blank Dock thumbnails, black lock screen), the re-mark a try (NVRM_SS_PLANE_TRYLOCK); and
# commitAndWaitUntilSubmitted no longer waits for completion (the swap waits in NVAccel). Branch gl-2.3.6 in src/wt-gl236.
# Tests: catest/wsmark as "WindowServer" (capture 24/24, f153c579 0/24). Replaceable: f153c579. Rollback: 'install.sh wsmarkprev'.
GOOD_PLUGIN=1eae68faed708cd5e8e63c063959f3798dd42efa9ea7921b9e1046d0ee572ade
OLD_GOOD="f153c5792954eac89d9d8a21d952125bd2ff8c42e6412ecb6eef6e84072e14d7 854b82c8495f31ea7f0caea16c3560ce255b7af081d8081b3127b73f0daea6c6 b220dfe2cf7d0df00770d3192e0355849cf32cbc6cb9d0736be96d1b660941cf 056584214254fa8ff0bdea119e8b7c96d5b7d8f6d79d33aee483fdbb4dad0f2d 3492ac34e1faf97d8eb24b539d69d868e4f8df0c7230c9feec551171b411b218 302fa1766c0e763a4ce7000bd1e61d1e14924ad3b3ec34cc46344d201a3863a3 9952f8744d0914ca1aa0b1f0aa10792bcbe49a284f200b7e16da0d134b33d1bd d6d309f8072e6fee2b7c08633185468962ccc180311620cc7e9e97501b4a146e b4041b081f2753b3229778945ee50667eaecbd1f02ae217b6a2e08aca2940437 e8328b6a41dd8e6985a2e8f7179f9780b4cfd2e15e41fd0cb744b91cc36a9002 133fa8230dd0a5eb06574076ca713505fa5ba74bd7f6302c20fb18d4ec32e05f 93c3be149b5ab2b2fac2f8ddafb475c4305c090335a67e8ea78ff1d2792f232f dbbc77ecab5df8287e4a2ea7a6882ad9c7e0c809a640e17326deec3a81238b06 4eb05cf429d9d6e1afd8dd2aaa636ed01457d6288075eb9a8f25f8e5d3fc79d3 0eae96ab470576e8cec84898875ec08100122bffd5ff62cd83fda028af881ad2 3108990ae5f7f78cc1a73590efb6a1db2e168f87cab798424d88c35ad4405119 3c2ff6d8dd8c825075b4878071bda7a8c002e25da80376e1b74c95dc342ae1f8 ac789120bc899390c3ccce2c6c643a564319fd8d79da2259b4ec98ce05336ca9 d8aa6e316fefded9b61f1ce9e27a83fefb8e562a3f60119d92a548346cb3937b dc90cf35c552510594396910840882083000295e3c2b98d140f8748c1ddf3b18 04842a7de6f4d948554926bc9e66c375638c6c031f9b221b1c1fccc657dfefd5 0a322a7221344dbdbddcd926d68e32893de4afcac85a6190c2c15aacaeb12aa4 ab73ca6165b3b9815099eb1a9c899686d0eacd4306138b9a9d0495c4d41e6553 78715fbf6e214fc81e392f30d01c3ddb1bdc1dc3a2fa2d2ac5c7ba18c60a68f3 500625c8a5a32256395bcb0022d4f92dd243530dc97a0867a70b373c79b2a642 c8f5027773c1069be0759b612232a184d87afe6b02be26717316dcfb4fa536a1 7e74f345d4569bfbd22cc2cde1ec669848d992ea8d3636720e9b7ca4d765931f aaa7f9fd1cf4255f5b311caebf29d89a2804028338d46a7308664708414b4c67 16437f5805483ddbc6447743a4cde1d474a22a0cea0d53ab71569b16845449cf 4d46bf2a532816c718deb7ce75ea535352a9862e98c756d008e5ee21c891f6b7 1a60d9b6292720d955f175c94bfca770ed30c542f6db0a7eff9db683114088cb e061e82ebf24256c44d878248e278b03c6f5ab490844e8c0d65ba46ee5dccdc1 f11d117fbb9426ff78bce8eacd156bc9328386b8085c8ef6a7a05d1b227769c6 1bb7a0196b186ca33659c42b9e2a673ccf3e8e7c0ecad29b9e79a37847b07e0c ba00854b7c53679da1af4da52296676b4b5a37fc3a813f9fd77bda1c7c9fdd9a a3ca74b2c4360178bc8f78b4e808e9af1721b6f4651a8a7060c1763d39eee24d 2d82e19dae75a85bd53ffb8764f5d31790b77ac5e7a1967f48f008db1ff7bfa0 5a1c90ade3cd019388114d9a5d21de27f293799b164f148f53636c68a912299e 02312aa725cb7fb81052b6cb5ba3d0072f92a52c12d08f9e3508486a49991a85 ab942f5ad7a93518dc64928b24a98525a03105f01a707e7bd7a305ccff1fad12 484577b65f2b1db03131422f1993e36d540b4b3ce8c47d55dfbb3b0da832edc9 d927b6eb094cb5779ab594ebdccb415e276555ff4deff8f6b794360f233e4835 98d0173e590aad14b33cab63eca035ef07e512210930efa892ae0e81afe270a7 83fe25d4c15c0e9169d0cc8ed3260eccfda8499f32b68a5bed7ad399e0d6a85e e9fecfa37bd3cbbff9b3d29aaf5126c73b36d5678d230b253503a7989ee6bdb0 4f6783863f817e366f40c1c614811e397b82c8a3cdc100ec15eff15e763f26a1 f0a4b12846fa02acaeecbbaea99c6c4c7e6ca48ba8bd0460d58347b97a2bf3d5 f76382c8690707a14af9da4c0cd24bd93fa873e5dfbe205b5eeab500741bd3a4 595cec69380ba3fcd205c2e2c22355ecb418ad3dc0b0c4ba771708b120b0b85f 0d0a62db4eca4f4301eb1d746b27c303da07d046c94ca0940ed5867ea12006c8 4e9f1df764595614646f5d8afed87d59d2f050e8c78000f4ca8261567ec643b4 a80e587316c96288a50b833a6fdaa44a1e52fb0e4df6f8ba93eb65ba12d1e419 da12f0be414e521641232b70ff12e9c669b9fcde4e60f29183c8c8b9dd413518 033f194194e9b9d78e60ea9d6734e6d3701a00e39565728fd0a54be018dff12b 158aada056b0fe13708968bf030bccec237db77a41d191ae00e175200bbbb023 994cea3e2b604717025d1deaffc19737e9e8efc50e29cd2767b32634019204df bc31edeb4b754e334ae0ec9d1259ebeb3cf6e13d2b0cd78cf1d7119920838c70 b5d6d1fb55eeb81e41e7df8e4e477ce93b56d7df72fdd7b8b07ecf481d4c1cff 01bbcbe743e24d2e37e4452a72718ed0aad1970a928959e1d3124d9c6d9cfc29 3d705cbe094ddd23143310681cff1e0fea4819ef75c9713032f850e9c57dc8c7 737e422ee2656b67968598c116747188cd4bba624c38d0d9ff1e42709e20e7a6 9cef88d86490a22ed921241deaf0e62642cdfef97d273fec6cd158390e913ec1 a72c5a49be623e42f014b03dabd68f874688a5c2deaebc509b53faec64f36394 b1648b6acd55ace9a6319cb2c04ffab3e6b2ff0ffa8c21f658fb7a394af53d35 b769342fc57710b0f512cdd4a9f39528045361ece0401d31f258433a826fec74 62babe9791a28f6cc43d7bf943886ac3f9661a166191645e3521f57c2f6d09fc 6ab700f8b0406df5b6d7fb14fbfb475bdb6a9c3ab854077a4d12405ed178ac45 0b5aca21e5671ed6a8c7c24e71b8d46da9b57cd4e878aaad667dd12ff6bb63ce e18e98828438b08b4269180325d828d17fdd4f528ebc084adc13046c399251ca e29f5a4bdd9216ba921f1e437a5f8175b04c467ae786ba6d122d3b46051782b8 e242cfa57b59e956717ef562a9a3039389aaa7025f3d190061014f1f7cbfc574 d5067a4f233a5509348c4477c0a681a318e90117062390853fff6c4059e2bff1 d76d4bee86f120e6d63ec400992a114abf0df8baafe641f43c4c91f0919dd202 a7c70f3931bd0c148f91a33cd276fd8ff736927c316e9635b13f9c5719a3f345 863d343ca0fa837b07827aed38b42f22cd7bebe711d4d7b1ce7bfd7d5d2ba1b6 41b8ebb77bd5e80727d106970171454463034c0d1af34631405475f19c952b05 a1eca8799ef43cec6ee519e8794683d1f06f560c509b4015cf1d3a3909ead256 3862f11febf5bbf6759fe7b945453c1d97dca8e013fce3a6c20e0cd908d097e9 e3c9b14e47713a6061b1d57186d6b23affa35e0d8d57421d9fa9bdb82488d691 f0856a03820e7d100525c07e7a88418cde46e086c12cf248d10049c2a5fab27d 3daf2b9a37c09380f508b02f8e1ca1c51f972bd13e4c267955836e1785066f8a 66d936125df700712219aa54c113c208175b25b6c26b9d2af7b385a353703879"
# shader translator rebuilt from source with get_num_samples() as a spec constant (stock NullMoth 1.0.0 build: eba8fee8)
STOCK_XLATE=eba8fee840d953b7c29229541386f710639c8445ecab28a2a559a8b36a1786b3
# 2026-10-11 eb4fb6a3 = 02754ed9 + helpers with a buffer-pointer parameter are emitted after their callers, so the constant byte
# offset the call passes (raw_call_param_offsets) is known: Core Image's _lanczosDownH/V read the sampler transform from byte 0
# instead of 80 and every Lanczos-scaled image (Preview, screenshot thumbnail editor) showed one flat colour per tile
# (patch hidpi/plugin/translator-callers-first.patch, tests hidpi/catest/cikl + cidown). Replaceable: 02754ed9.
OLD_XLATE="50471f26cae32538a8761e8d81f62697df54988d5c0c7a532113e145526b53b2 8e242d50ec5190f954c0d26f9cc447af5461f4c49992477c8f3f847e27ac773d eb4fb6a386a809564e8596a7ef91d09e3c6de9244fe587d5aa8a00edb405ddd3 67faee216b6a78974f5b1239a09d9ea04ad4b3a93bca89ef4d53134d33feefb8 761a54b46d834741109599e23f97b0410ae7d2885764ed6cfbbe9cc2383d3ab2 02754ed92b1c529056a0fb26f7fc0d46883ae5b84435d5fc89db107f7ab9119c"
# 2026-10-12 50471f26 = eb4fb6a3 + NullMoth 1.13.0 translator (inlining/OpenCL/integer-simd fixes). Replaceable: eb4fb6a3.
# 2026-10-12 f62a16e5 = aa11ce8d + NullMoth 1.14.2 translator (upstream raw-cursor helper order replaces our callers-first; wrapper keeps the
# get_num_samples specialization constant instead of upstream's constant 1). Replaceable: aa11ce8d.
# 2026-10-13 2a3e7ea7 = f62a16e5 + a module with the translator's own address table gets its other buffers lowered onto it (texture-
# sampling fragment shaders read setFragmentBytes data through the table, so their set can be reused); 4639 cached modules: 2580
# unchanged, 2059 merged, all 2059 compile with NVK. NVMTL_NO_TABLE_MERGE=1 in nvrm610.conf restores the old lowering.
# 2026-10-13 70c04748 = 2a3e7ea7 + upstream 1.15.0 translator fixes: a kernel that binds a sampler keeps its threadgroup memory length
# (2009ced: VideoToolbox's Metal scaler got 8 of its 16 KB, whole columns of zeros = green lines in Photos), and stage outputs survive a
# buffer type remapping (4b0a8c7; our type_def_of fallback kept). Stock 1.15.0 translator 0ac92ae5 is replaceable.
# 2026-10-14 183ddb7c = 70c04748 + `array<sampler, 1>` entry parameters are bound as a one-element sampler array (src/wt-m115 branch
# sampler1): bound as a plain sampler, ANGLE's TextureEnv store of the parameter became null and a sample in a helper had no sampler
# ("sampler operand is a pointer whose exact sampler state was not recovered") - three.js shadow maps (`sampler2D shadowMap[1]` passed to
# getShadow) lost the WebGL context and Chrome's GPU process restarted. Built from source with MACOSX_DEPLOYMENT_TARGET=15.0. Test:
# catest/sarray1 (+ sarray). 3008 cached shaders old vs new: only that shader changes (fails -> translates). Replaceable: 70c04748.
# 2026-10-16 a649e150 = 183ddb7c + NullMoth 2.0.x translator fixes (planner cache 10e9b51/32afda2, cube arrays/image selects/fcmp ord-uno
# 0d0584d, loop exits + dominance 08d9f46/4ba580e, vector fast_ldexp c19414b, bvec icmp 39f543b) + texture/sampler array elements each
# get their own binding (242dcdb passes::split_descriptor_arrays: the layout has one descriptorCount-1 binding per slot; with
# robustBufferAccess NVK clamped tex[k] to tex[0] - catest/sarray 1/16). METAL2VULKAN_NO_DESCRIPTOR_ARRAY_SPLIT=1: off. Lib tests with
# spirv-val 2150 pass, 18 failures all pre-existing. Replaceable: 183ddb7c.
# 2026-10-18 3cf58ff8 = a649e150 + upstream v2.0.4..v2.3.6 translator: [[visible]] function references that function constants turn off
# are closed against an empty linkage instead of refused (110 of 122 cached MPS kernels: Spotlight, iconservicesagent, mediaanalysisd,
# DockHelper), A8 target variant, atomic image formats / CopyLogical (d17e509), Blender (416ee60, 5092fcb), resource_phi_fold,
# gep_provenance, stage_output. Kept: our table merge (bc81839) + upstream's Block/offset-0 table check; descriptor-array split,
# sampler[1], Graphite outputs, Lanczos offsets, get_num_samples. Lib tests: no new failures. Replaceable: a649e150.
# 2026-10-18 later: 793acd8e = 3cf58ff8 + the after-constants refusal for a [[visible]] reference that is still live and unsupplied:
# one message naming a "visible function reference" wherever the emitter meets it (call or function-pointer value), the phrase the
# plugin defers to pipeline creation on. 3cf58ff8 said "is called on a live path" / "unknown global value @X.MTL_UNRESOLVED_VISIBLE_FN"
# instead, RenderBox's custom fragments came back nil and every system icon glyph was black. catest/iconfc: 0 nil, 8 deferred, 8/8
# linked custom_fn pipelines (3cf58ff8: 8 nil, 0/8). Lib tests: same 19 pre-existing failures, +3 tests. Replaceable: 3cf58ff8, a649e150.
# 2026-10-19 3b42129d = 793acd8e + function-constant specialization that actually specializes Core Animation's uber shader:
# fixed_frag_* builds its FragmentShaderConfig struct from the constants in the static initializer and read it through
# select(has_config, @config, buffer) + getelementptr, which never folded - every "specialized" variant was the whole 684 KB
# uber shader, ~3.3 s cold, past CA's budget (it fell back to its generic path for the process: catest cold G 98 vs warm 99).
# Those field loads fold now (meta::static_init_foldable_aggregates + LlModule aggregate image): 684 KB -> 19-24 KB, and the
# text inliner / parser hot spots are output-identical faster: 3.3 s -> ~0.53 s (fixed_frag_lpf_cpf n 60), generic 3.0 -> 2.45 s.
# 280 of 289 captured translations byte-identical (the 9 that change = fixed_frag with fc_generic 0, all spirv-val OK);
# catest suite cold+warm identical to the old stack's warm output. Lib tests: no new failures (18 pre-existing), +3 tests.
# Replaceable: 793acd8e (rollback alias fcfastprev).
# 2026-10-19 ce980d35 = 3b42129d + NullMoth 2.3.7 ce133bf (a single-field struct alloca is not reinterpreted as its field type).
# fixed_frag specialization and generic variant byte-identical, lib tests same 18 pre-existing failures. Replaceable: 3b42129d.
GOOD_XLATE=ce980d35924a8abe41c69cbd78255c9e473413ef6d2005e87c41a3a27bc4e5da
OLD_XLATE="3b42129d7e1d365f493654679804939b97ecfe150477fe8cdbd75c5556507264 793acd8eb504a4a6af05d45c23a6ea854e1d3cf4584348e28c2e57db8c39a93c 3cf58ff8fee680a4fe5867bbb495912ec8cde49678d3cd9e33f1b01c35c5f4d2 a649e150f4b03e1b358bd8716b8014319f3a8153f52c8eec1174d04440d3fd84 183ddb7ce44e13bd4440a318d73adf56ea45e25d92f496683a92885796aec0db 70c047482613355e9c72f49653e82057f4be1e85faf9855fabcd2391b31beef6 2a3e7ea76e00030d29ef19c1f112c431a2f2eb437198852829763263106a689c 0ac92ae5416bda4f33c74e4dc4fd94f7a36a12baee05681f8373bd3743c1d46b f62a16e5752c1a72334f7a1d0ce49e036b230268b2a263ebb3aca374a8097b6b aa11ce8dd0a7aec5bc9a9111c6abf737cb44c19f770050faeca41d4db8badc50 $OLD_XLATE"
# patched Vulkan driver (bindfix build; ICD loaded by the plugin and by every Metal client). Stock = NullMoth's; the others are earlier patched builds.
STOCK_VK=372c257b551cc0c4591239003151f6ac3cb80a947765b5639acfdb5a80e74ebc   # NullMoth 1.9.0 (1.0.10 stock was bd879ca7)
OLD_VK="bd879ca71229b690a26392fd52d569703febe3dcf9e7b63a8100bd2c872057ec 4d9ceab1c4ae7c752c9b2f8c1eaa6302de70b337aee24cc2270e550137ac0d75 864c2931c3634998ecca4ad2493539f1158b4e9d2a4e88df889c86f2fff99ee6 780adb3f60f163fee7f6eb9a7e09a7e2dd446bbd7169676e96b45397be26a874"
# 1.9.0 Vulkan driver + our three patches re-derived by vk-patched/mk-bindfix-190.py (previous good build: 4d9ceab1 = vk.bindfix.dylib on 1.0.10)
# 2026-10-13 19bbfc23 = d94ea1a3 without our hw.memsize rewrite (vk-patched/mk-nomem-190.py): the plugin's sysconf fallback (upstream
# 1.14.5) answers it now. NEEDS plugin dbbc77ec+: an older plugin with this driver has no device in Chrome's GPU sandbox.
# 2026-10-13 403d4d40 = STOCK NullMoth 1.15.0 Vulkan driver, no patches of ours left: upstream has the read-only /dev/null fd (e4d8ca8)
# and the unbind-before-pooling of a closed connection (bee05d1), plus three aborts turned into errors (unknown SM version, stale MSAA
# sample count in an internal copy draw, GPU checks). Same NVK sources as 1.14.2 apart from bee05d1, which our plugin is built against.
# 2026-10-14 c866c85d = 403d4d40 + ZCULL on (vk-patched/mk-zcull-115.py): Mesa 26.x NVK carries upstream zcull but the NVRM backend set
# has_zcull_info = false; a cave now fills it from NV2080_CTRL_CMD_GR_GET_ZCULL_INFO (nvrm610.conf ZCULL_RGN=0 turns it off). Late-Z fragments
# (ANGLE MSAA WebGL writes sample_mask in every shader) behind nearer depth are culled before shading: catest/earlyz mask occluded 2.98 -> 0.06 ms,
# three.js chess main pass 4.4 -> 2.4 ms; catest suite + rtcheck identical.
# 2026-10-16 8003fbba = NullMoth 2.0.4 NVK (cfa7e20f: remove a mapping from the table before freeing it e4f3312, a zero-count push method
# header no longer aborts c74aebc, quieter diagnostics) + the same ZCULL cave (vk-patched/mk-zcull-204.py; nvkmd_nvrm_enum_pdev is
# instruction-identical to 1.15.0's, addresses +0x4600). Replaceable: c866c85d.
# 2026-10-18 b81c1cb8 = NullMoth 2.0.5 NVK as shipped in 2.3.6 (a3a6451e: release build - no asserts; Ada's async copy engine for the
# upload queue; NAK stencil export) + the ZCULL cave re-derived for it (vk-patched/mk-zcull-236.py; earlyz 2.96 -> 0.07 ms). Replaceable: 8003fbba.
GOOD_VK=b81c1cb86b46a0e19e6c0257c32093256d7e997300929168ad9ad70298da5a29; VK_SRC=$SYS/vk-patched/vk236.zcull.dylib
OLD_VK="8003fbba3a57cbea8e0e22fb78fbd20638c8437d2240c05b8dc99399231df01e c866c85d695d21c8497f14e9672f6beac97172d86df7c77473b344bbaad5bdf2 403d4d40ff7b53d2d3ee72b4dd8b0e3ec0a4db5def34570ac098b32b18836ddb 19bbfc23ab78d7a197510a515e535a02dab869903ffec17f5bb7386f3a6c3661 d94ea1a395841c3cf1b666ce1f4ffd056751899628c652d19f644c943cbe5d50 $OLD_VK"

# 2026-10-12: GOOD = the ad-hoc SIGNED sampler-array builds (plugin dc90cf35, translator aa11ce8d; xterm.js WebGL text). The first attempt shipped
# an UNSIGNED translator (0a322a72/8e242d50 are those builds): WindowServer's library validation rejected it -> crash loop. Never pin an unsigned file.
# ROLLBACK: "install.sh previous" pins the builds before them (04842a7d + 50471f26); the sampler-array builds stay replaceable, so the guard puts the old ones back.
# 2026-10-12 later: GOOD = the signed 1.14.2 merge (d8aa6e31 + f62a16e5). ROLLBACK "install.sh sampler" = the sampler-array builds above.
# 2026-10-13: GOOD plugin = ac789120 (surface-in staging reuse). ROLLBACK "install.sh previous" = plugin d8aa6e31, same translator.
# 2026-10-13 later: GOOD plugin = 3108990a (eager-submit: ac789120 + submit-ahead on commit). ROLLBACK "install.sh previous" = ac789120.
# 2026-10-13: 3c2ff6d8 (surface import cache) was installed and REVERTED - Chrome makes a NEW IOSurface per frame (recycled IDs), the cache never hit and held up to 512 MB of freed surfaces; listed in OLD_GOOD so the guard replaces it.
# 2026-10-13 later: GOOD plugin = 4eb05cf4 (rsh-park: 3108990a + a dead texture's tiled render shadow is reused by the next shadow of its size;
# Chrome's masked danmaku layer makes a new IOSurface per frame: newsurf 1856x1024 CPU per surface 1.48 -> 0.93 ms). ROLLBACK "install.sh previous" = 3108990a.
# 2026-10-13 later: GOOD plugin = 0eae96ab (surfin-video: 4eb05cf4 + video (multi-plane) surfaces re-uploaded by a GPU copy straight from
# their pages, waited for under the lock: WindowServer's per-frame CPU memmove of overlay video frames). ROLLBACK "install.sh previous" = 4eb05cf4.
# 2026-10-13: 0eae96ab REVERTED - no gain for Chrome 4K (WindowServer makes a new texture per frame for the VT pool surfaces, so the
# GPU-from-pages path never ran for them; the one case it ran, 3520x1980, waited ~2.2 ms per plane on WS's main thread). GOOD = 4eb05cf4 again.
PLUG_SRC=$NVS/hidpi/plugin/NVMTLDriver.wsmark-signed; XL_SRC=$NVS/hidpi/plugin/libnvmtl_translate.dylib.sec237-signed
# NVMTL_RES2_WS=1 (2.3.6 package default): Metal reports the whole VRAM as its working set; every rollback alias puts 0 back
RES2_WS=1
# "install.sh previous" (alias m236prev) = the NullMoth 2.0.4 merge: plugin 302fa176 + translator a649e150 + Vulkan driver 8003fbba.
# "install.sh fcfastprev" = only the translator back to 793acd8e (before the Core Animation config fold; plugin + Vulkan driver stay)
# "install.sh wsmarkprev" = only the plugin back to f153c579 (before the WindowServer GPU marks; translator + Vulkan driver stay)
case ${1:-} in wsmarkprev)
  OLD_GOOD="$GOOD_PLUGIN $OLD_GOOD"; GOOD_PLUGIN=f153c5792954eac89d9d8a21d952125bd2ff8c42e6412ecb6eef6e84072e14d7; PLUG_SRC=$NVS/hidpi/plugin/NVMTLDriver.sec237-signed ;;
esac
# "install.sh sec237prev" = plugin 854b82c8 + translator 3b42129d (before the 2.3.7 bounds fixes); every other alias starts from it
case ${1:-} in ''|sec237prev|wsmarkprev) ;; *)
  OLD_GOOD="$GOOD_PLUGIN $OLD_GOOD"; OLD_XLATE="$GOOD_XLATE $OLD_XLATE"
  GOOD_PLUGIN=854b82c8495f31ea7f0caea16c3560ce255b7af081d8081b3127b73f0daea6c6; PLUG_SRC=$NVS/hidpi/plugin/NVMTLDriver.itex-signed
  GOOD_XLATE=3b42129d7e1d365f493654679804939b97ecfe150477fe8cdbd75c5556507264; XL_SRC=$NVS/hidpi/plugin/libnvmtl_translate.dylib.fcfast-signed ;;
esac
case ${1:-} in sec237prev)
  OLD_GOOD="$GOOD_PLUGIN $OLD_GOOD"; GOOD_PLUGIN=854b82c8495f31ea7f0caea16c3560ce255b7af081d8081b3127b73f0daea6c6; PLUG_SRC=$NVS/hidpi/plugin/NVMTLDriver.itex-signed
  OLD_XLATE="$GOOD_XLATE $OLD_XLATE"; GOOD_XLATE=3b42129d7e1d365f493654679804939b97ecfe150477fe8cdbd75c5556507264; XL_SRC=$NVS/hidpi/plugin/libnvmtl_translate.dylib.fcfast-signed ;;
fcfastprev)
  OLD_XLATE="$GOOD_XLATE $OLD_XLATE"; GOOD_XLATE=793acd8eb504a4a6af05d45c23a6ea854e1d3cf4584348e28c2e57db8c39a93c; XL_SRC=$NVS/hidpi/plugin/libnvmtl_translate.dylib.vfn-signed ;;
esac
case ${1:-} in previous|m236prev)
  OLD_GOOD="$GOOD_PLUGIN $OLD_GOOD"; GOOD_PLUGIN=302fa1766c0e763a4ce7000bd1e61d1e14924ad3b3ec34cc46344d201a3863a3; PLUG_SRC=$NVS/hidpi/plugin/NVMTLDriver.m204-signed
  OLD_XLATE="$GOOD_XLATE $OLD_XLATE"; GOOD_XLATE=a649e150f4b03e1b358bd8716b8014319f3a8153f52c8eec1174d04440d3fd84; XL_SRC=$NVS/hidpi/plugin/libnvmtl_translate.dylib.m204-signed
  OLD_VK="$GOOD_VK $OLD_VK"; GOOD_VK=8003fbba3a57cbea8e0e22fb78fbd20638c8437d2240c05b8dc99399231df01e; VK_SRC=$SYS/vk-patched/vk204.zcull.dylib ;;
# "install.sh xlate204" (alias m236xlate) = the 2.3.6 user-space set EXCEPT the translator: plugin 3492ac34 + Vulkan driver
# b81c1cb8 stay, translator goes back to a649e150. 2026-10-18 bisect: 3cf58ff8 refuses the visible-function calls that
# Apple's icon shaders (custom_fn / IconRendering glassHighlight_v1, glow_v1, sdfFill_v1) specialize through function
# constants, and every system app icon renders as a black glyph; swapping only the translator fixes it, WS settings and
# plugin/NVK are innocent. Replaceable: 3cf58ff8, so a reinstall of the 2.3.6 set gets the old translator put back.
# Since 793acd8e (the root fix) this alias is the rollback of that translator too.
itexprev)
  OLD_GOOD="$GOOD_PLUGIN $OLD_GOOD"; GOOD_PLUGIN=b220dfe2cf7d0df00770d3192e0355849cf32cbc6cb9d0736be96d1b660941cf; PLUG_SRC=$NVS/hidpi/plugin/NVMTLDriver.glvbl-signed ;;
gl236)
  OLD_GOOD="$GOOD_PLUGIN $OLD_GOOD"; GOOD_PLUGIN=056584214254fa8ff0bdea119e8b7c96d5b7d8f6d79d33aee483fdbb4dad0f2d; PLUG_SRC=$NVS/hidpi/plugin/NVMTLDriver.gl236-signed ;;
m236gl)
  OLD_GOOD="$GOOD_PLUGIN $OLD_GOOD"; GOOD_PLUGIN=3492ac34e1faf97d8eb24b539d69d868e4f8df0c7230c9feec551171b411b218; PLUG_SRC=$NVS/hidpi/plugin/NVMTLDriver.m236-signed ;;
xlate204|m236xlate)
  OLD_XLATE="$GOOD_XLATE $OLD_XLATE"; GOOD_XLATE=a649e150f4b03e1b358bd8716b8014319f3a8153f52c8eec1174d04440d3fd84; XL_SRC=$NVS/hidpi/plugin/libnvmtl_translate.dylib.m204-signed ;;
esac
if [[ -n ${1:-} && ${1:-} != xlate204 && ${1:-} != m236xlate && ${1:-} != m236gl && ${1:-} != gl236 && ${1:-} != itexprev && ${1:-} != fcfastprev && ${1:-} != sec237prev && ${1:-} != wsmarkprev ]]; then RES2_WS=0; fi
# "install.sh m204prev" = the stack before the NullMoth 2.0.4 merge: plugin 9952f874 + translator 183ddb7c + Vulkan driver c866c85d.
# Every older alias below starts from it, so each one pins a whole plugin/translator/driver set.
case ${1:-} in m204prev|zcullprev|sampler1prev|tiledprev|vtfix133|drawcost)
  OLD_GOOD="$GOOD_PLUGIN $OLD_GOOD"; GOOD_PLUGIN=9952f8744d0914ca1aa0b1f0aa10792bcbe49a284f200b7e16da0d134b33d1bd; PLUG_SRC=$NVS/hidpi/plugin/NVMTLDriver.xsync-signed
  OLD_XLATE="$GOOD_XLATE $OLD_XLATE"; GOOD_XLATE=183ddb7ce44e13bd4440a318d73adf56ea45e25d92f496683a92885796aec0db; XL_SRC=$NVS/hidpi/plugin/libnvmtl_translate.dylib.sampler1-signed
  OLD_VK="$GOOD_VK $OLD_VK"; GOOD_VK=c866c85d695d21c8497f14e9672f6beac97172d86df7c77473b344bbaad5bdf2; VK_SRC=$SYS/vk-patched/vk115.zcull.dylib ;;
esac
# "install.sh zcullprev" = plugin b4041b08 (no cross-process IOSurface sync) + Vulkan driver 403d4d40 (stock 1.15.0, no ZCULL), translator 183ddb7c
if [[ ${1:-} == zcullprev || ${1:-} == sampler1prev ]]; then
  OLD_GOOD="$GOOD_PLUGIN $OLD_GOOD"; GOOD_PLUGIN=b4041b081f2753b3229778945ee50667eaecbd1f02ae217b6a2e08aca2940437
  PLUG_SRC=$NVS/hidpi/plugin/NVMTLDriver.tiledmips-signed
  OLD_VK="$GOOD_VK $OLD_VK"; GOOD_VK=403d4d40ff7b53d2d3ee72b4dd8b0e3ec0a4db5def34570ac098b32b18836ddb; VK_SRC=$SYS/vk-patched/vk115.stock.dylib
fi
# "install.sh sampler1prev" = translator 70c04748 (before the one-element sampler array fix) as well
if [[ ${1:-} == sampler1prev ]]; then
  OLD_XLATE="$GOOD_XLATE $OLD_XLATE"; GOOD_XLATE=70c047482613355e9c72f49653e82057f4be1e85faf9855fabcd2391b31beef6
  XL_SRC=$NVS/hidpi/plugin/libnvmtl_translate.dylib.m115-signed
fi
# "install.sh tiledprev" = plugin e8328b6a (before the tiled-texture mip chain fix), same translator and Vulkan driver
if [[ ${1:-} == tiledprev ]]; then
  OLD_GOOD="$GOOD_PLUGIN $OLD_GOOD"; GOOD_PLUGIN=e8328b6a41dd8e6985a2e8f7179f9780b4cfd2e15e41fd0cb744b91cc36a9002
  PLUG_SRC=$NVS/hidpi/plugin/NVMTLDriver.vtfix-signed
fi
# "install.sh vtfix133" = plugin 133fa823 (the 1.15.0 merge before the descriptor-set reuse fix), same translator and Vulkan driver
if [[ ${1:-} == vtfix133 ]]; then
  OLD_GOOD="$GOOD_PLUGIN $OLD_GOOD"; GOOD_PLUGIN=133fa8230dd0a5eb06574076ca713505fa5ba74bd7f6302c20fb18d4ec32e05f
  PLUG_SRC=$NVS/hidpi/plugin/NVMTLDriver.m115-signed
fi
# "install.sh drawcost" = the stack before the 1.15.0 merge: plugin 93c3be14 + translator 2a3e7ea7 + Vulkan driver 19bbfc23
if [[ ${1:-} == drawcost ]]; then
  OLD_GOOD="$GOOD_PLUGIN $OLD_GOOD"; GOOD_PLUGIN=93c3be149b5ab2b2fac2f8ddafb475c4305c090335a67e8ea78ff1d2792f232f
  PLUG_SRC=$NVS/hidpi/plugin/NVMTLDriver.drawcost-signed
  OLD_XLATE="$GOOD_XLATE $OLD_XLATE"; GOOD_XLATE=2a3e7ea76e00030d29ef19c1f112c431a2f2eb437198852829763263106a689c
  XL_SRC=$NVS/hidpi/plugin/libnvmtl_translate.dylib.drawcost-signed
fi
# plugins before 133fa823 run on the Vulkan driver 19bbfc23 (1.9.0 + our /dev/null and unbind patches)
if [[ ${1:-} == drawcost || ${1:-} == sbfd ]]; then
  OLD_VK="$GOOD_VK $OLD_VK"; GOOD_VK=19bbfc23ab78d7a197510a515e535a02dab869903ffec17f5bb7386f3a6c3661; VK_SRC=$SYS/vk-patched/vk190.nomem.dylib
fi
if [[ ${1:-} == sbfd ]]; then
  OLD_GOOD="$GOOD_PLUGIN $OLD_GOOD"
  GOOD_PLUGIN=dbbc77ecab5df8287e4a2ea7a6882ad9c7e0c809a640e17326deec3a81238b06
  PLUG_SRC=$NVS/hidpi/plugin/NVMTLDriver.sbfd-signed
  OLD_XLATE="$GOOD_XLATE $OLD_XLATE"; GOOD_XLATE=f62a16e5752c1a72334f7a1d0ce49e036b230268b2a263ebb3aca374a8097b6b
  XL_SRC=$NVS/hidpi/plugin/libnvmtl_translate.dylib.m114-signed
fi
# "install.sh rpark" = the stack before the sandbox fallbacks (plugin 4eb05cf4 + translator f62a16e5 + Vulkan driver d94ea1a3), for A/B tests
if [[ ${1:-} == rpark ]]; then
  OLD_GOOD="$GOOD_PLUGIN 93c3be149b5ab2b2fac2f8ddafb475c4305c090335a67e8ea78ff1d2792f232f dbbc77ecab5df8287e4a2ea7a6882ad9c7e0c809a640e17326deec3a81238b06 $OLD_GOOD"
  GOOD_PLUGIN=4eb05cf429d9d6e1afd8dd2aaa636ed01457d6288075eb9a8f25f8e5d3fc79d3
  PLUG_SRC=$NVS/hidpi/plugin/NVMTLDriver.rpark-signed
  OLD_XLATE="$GOOD_XLATE $OLD_XLATE"; GOOD_XLATE=f62a16e5752c1a72334f7a1d0ce49e036b230268b2a263ebb3aca374a8097b6b
  XL_SRC=$NVS/hidpi/plugin/libnvmtl_translate.dylib.m114-signed
fi
# plugins before dbbc77ec lack the sysconf fallback, so they get the Vulkan driver that still carries our hw.memsize patch
if [[ ${1:-} == sampler || ${1:-} == rpark ]]; then
  OLD_VK="$GOOD_VK 19bbfc23ab78d7a197510a515e535a02dab869903ffec17f5bb7386f3a6c3661 $OLD_VK"; GOOD_VK=d94ea1a395841c3cf1b666ce1f4ffd056751899628c652d19f644c943cbe5d50; VK_SRC=$SYS/vk-patched/vk190.bindfix.dylib
fi
if [[ ${1:-} == sampler ]]; then
  OLD_GOOD="$GOOD_PLUGIN $OLD_GOOD"; OLD_XLATE="$GOOD_XLATE $OLD_XLATE"
  GOOD_PLUGIN=dc90cf35c552510594396910840882083000295e3c2b98d140f8748c1ddf3b18
  GOOD_XLATE=aa11ce8dd0a7aec5bc9a9111c6abf737cb44c19f770050faeca41d4db8badc50
  PLUG_SRC=$NVS/hidpi/plugin/NVMTLDriver.sampler-array-signed; XL_SRC=$NVS/hidpi/plugin/libnvmtl_translate.dylib.sampler-array-signed
fi
for f in $PLUG_SRC $XL_SRC; do codesign --verify --strict $f 2>/dev/null || { echo "STOP: $f is not validly code-signed (WindowServer rejects unsigned dylibs)"; exit 1; }; done
mkdir -p $G
chflags -R noschg $G 2>/dev/null || true   # the snapshot is kept immutable between installs
cp $SYS/nvdec-patched/h264.t2d.dylib $G/libnvdec_h264.dylib
# Since the 1.13 plugin a non-Blackwell GPU loads libnvdec_h264_t2d.dylib (upstream's name for the mode-0 decoder); it was never installed, so
# H.264 hardware decode was not registered at all (dlopen failed). Our t2d build is that library; the guard creates it when it is missing.
# 2026-10-12 later: the t2d-name decoder is the 8-byte detile build (nvdec-patched/mk-detile8.py: nvd264_detile copied one byte per
# iteration; 4K 26.8 -> 12.6 ms/frame, 1080p 6.3 -> 2.8 ms, bit-exact). NVGUARD_T2D=old pins the previous byte-loop build (1b5d08ba).
# 2026-10-13: the t2d-name decoder is the t2d8 build + a sleeping NVDEC wait (nvdec-patched/mk-sleep.py: decode_pending spun on
# clock_gettime for the whole decode; now polls every 50 us via mach_wait_until like the HEVC decoder): CPU per frame 4K 8.0 -> 3.7 ms,
# 1080p 2.45 -> 0.86 ms, same wall time, bit-exact (decbench).
# 2026-10-19: 2.3.7 fixes the conformance-window out-of-bounds write. The t2d-name decoder is now the 2.3.7 build with the
# same detile + sleep patches (af0ca14b); the 2.3.7 HEVC decoder is be2f3454. Old builds remain available for rollback:
# NVGUARD_T2D=t2d8s (e641afb3), t2d8 (703c1f2c), old (1b5d08ba) and NVGUARD_HEVC=old (bf11a0bd).
T2D_SRC=$SYS/nvdec-patched/h264.237.t2d8s.dylib; T2D_SHA=af0ca14b878f538d5e29c6180b109ed7f26865b98660410856ec16f9bea8498b
[[ ${NVGUARD_T2D:-} == t2d8s ]] && { T2D_SRC=$SYS/nvdec-patched/h264.t2d8s.dylib; T2D_SHA=e641afb31e8cab30b13352f9d9e5cacd460d4ba3fcdbe6a2430093dbedece453; }
[[ ${NVGUARD_T2D:-} == t2d8 ]] && { T2D_SRC=$SYS/nvdec-patched/h264.t2d8.dylib; T2D_SHA=703c1f2c1666684b30fc3e17d97e09abb9dfecf03f586ee08488baa8dc39a6d8; }
[[ ${NVGUARD_T2D:-} == old ]] && { T2D_SRC=$SYS/nvdec-patched/h264.t2d.dylib; T2D_SHA=1b5d08ba7cb95804e076d0be30c994bc15121ec4c4345f587dc45e34adffe1bf; }
HEVC_SRC=$SYS/nvdec-patched/hevc.237.dylib; HEVC_SHA=be2f34544e27efc0234d974021e5cf8bba3c6e0fce7b736d22e59a40e213ab21
[[ ${NVGUARD_HEVC:-} == old ]] && { HEVC_SRC=$SYS/nvdec-patched/hevc.orig.dylib; HEVC_SHA=bf11a0bddd05e387f9b793ff80390314680df8c0ed92401e75b6cab7740b4eaf; }
codesign --verify --strict $T2D_SRC 2>/dev/null || { echo "STOP: $T2D_SRC is not validly code-signed"; exit 1; }
[[ $(sha $T2D_SRC) == $T2D_SHA ]] || { echo "t2d decoder in the project is not the expected build - stop"; exit 1; }
cp $T2D_SRC $G/libnvdec_h264_t2d.dylib
codesign --verify --strict $HEVC_SRC 2>/dev/null || { echo "STOP: $HEVC_SRC is not validly code-signed"; exit 1; }
[[ $(sha $HEVC_SRC) == $HEVC_SHA ]] || { echo "HEVC decoder in the project is not the expected build - stop"; exit 1; }
cp $HEVC_SRC $G/libnvdec_hevc.dylib
cp $SYS/nvenc-patched/h264.final.dylib $G/libnvenc_h264.dylib
[[ $(sha $G/libnvdec_h264.dylib) == 1b5d08ba7cb95804e076d0be30c994bc15121ec4c4345f587dc45e34adffe1bf ]] || { echo "nvdec copy checksum mismatch"; exit 1; }
[[ $(sha $G/libnvenc_h264.dylib) == 2b231d508b2d886afb8de51b950071b905fbd23d88c635bfda968a0855d28231 ]] || { echo "nvenc copy checksum mismatch"; exit 1; }
[[ $(sha $PLUG_SRC) == $GOOD_PLUGIN ]] || { echo "merged plugin in the project is not the expected build - stop"; exit 1; }
cp $PLUG_SRC $G/NVMTLDriver; echo "plugin snapshot: merged build ${GOOD_PLUGIN[1,16]}"
[[ $(sha $XL_SRC) == $GOOD_XLATE ]] || { echo "translator in the project is not the expected build - stop"; exit 1; }
cp $XL_SRC $G/libnvmtl_translate.dylib
codesign --verify --strict $VK_SRC 2>/dev/null || { echo "STOP: $VK_SRC is not validly code-signed"; exit 1; }
[[ $(sha $VK_SRC) == $GOOD_VK ]] || { echo "patched Vulkan lib in the project is not the expected build - stop"; exit 1; }
cp $VK_SRC $G/libvulkan_nouveau.dylib
{ echo "libnvdec_h264.dylib ebf782888d4663955f6d7ce04dc158b7b5cfb78f48651450305b3e56abf88d15"
  echo "libnvdec_h264_t2d.dylib ebf782888d4663955f6d7ce04dc158b7b5cfb78f48651450305b3e56abf88d15 1b5d08ba7cb95804e076d0be30c994bc15121ec4c4345f587dc45e34adffe1bf 703c1f2c1666684b30fc3e17d97e09abb9dfecf03f586ee08488baa8dc39a6d8 e641afb31e8cab30b13352f9d9e5cacd460d4ba3fcdbe6a2430093dbedece453 5454198cf7bef01fa3a6a543ab845567a245ffb3eb5b8468c0c3985aa9f40f43"
  echo "libnvdec_hevc.dylib bf11a0bddd05e387f9b793ff80390314680df8c0ed92401e75b6cab7740b4eaf be2f34544e27efc0234d974021e5cf8bba3c6e0fce7b736d22e59a40e213ab21"
  echo "libnvenc_h264.dylib 164f6dfa409352e90b079659578a012dc37d1fba364067b99cb8c7bf337b1b5d"
  echo "NVMTLDriver $STOCK_PLUGIN $UPSTREAM_RESSET $OLD_GOOD"
  echo "libnvmtl_translate.dylib $STOCK_XLATE $OLD_XLATE"
  echo "nvmtl/libvulkan_nouveau.dylib $STOCK_VK $OLD_VK"; } > $G/files.txt
# 2026-10-13: NVMTL_SCHEDULED_WAIT=0 - waitUntilScheduled returns once submitted again (the wait-for-completion was added against Chrome
# flicker that turned out to be the translator vertex-output bug). Real Bilibili 4K HEVC + danmaku: 128-160 -> 165 fps, video drops 0-2% -> 0,
# Chrome GPU process CPU ~116% -> ~34%; user saw no flicker/tearing. Scheduled HANDLERS still run at completion (ZCode fix, separate knob).
# 2026-10-13: the conf as actually in effect since 02:35 (the plugin and NVK take the FIRST line of a key; the old guard only appended
# lines, so its MINPX=3686400 sat unused below MINPX=0): NVMTL_SURF_SHARE_MINPX=0 (all window-sized and smaller IOSurfaces in shared VRAM;
# user saw no black blocks; WS 80 -> 55% under smart-mask danmaku - if black blocks come back, put 3686400 here) and NVRM_EVENT_WAIT=1
# (every process, not only WindowServer, sleeps on GPU completion events instead of spinning: Chrome GPU proc 130 -> 117%).
printf '%s\n' NVMTL_SURF_SHARE_MINPX=0 NVMTL_NO_NVENC_HEVC=1 NVMTL_SCHEDULED_WAIT=0 NVRM_EVENT_WAIT=1 NVMTL_RES2_WS=$RES2_WS > $G/conf.txt
cp $HERE/nvguard.sh $G/nvguard.sh
chown -R root:wheel $G; chmod 755 $G $G/nvguard.sh; chmod 644 $G/*.txt $G/*.dylib; [[ -f $G/NVMTLDriver ]] && chmod 755 $G/NVMTLDriver
( cd $G && rm -f MANIFEST.sha256 && shasum -a 256 * > MANIFEST.sha256 )   # what verify.sh compares against
cat > $PL <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>local.nvguard</string>
	<key>ProgramArguments</key><array><string>/bin/zsh</string><string>$G/nvguard.sh</string></array>
	<key>RunAtLoad</key><true/>
	<key>WatchPaths</key><array><string>$M</string><string>/Library/GPUBundles</string><string>/Library/GPUBundles/nvmtl</string></array>
	<key>ThrottleInterval</key><integer>10</integer>
</dict>
</plist>
PLIST
chown root:wheel $PL; chmod 644 $PL
launchctl bootout system $PL 2>/dev/null || true
launchctl bootstrap system $PL
sleep 5
echo "--- bundle now:"; for f in libnvdec_h264.dylib libnvdec_h264_t2d.dylib libnvdec_hevc.dylib libnvenc_h264.dylib NVMTLDriver libnvmtl_translate.dylib; do echo "  $f $(sha $M/$f | cut -c1-16)"; done
tail -5 /var/log/nvguard.log 2>/dev/null || true
# UU's streamer still has the old encoder loaded: restart UU as the user (never as root).
zsh $SYS/uu-restart.sh >/dev/null 2>&1 && echo "UU restarted" || echo "UU restart failed - run: zsh ~/work/system/uu-restart.sh"
chflags -R schg $G 2>/dev/null && echo "guard snapshot locked (chflags schg; install.sh unlocks it itself)"
echo "guard installed."
