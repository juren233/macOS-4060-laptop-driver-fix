#!/bin/zsh
# glvsync A/B: installed-equivalent plugin (pbase) vs GL merge (pgl), two rounds, through plugshim
C=${CATEST:-.}; S=${TMPDIR:-/tmp}
cd "$S"
for v in pbase pgl pbase pgl; do
  print -n "$v: "; DYLD_INSERT_LIBRARIES=$C/plugshim.dylib NVMTL_TEST_PLUGIN=$S/$v/NVMTLDriver perl -e 'alarm 30; exec @ARGV' $C/gl236/glvsync 5 2>/dev/null | head -1
done > $S/glvsync-ab.txt 2>&1
echo done >> $S/glvsync-ab.txt
