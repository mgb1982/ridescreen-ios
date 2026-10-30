#!/usr/bin/env python3
"""Fail CI when an embedded font, Info.plist or SwiftUI name drifts."""
from __future__ import annotations

import plistlib
import re
from pathlib import Path
from fontTools.ttLib import TTFont

ROOT = Path(__file__).resolve().parents[1]
FONT_DIR = ROOT / "ios" / "RideScreenIOS" / "Fonts"
EXPECTED = {
    "Archivo-Regular.ttf": "Archivo-Regular",
    "Archivo-Medium.ttf": "Archivo-Medium",
    "Archivo-SemiBold.ttf": "Archivo-SemiBold",
    "Archivo-ExtraBold.ttf": "Archivo-ExtraBold",
    "ArchivoBlack-Regular.ttf": "ArchivoBlack-Regular",
}

actual = set()
for filename, expected_name in EXPECTED.items():
    path = FONT_DIR / filename
    if not path.is_file():
        raise SystemExit(f"Missing decoded font: {path}")
    font = TTFont(path, lazy=False)
    names = {
        record.toUnicode()
        for record in font["name"].names
        if record.nameID == 6
    }
    if names != {expected_name}:
        raise SystemExit(f"{filename}: PostScript names {sorted(names)}; expected {expected_name}")
    actual.update(names)
    print(f"OK {filename}: {expected_name}")

if actual != set(EXPECTED.values()) or len(actual) != 5:
    raise SystemExit(f"PostScript names are not five unique expected values: {sorted(actual)}")

with (ROOT / "ios" / "RideScreenIOS" / "Info.plist").open("rb") as handle:
    info = plistlib.load(handle)
registered = set(info.get("UIAppFonts", []))
if registered != set(EXPECTED):
    raise SystemExit(f"UIAppFonts mismatch: {sorted(registered)}")

swift = (ROOT / "ios" / "RideScreenIOS" / "RideScreenIOSApp.swift").read_text(encoding="utf-8")
used = set(re.findall(r'\.custom\("([^"]+)"', swift))
if used != set(EXPECTED.values()):
    raise SystemExit(f"SwiftUI Font.custom names mismatch: {sorted(used)}")

print("All five Archivo PostScript names, UIAppFonts entries and SwiftUI names match.")
