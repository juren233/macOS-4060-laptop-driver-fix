#!/bin/zsh
# 三种变体各 25 秒，窗口标题写明是哪一种
cd "$(dirname $0)"
run() { env "$@" ./gfxwin.app/Contents/MacOS/gfxwin $MODE 20 $CPU >/dev/null 2>&1; }
MODE=large; CPU=cpu; run A=1                 # 1 CPU 填充 + IOSurfaceCreate
MODE=large; CPU=cpu; run GFXWIN_CV=1         # 2 CPU 填充 + CVPixelBuffer
MODE=large; CPU=gpu; run GFXWIN_CV=1         # 3 GPU 绘制 + CVPixelBuffer
