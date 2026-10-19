#!/bin/zsh
# NVRM_SRC_HOOK for kext204/build-nvrm.sh: add the source head-scaler (610-head-scaler.patch, applied after upstream's
# two nvkms-kapi.c patches) to the exported kexts/NVRM copy. Cross-check build only; the shipped NVRM is the official
# binary + patch-nvrm-237.py.
set -euo pipefail
SRC=$1; H=${0:A:h}
cp $H/610-head-scaler.patch $SRC/patches/
python3 -I - $SRC/build-completion-archive.py <<'EOF'
import sys
p = sys.argv[1]; s = open(p).read()
old = "['610-display-completion.patch','610-setmode-reason.patch']"
assert s.count(old) == 1, 'nvkms-kapi.c patch list not found'
open(p, 'w').write(s.replace(old, old[:-1] + ",'610-head-scaler.patch']"))
EOF
echo "hook: head-scaler source patch added"
