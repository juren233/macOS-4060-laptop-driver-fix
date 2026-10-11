#!/usr/bin/env python3
# Save the DSDT + SSDTs published by NVDSM (sysctl debug.nvdsm_acpi) as separate .aml files.
import ctypes, struct, sys, os
libc = ctypes.CDLL(None)
name = b"debug.nvdsm_acpi"
size = ctypes.c_size_t(0)
if libc.sysctlbyname(name, None, ctypes.byref(size), None, 0) != 0 or not size.value:
    sys.exit("sysctl debug.nvdsm_acpi unavailable (NVDSM v6 loaded?)")
buf = ctypes.create_string_buffer(size.value)
if libc.sysctlbyname(name, buf, ctypes.byref(size), None, 0) != 0:
    sys.exit("sysctl read failed")
data, out = buf.raw[:size.value], sys.argv[1] if len(sys.argv) > 1 else "acpi"
os.makedirs(out, exist_ok=True)
off, n = 0, {}
while off + 36 <= len(data):
    sig = data[off:off + 4].decode("ascii", "replace"); ln = struct.unpack_from("<I", data, off + 4)[0]
    oem = data[off + 16:off + 24].replace(b"\0", b"").decode("ascii", "replace").strip()
    if ln < 36 or off + ln > len(data): break
    i = n.get(sig, 0); n[sig] = i + 1
    fn = os.path.join(out, f"{sig}-{i}-{oem}.aml".replace(" ", "_"))
    open(fn, "wb").write(data[off:off + ln]); print(fn, ln)
    off += ln
