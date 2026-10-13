#!/bin/zsh
# 用法: sudo zsh nvknob.sh <方案>|reset|show
#   a   关闭"GPU 直接读 IOSurface 内存页"(NVMTL_SURFIN_IMPORT_MB=0)
#   b   a + 关闭异步上传(NVMTL_SURFIN_ASYNC=0)，回到最早的同步上传
#   c   b + 关闭 IOSurface 使用计数(NVMTL_SURF_USECOUNT=0)
#   d   NVMTL_SURF_SHARE_MINPX 调到极大：Chrome 的大窗口表面不再走共享显存
#   e   提交/排序类优化全关(ASYNC_COMMIT,PRESUBMIT_PROLOGUE,EVFOLD,SKIP_EMPTY)
#   f   复用/缓存类优化全关(BUFREUSE,POOL_REUSE,DIRTYONLY,PARFAST,堆纹理复用)
#   reset  删除本脚本加的所有行；show  显示当前文件
# 改完后 ⌘Q 彻底退出 Chrome 再打开即可测 Chrome 一侧（不用重启）；WindowServer 一侧要重启电脑。
CONF=/Library/GPUBundles/nvmtl/nvrm610.conf
B1="# --- claude bisect ---"; B2="# --- end claude bisect ---"
[ "$(id -u)" = 0 ] || [ "$1" = show ] || { echo "需要 sudo"; exit 1; }
strip() { sed -i '' "/$B1/,/$B2/d" $CONF; sed -i '' 's/^NVMTL_SURF_SHARE_MINPX=.*/NVMTL_SURF_SHARE_MINPX=0/' $CONF; }
case "$1" in
  show) cat $CONF ;;
  reset) cp $CONF $CONF.bak-bisect; strip; echo "已还原"; cat $CONF ;;
  a|b|c)
    cp $CONF $CONF.bak-bisect; strip
    { echo "$B1"; echo "NVMTL_SURFIN_IMPORT_MB=0"
      [ "$1" != a ] && echo "NVMTL_SURFIN_ASYNC=0"
      [ "$1" = c ] && echo "NVMTL_SURF_USECOUNT=0"
      echo "$B2"; } >> $CONF
    echo "已应用方案 $1"; cat $CONF ;;
  e)  cp $CONF $CONF.bak-bisect; strip
      { echo "$B1"; echo "NVMTL_ASYNC_COMMIT=0"; echo "NVMTL_PRESUBMIT_PROLOGUE=0"; echo "NVMTL_EVFOLD=0"; echo "NVMTL_SKIP_EMPTY=0"; echo "$B2"; } >> $CONF
      echo "已应用方案 e (提交/排序类优化全关)"; cat $CONF ;;
  f)  cp $CONF $CONF.bak-bisect; strip
      { echo "$B1"; for k in NO_BUFREUSE NO_POOL_REUSE NO_DIRTYONLY NO_PARFAST NO_HEAPTEX_RECYCLE NO_BUFTEX_RECYCLE NO_HEAPTEX_PLACE; do echo "NVMTL_$k=1"; done; echo "$B2"; } >> $CONF
      echo "已应用方案 f (复用/缓存类优化全关)"; cat $CONF ;;
  d)  cp $CONF $CONF.bak-bisect; strip
      sed -i '' 's/^NVMTL_SURF_SHARE_MINPX=.*/NVMTL_SURF_SHARE_MINPX=900000000/' $CONF
      echo "已应用方案 d (所有 IOSurface 都不走共享显存)"; cat $CONF ;;
  *) sed -n 2,12p $0 ;;
esac
