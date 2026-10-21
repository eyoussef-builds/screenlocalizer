#!/usr/bin/env python3
"""Lists UI strings used in the Swift sources that are missing from a Localizable.strings file.

    python3 -I scripts/check-strings.py            # check ar
    python3 -I scripts/check-strings.py --list     # print every key found
"""
import json
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CALLS = r"(?:\bL|\bLF|\bText|\bButton|\bToggle|\bPicker|\bSection|\bLabel|\bTextField|\bSecureField|\bMenu|\bLink|\bContentUnavailableView|\.help|\.confirmationDialog|\bLabeledContent)"
PATTERN = re.compile(CALLS + r'\(\s*"((?:[^"\\]|\\.)*)"')
# Keys that are brand names, symbols or pure format placeholders.
IGNORE = {"ScreenLocalizer", "•", "English", "العربية"}


def swift_keys():
    keys = set()
    for path in sorted((ROOT / "Sources").rglob("*.swift")):
        text = path.read_text(encoding="utf-8")
        for match in PATTERN.finditer(text):
            raw = match.group(1)
            if "\\(" in raw:
                # SwiftUI turns "\(x)" interpolations into %@ / %lld format keys.
                raw = re.sub(r"\\\(Int\([^)]*\)\)", "%lld", raw)
                raw = re.sub(r"\\\([^)]*\)\)?", "%@", raw)
            key = raw.replace('\\"', '"')
            if key and key not in IGNORE and not re.fullmatch(r"[%@lld·() ]*", key):
                keys.add(key)
    return keys


def strings_keys(lang):
    path = ROOT / "Resources" / f"{lang}.lproj" / "Localizable.strings"
    if not path.exists():
        return {}
    out = subprocess.run(["plutil", "-convert", "json", "-o", "-", str(path)], capture_output=True, text=True, check=True)
    return json.loads(out.stdout)


def main():
    keys = swift_keys()
    if "--list" in sys.argv:
        for key in sorted(keys):
            print(key)
        return 0
    translated = strings_keys("ar")
    missing = sorted(k for k in keys if k not in translated)
    unused = sorted(k for k in translated if k not in keys)
    for key in missing:
        print(f"MISSING  {key}")
    for key in unused:
        print(f"UNUSED   {key}")
    print(f"{len(keys)} keys in code, {len(translated)} in ar, {len(missing)} missing, {len(unused)} unused")
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
