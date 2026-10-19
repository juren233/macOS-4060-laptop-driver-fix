#!/usr/bin/env python3
"""Check the x86_64 bluetoothd/BlueTool patch sites used by BTLEFix v6."""

import argparse
import pathlib
import struct
import sys

FAT_MAGIC = 0xCAFEBABE
MH_MAGIC_64 = 0xFEEDFACF
CPU_TYPE_X86_64 = 0x01000007
LC_SEGMENT_64 = 0x19
LC_UUID = 0x1B


def be32(data, off):
    return struct.unpack_from(">I", data, off)[0]


def le32(data, off):
    return struct.unpack_from("<I", data, off)[0]


def le64(data, off):
    return struct.unpack_from("<Q", data, off)[0]


class Rule:
    def __init__(self, name, original, patched, expected, patched_prefix=False):
        self.name = name
        self.original = original
        self.patched = patched
        self.expected = expected
        self.patched_prefix = patched_prefix


RULES = {
    "bluetoothd": [
        Rule("vendor", bytes.fromhex("81fa5c0a000074"), bytes.fromhex("81fa5c0a0000eb"), 1),
        Rule("chipset", bytes.fromhex("81f9cf07000072"), bytes.fromhex("81f9cf070000eb"), 3),
        Rule(
            "chipset15.4",
            bytes.fromhex("81f96f1700007730"),
            bytes.fromhex("8d4fff b865000000").replace(b" ", b"") + b"\x90" * 8,
            1,
        ),
        Rule(
            "le-v2",
            bytes.fromhex("41807e6901751541807e2710731e"),
            bytes.fromhex("41807e6901751541807e27109090"),
            1,
        ),
        Rule("board-id", b"Mac-F60DEB81FF30ACF6\0", b"Mac-7BA5B2D9E42DDD94\0", 1),
    ],
    "BlueTool": [
        Rule(
            "automatic-update-path",
            b"/etc/bluetool/SkipBluetoothAutomaticFirmwareUpdate\0",
            b"/System/Library/CoreServices/boot.efi",
            1,
            patched_prefix=True,
        ),
        Rule("board-id", b"Mac-F60DEB81FF30ACF6\0", b"Mac-7BA5B2D9E42DDD94\0", 1),
    ],
}


def x86_64_slice(data):
    if be32(data, 0) != FAT_MAGIC:
        if le32(data, 0) != MH_MAGIC_64:
            raise ValueError("not a Mach-O file")
        return data, 0
    count = be32(data, 4)
    for index in range(count):
        off = 8 + index * 20
        cputype, _, slice_off, size, _ = struct.unpack_from(">IIIII", data, off)
        if cputype == CPU_TYPE_X86_64:
            return data[slice_off : slice_off + size], slice_off
    raise ValueError("no x86_64 slice")


def mach_info(thin):
    if le32(thin, 0) != MH_MAGIC_64:
        raise ValueError("invalid 64-bit Mach-O header")
    cputype = le32(thin, 4)
    ncmds = le32(thin, 16)
    sizeofcmds = le32(thin, 20)
    if cputype != CPU_TYPE_X86_64:
        raise ValueError("x86_64 slice has the wrong cputype")

    pos = 32
    text = None
    ident = None
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", thin, pos)
        if size < 8 or pos + size > 32 + sizeofcmds:
            raise ValueError("invalid load command")
        if cmd == LC_SEGMENT_64 and size >= 72:
            name = thin[pos + 8 : pos + 24].split(b"\0", 1)[0]
            vmaddr = le64(thin, pos + 24)
            fileoff = le64(thin, pos + 40)
            filesize = le64(thin, pos + 48)
            if name == b"__TEXT":
                text = (vmaddr, fileoff, filesize)
        elif cmd == LC_UUID and size >= 24:
            ident = thin[pos + 8 : pos + 24]
        pos += size
    if text is None or ident is None:
        raise ValueError("missing __TEXT or LC_UUID")
    return text, ident


def find_all(haystack, needle):
    found = []
    pos = 0
    while True:
        pos = haystack.find(needle, pos)
        if pos < 0:
            return found
        found.append(pos)
        pos += 1


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("path", nargs="?", default="/usr/sbin/bluetoothd")
    parser.add_argument("--expect-pristine", action="store_true", help="fail if file/UBC pages are already patched")
    args = parser.parse_args()
    path = pathlib.Path(args.path)
    data = path.read_bytes()
    thin, slice_off = x86_64_slice(data)
    (text_vmaddr, text_fileoff, text_filesize), ident = mach_info(thin)
    text = thin[text_fileoff : text_fileoff + text_filesize]
    name = "BlueTool" if path.name == "BlueTool" else "bluetoothd"

    print(f"file: {path}")
    print(f"x86_64 slice: file offset {slice_off:#x}, size {len(thin):#x}")
    print(
        f"__TEXT: vmaddr {text_vmaddr:#x}, file offset {text_fileoff:#x}, "
        f"size {text_filesize:#x}"
    )
    print(f"UUID: {ident.hex()}")

    failed = False
    saw_patched = False
    for rule in RULES[name]:
        original_hits = find_all(text, rule.original)
        patched_hits = find_all(text, rule.patched)
        if len(original_hits) == rule.expected:
            state = "pristine"
        elif len(patched_hits) >= rule.expected:
            state = "patched"
        else:
            state = "mismatch"
        saw_patched = saw_patched or state == "patched"
        print(
            f"{rule.name:23} original={len(original_hits)} patched={len(patched_hits)} "
            f"expected={rule.expected} [{state}]"
        )
        for off in original_hits + patched_hits:
            file_off = slice_off + text_fileoff + off
            print(f"  text {off:#x}  file {file_off:#x}  16K block {file_off // 16384 * 16384:#x}")
        if state == "mismatch":
            failed = True
        if args.expect_pristine and state != "pristine":
            failed = True

    if saw_patched:
        print("note: patched forms are present; UBC may still contain the old in-place edits")
    return 1 if failed else 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        raise SystemExit(2)
