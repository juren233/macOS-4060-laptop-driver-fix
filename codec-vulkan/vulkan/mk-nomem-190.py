# vk190.nomem = vk190.bindfix (d94ea1a3) with our os_get_total_physical_memory rewrite (patch 2 of mk-bindfix-190.py) taken out again:
# the memory size in sandboxed GPU processes now comes from the plugin, as upstream 1.14.5 does it (the plugin points the driver's
# sysconf import at a wrapper that answers _SC_PHYS_PAGES through host_info when sysctl is denied). Patches 1 (/dev/null read-only,
# = upstream NVK e4d8ca8) and 3 (pooled-connection unbind) stay. Needs plugin dbbc77ec or later: an older plugin + this driver has no
# device in Chrome's GPU sandbox ("Failed to query total system memory").
# usage: python3 -I mk-nomem-190.py STOCK_1.9.0.dylib vk190.bindfix.dylib OUT.dylib ; then codesign -f -s - -i vk190.bindfix OUT.dylib
import sys
stock, cur = (open(p, "rb").read() for p in sys.argv[1:3])
d = bytearray(cur)
o, n = 0x406f14 + 0xC0, 76             # patch 2 site in the 1.9.0 layout
assert stock[o-4:o] == cur[o-4:o] and stock[o:o+n] != cur[o:o+n]
d[o:o+n] = stock[o:o+n]
open(sys.argv[3], "wb").write(d)
print("wrote", sys.argv[3])
