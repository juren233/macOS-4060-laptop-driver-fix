#!/bin/zsh
# LOCAL HARDENING - DO NOT EDIT BY HAND WITHOUT UPDATING THE HASHES BELOW. Registers the exact builds that carry this machine's fixes;
# nvguard.sh restores them if a NullMoth install/update replaces them. Source of truth: git in ~/work/system and ~/work/nvidia-setup/src/repo.
# sudo zsh ~/work/system/nvguard/install.sh          install/refresh the guard (snapshots the current plugin build)
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
GOOD_PLUGIN=04842a7de6f4d948554926bc9e66c375638c6c031f9b221b1c1fccc657dfefd5
OLD_GOOD="ab73ca6165b3b9815099eb1a9c899686d0eacd4306138b9a9d0495c4d41e6553 78715fbf6e214fc81e392f30d01c3ddb1bdc1dc3a2fa2d2ac5c7ba18c60a68f3 500625c8a5a32256395bcb0022d4f92dd243530dc97a0867a70b373c79b2a642 c8f5027773c1069be0759b612232a184d87afe6b02be26717316dcfb4fa536a1 7e74f345d4569bfbd22cc2cde1ec669848d992ea8d3636720e9b7ca4d765931f aaa7f9fd1cf4255f5b311caebf29d89a2804028338d46a7308664708414b4c67 16437f5805483ddbc6447743a4cde1d474a22a0cea0d53ab71569b16845449cf 4d46bf2a532816c718deb7ce75ea535352a9862e98c756d008e5ee21c891f6b7 1a60d9b6292720d955f175c94bfca770ed30c542f6db0a7eff9db683114088cb e061e82ebf24256c44d878248e278b03c6f5ab490844e8c0d65ba46ee5dccdc1 f11d117fbb9426ff78bce8eacd156bc9328386b8085c8ef6a7a05d1b227769c6 1bb7a0196b186ca33659c42b9e2a673ccf3e8e7c0ecad29b9e79a37847b07e0c ba00854b7c53679da1af4da52296676b4b5a37fc3a813f9fd77bda1c7c9fdd9a a3ca74b2c4360178bc8f78b4e808e9af1721b6f4651a8a7060c1763d39eee24d 2d82e19dae75a85bd53ffb8764f5d31790b77ac5e7a1967f48f008db1ff7bfa0 5a1c90ade3cd019388114d9a5d21de27f293799b164f148f53636c68a912299e 02312aa725cb7fb81052b6cb5ba3d0072f92a52c12d08f9e3508486a49991a85 ab942f5ad7a93518dc64928b24a98525a03105f01a707e7bd7a305ccff1fad12 484577b65f2b1db03131422f1993e36d540b4b3ce8c47d55dfbb3b0da832edc9 d927b6eb094cb5779ab594ebdccb415e276555ff4deff8f6b794360f233e4835 98d0173e590aad14b33cab63eca035ef07e512210930efa892ae0e81afe270a7 83fe25d4c15c0e9169d0cc8ed3260eccfda8499f32b68a5bed7ad399e0d6a85e e9fecfa37bd3cbbff9b3d29aaf5126c73b36d5678d230b253503a7989ee6bdb0 4f6783863f817e366f40c1c614811e397b82c8a3cdc100ec15eff15e763f26a1 f0a4b12846fa02acaeecbbaea99c6c4c7e6ca48ba8bd0460d58347b97a2bf3d5 f76382c8690707a14af9da4c0cd24bd93fa873e5dfbe205b5eeab500741bd3a4 595cec69380ba3fcd205c2e2c22355ecb418ad3dc0b0c4ba771708b120b0b85f 0d0a62db4eca4f4301eb1d746b27c303da07d046c94ca0940ed5867ea12006c8 4e9f1df764595614646f5d8afed87d59d2f050e8c78000f4ca8261567ec643b4 a80e587316c96288a50b833a6fdaa44a1e52fb0e4df6f8ba93eb65ba12d1e419 da12f0be414e521641232b70ff12e9c669b9fcde4e60f29183c8c8b9dd413518 033f194194e9b9d78e60ea9d6734e6d3701a00e39565728fd0a54be018dff12b 158aada056b0fe13708968bf030bccec237db77a41d191ae00e175200bbbb023 994cea3e2b604717025d1deaffc19737e9e8efc50e29cd2767b32634019204df bc31edeb4b754e334ae0ec9d1259ebeb3cf6e13d2b0cd78cf1d7119920838c70 b5d6d1fb55eeb81e41e7df8e4e477ce93b56d7df72fdd7b8b07ecf481d4c1cff 01bbcbe743e24d2e37e4452a72718ed0aad1970a928959e1d3124d9c6d9cfc29 3d705cbe094ddd23143310681cff1e0fea4819ef75c9713032f850e9c57dc8c7 737e422ee2656b67968598c116747188cd4bba624c38d0d9ff1e42709e20e7a6 9cef88d86490a22ed921241deaf0e62642cdfef97d273fec6cd158390e913ec1 a72c5a49be623e42f014b03dabd68f874688a5c2deaebc509b53faec64f36394 b1648b6acd55ace9a6319cb2c04ffab3e6b2ff0ffa8c21f658fb7a394af53d35 b769342fc57710b0f512cdd4a9f39528045361ece0401d31f258433a826fec74 62babe9791a28f6cc43d7bf943886ac3f9661a166191645e3521f57c2f6d09fc 6ab700f8b0406df5b6d7fb14fbfb475bdb6a9c3ab854077a4d12405ed178ac45 0b5aca21e5671ed6a8c7c24e71b8d46da9b57cd4e878aaad667dd12ff6bb63ce e18e98828438b08b4269180325d828d17fdd4f528ebc084adc13046c399251ca e29f5a4bdd9216ba921f1e437a5f8175b04c467ae786ba6d122d3b46051782b8 e242cfa57b59e956717ef562a9a3039389aaa7025f3d190061014f1f7cbfc574 d5067a4f233a5509348c4477c0a681a318e90117062390853fff6c4059e2bff1 d76d4bee86f120e6d63ec400992a114abf0df8baafe641f43c4c91f0919dd202 a7c70f3931bd0c148f91a33cd276fd8ff736927c316e9635b13f9c5719a3f345 863d343ca0fa837b07827aed38b42f22cd7bebe711d4d7b1ce7bfd7d5d2ba1b6 41b8ebb77bd5e80727d106970171454463034c0d1af34631405475f19c952b05 a1eca8799ef43cec6ee519e8794683d1f06f560c509b4015cf1d3a3909ead256 3862f11febf5bbf6759fe7b945453c1d97dca8e013fce3a6c20e0cd908d097e9 e3c9b14e47713a6061b1d57186d6b23affa35e0d8d57421d9fa9bdb82488d691 f0856a03820e7d100525c07e7a88418cde46e086c12cf248d10049c2a5fab27d 3daf2b9a37c09380f508b02f8e1ca1c51f972bd13e4c267955836e1785066f8a 66d936125df700712219aa54c113c208175b25b6c26b9d2af7b385a353703879"
# shader translator rebuilt from source with get_num_samples() as a spec constant (stock NullMoth 1.0.0 build: eba8fee8)
STOCK_XLATE=eba8fee840d953b7c29229541386f710639c8445ecab28a2a559a8b36a1786b3
# 2026-10-11 eb4fb6a3 = 02754ed9 + helpers with a buffer-pointer parameter are emitted after their callers, so the constant byte
# offset the call passes (raw_call_param_offsets) is known: Core Image's _lanczosDownH/V read the sampler transform from byte 0
# instead of 80 and every Lanczos-scaled image (Preview, screenshot thumbnail editor) showed one flat colour per tile
# (patch hidpi/plugin/translator-callers-first.patch, tests hidpi/catest/cikl + cidown). Replaceable: 02754ed9.
OLD_XLATE="eb4fb6a386a809564e8596a7ef91d09e3c6de9244fe587d5aa8a00edb405ddd3 67faee216b6a78974f5b1239a09d9ea04ad4b3a93bca89ef4d53134d33feefb8 761a54b46d834741109599e23f97b0410ae7d2885764ed6cfbbe9cc2383d3ab2 02754ed92b1c529056a0fb26f7fc0d46883ae5b84435d5fc89db107f7ab9119c"
# 2026-10-12 50471f26 = eb4fb6a3 + NullMoth 1.13.0 translator (inlining/OpenCL/integer-simd fixes). Replaceable: eb4fb6a3.
GOOD_XLATE=50471f26cae32538a8761e8d81f62697df54988d5c0c7a532113e145526b53b2
# patched Vulkan driver (bindfix build; ICD loaded by the plugin and by every Metal client). Stock = NullMoth's; the others are earlier patched builds.
STOCK_VK=372c257b551cc0c4591239003151f6ac3cb80a947765b5639acfdb5a80e74ebc   # NullMoth 1.9.0 (1.0.10 stock was bd879ca7)
OLD_VK="bd879ca71229b690a26392fd52d569703febe3dcf9e7b63a8100bd2c872057ec 4d9ceab1c4ae7c752c9b2f8c1eaa6302de70b337aee24cc2270e550137ac0d75 864c2931c3634998ecca4ad2493539f1158b4e9d2a4e88df889c86f2fff99ee6 780adb3f60f163fee7f6eb9a7e09a7e2dd446bbd7169676e96b45397be26a874"
# 1.9.0 Vulkan driver + our three patches re-derived by vk-patched/mk-bindfix-190.py (previous good build: 4d9ceab1 = vk.bindfix.dylib on 1.0.10)
GOOD_VK=d94ea1a395841c3cf1b666ce1f4ffd056751899628c652d19f644c943cbe5d50
mkdir -p $G
chflags -R noschg $G 2>/dev/null || true   # the snapshot is kept immutable between installs
cp $SYS/nvdec-patched/h264.t2d.dylib $G/libnvdec_h264.dylib
cp $SYS/nvenc-patched/h264.final.dylib $G/libnvenc_h264.dylib
[[ $(sha $G/libnvdec_h264.dylib) == 1b5d08ba7cb95804e076d0be30c994bc15121ec4c4345f587dc45e34adffe1bf ]] || { echo "nvdec copy checksum mismatch"; exit 1; }
[[ $(sha $G/libnvenc_h264.dylib) == 2b231d508b2d886afb8de51b950071b905fbd23d88c635bfda968a0855d28231 ]] || { echo "nvenc copy checksum mismatch"; exit 1; }
[[ $(sha $NVS/hidpi/plugin/NVMTLDriver) == $GOOD_PLUGIN ]] || { echo "merged plugin in the project is not the expected build - stop"; exit 1; }
cp $NVS/hidpi/plugin/NVMTLDriver $G/NVMTLDriver; echo "plugin snapshot: merged build ${GOOD_PLUGIN[1,16]}"
[[ $(sha $NVS/hidpi/plugin/libnvmtl_translate.dylib) == $GOOD_XLATE ]] || { echo "translator in the project is not the expected build - stop"; exit 1; }
cp $NVS/hidpi/plugin/libnvmtl_translate.dylib $G/libnvmtl_translate.dylib
[[ $(sha $SYS/vk-patched/vk190.bindfix.dylib) == $GOOD_VK ]] || { echo "patched Vulkan lib in the project is not the expected build - stop"; exit 1; }
cp $SYS/vk-patched/vk190.bindfix.dylib $G/libvulkan_nouveau.dylib
{ echo "libnvdec_h264.dylib ebf782888d4663955f6d7ce04dc158b7b5cfb78f48651450305b3e56abf88d15"
  echo "libnvenc_h264.dylib 164f6dfa409352e90b079659578a012dc37d1fba364067b99cb8c7bf337b1b5d"
  echo "NVMTLDriver $STOCK_PLUGIN $UPSTREAM_RESSET $OLD_GOOD"
  echo "libnvmtl_translate.dylib $STOCK_XLATE $OLD_XLATE"
  echo "nvmtl/libvulkan_nouveau.dylib $STOCK_VK $OLD_VK"; } > $G/files.txt
printf '%s\n' NVMTL_SURF_SHARE_MINPX=3686400 NVMTL_NO_NVENC_HEVC=1 > $G/conf.txt
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
echo "--- bundle now:"; for f in libnvdec_h264.dylib libnvenc_h264.dylib NVMTLDriver libnvmtl_translate.dylib; do echo "  $f $(sha $M/$f | cut -c1-16)"; done
tail -5 /var/log/nvguard.log 2>/dev/null || true
# UU's streamer still has the old encoder loaded: restart UU as the user (never as root).
zsh $SYS/uu-restart.sh >/dev/null 2>&1 && echo "UU restarted" || echo "UU restart failed - run: zsh ~/work/system/uu-restart.sh"
chflags -R schg $G 2>/dev/null && echo "guard snapshot locked (chflags schg; install.sh unlocks it itself)"
echo "guard installed."
