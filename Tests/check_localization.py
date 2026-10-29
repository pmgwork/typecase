#!/usr/bin/env python3
"""Validate all translations, placeholders, and compiler-extracted UI keys.

Usage: python3 Tests/check_localization.py [DerivedData]
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CATALOG = ROOT / "typecase/Localizable.xcstrings"
LANGUAGES = {"en", "ja", "zh-Hans", "zh-Hant", "ko"}
# Product names, font style data, units, and composition-only formats.
VERBATIM = {"TypeCase", "Regular", "A", "—", "%lld", "%lld pt",
            "%@ · %@", "%@ (%@)", "%@–%@"}
TOKEN = re.compile(r"%(?:(\d+)\$)?(lld|@|%)")


def placeholders(text):
    result = {}
    index = 0
    for match in TOKEN.finditer(text):
        position, kind = match.groups()
        if kind == "%":
            continue
        index += 1
        result[int(position) if position else index] = kind
    return result


def units(node):
    if "stringUnit" in node:
        yield node["stringUnit"]
    for variation in node.get("variations", {}).values():
        for child in variation.values():
            yield from units(child)


def main():
    catalog = json.loads(CATALOG.read_text())
    assert catalog["sourceLanguage"] == "en"
    entries = catalog["strings"]
    for key, entry in entries.items():
        assert set(entry["localizations"]) == LANGUAGES, key
        for language, node in entry["localizations"].items():
            translations = list(units(node))
            assert translations, (key, language)
            for unit in translations:
                assert unit["state"] == "translated", (key, language)
                assert unit["value"].strip(), (key, language)
                assert placeholders(unit["value"]) == placeholders(key), (key, language, unit)
    if len(sys.argv) > 1:
        files = list(Path(sys.argv[1]).rglob("*.stringsdata"))
        assert files, "No compiler-extracted strings found; build first."
        for file in files:
            for item in json.loads(file.read_text()).get("tables", {}).get("Localizable", []):
                assert item["key"] in entries or item["key"] in VERBATIM, (file.name, item)
    print(f"PASS: {len(entries)} messages, {len(LANGUAGES)} languages, complete translations and valid placeholders")


if __name__ == "__main__":
    main()
