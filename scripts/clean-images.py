#!/usr/bin/env python3
"""Removes metadata from PNG images before they are committed.

macOS screenshots embed EXIF/XMP data and the display's color profile, whose name can identify
the monitor model. This script converts each image to sRGB (with macOS `sips`), then keeps only
the pixel data and a plain sRGB tag.

    python3 scripts/clean-images.py                # clean every tracked PNG
    python3 scripts/clean-images.py --check        # exit 1 if any PNG still has metadata
    python3 scripts/clean-images.py path/to/a.png  # clean specific files
"""
import shutil
import struct
import subprocess
import sys
import zlib

KEEP = {b"IHDR", b"PLTE", b"tRNS", b"IDAT", b"IEND", b"sRGB"}
SRGB_PROFILE = "/System/Library/ColorSync/Profiles/sRGB Profile.icc"


def chunks(data):
    i = 8
    while i < len(data):
        length, = struct.unpack(">I", data[i:i + 4])
        ctype = data[i + 4:i + 8]
        yield ctype, data[i:i + 12 + length]
        i += 12 + length


def chunk(ctype, body):
    return struct.pack(">I", len(body)) + ctype + body + struct.pack(">I", zlib.crc32(ctype + body) & 0xFFFFFFFF)


def has_metadata(path):
    data = open(path, "rb").read()
    return any(ctype not in KEEP for ctype, _ in chunks(data))


def clean(path):
    data = open(path, "rb").read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        return False
    if any(ctype == b"iCCP" for ctype, _ in chunks(data)) and shutil.which("sips"):
        subprocess.run(["sips", "-m", SRGB_PROFILE, path, "--out", path], check=True, capture_output=True)
        data = open(path, "rb").read()
    out = [data[:8]]
    for ctype, raw in chunks(data):
        if ctype in KEEP and ctype != b"sRGB":
            out.append(raw)
        if ctype == b"IHDR":
            out.append(chunk(b"sRGB", b"\x00"))  # perceptual rendering intent
    open(path, "wb").write(b"".join(out))
    return True


def main(args):
    check = "--check" in args
    paths = [a for a in args if not a.startswith("--")]
    if not paths:
        tracked = subprocess.run(["git", "ls-files", "*.png"], capture_output=True, text=True, check=True).stdout
        paths = tracked.split()
    if check:
        dirty = [p for p in paths if has_metadata(p)]
        for p in dirty:
            print(f"metadata found: {p}")
        return 1 if dirty else 0
    for p in paths:
        clean(p)
    print(f"cleaned {len(paths)} image(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
