#!/usr/bin/env python3
"""Merge native localization catalogs with Flutter-only supplemental strings.

Run from any directory:
  python3 flutter/tool/sync_localizations.py
  python3 flutter/tool/sync_localizations.py --check

Native files are read-only. Edit l10n_overrides/{en,ko,ja}.json for Flutter copy.
Supplemental keys must match across languages and preserve formatting tokens.
The source audit recognizes literal L10n.tr/_t calls and common dialog/empty-state
wrappers. Computed keys, user metadata and API errors still need manual review.
"""

from __future__ import annotations

import argparse
from collections import Counter
import json
from pathlib import Path
import re
import sys


FLUTTER = Path(__file__).resolve().parents[1]
REPOSITORY = FLUTTER.parent
LANGUAGES = ("en", "ko", "ja")
STRINGS_PAIR = re.compile(
    r'"((?:\\.|[^"\\])*)"\s*=\s*"((?:\\.|[^"\\])*)"\s*;', re.DOTALL
)
TOKENS = re.compile(
    r'%(?:\d+\$)?[-+0 #]*(?:\d+|\*)?(?:\.(?:\d+|\*))?'
    r'(?:hh|h|ll|l|z|t|j)?[@diuoxXfFeEgGaAcsp]'
    r'|\{[A-Za-z_][A-Za-z_0-9]*\}'
)


def read_json(path: Path) -> dict[str, str]:
    def unique_pairs(pairs: list[tuple[str, str]]) -> dict[str, str]:
        result: dict[str, str] = {}
        for key, value in pairs:
            if key in result:
                raise ValueError(f"Duplicate key in {path}: {key!r}")
            result[key] = value
        return result

    value = json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=unique_pairs)
    if not isinstance(value, dict) or not all(
        isinstance(key, str) and isinstance(text, str) and text.strip()
        for key, text in value.items()
    ):
        raise ValueError(f"Expected a nonempty string-to-string catalog: {path}")
    return value


def native_catalog(language: str) -> dict[str, str]:
    path = REPOSITORY / "native-ios" / "Shared" / f"{language}.lproj" / "Localizable.strings"
    text = path.read_text(encoding="utf-8")
    result: dict[str, str] = {}
    for raw_key, raw_value in STRINGS_PAIR.findall(text):
        key = json.loads(f'"{raw_key}"')
        if key in result:
            raise ValueError(f"Duplicate native key in {path}: {key!r}")
        result[key] = json.loads(f'"{raw_value}"')
    if not result:
        raise ValueError(f"No native translations found: {path}")
    return result


def placeholders(value: str) -> Counter[str]:
    # Native Korean retains two legacy unnumbered %@ translations of numbered
    # English tokens. Preserve these values and validate argument types/counts.
    return Counter(re.sub(r"^%(?:\d+\$)", "%", token)
                   for token in TOKENS.findall(value.replace("%%", "")))


def used_literal_keys() -> set[str]:
    keys: set[str] = set()
    single = r"'((?:\\.|[^'\\])*)'"
    patterns = [
        re.compile(r"L10n\.tr\(\s*[^,]+,\s*" + single),
        re.compile(r"\b_t\(\s*" + single),
        re.compile(r"\b(?:title|message)\s*:\s*" + single),
        re.compile(r"\b(?:showMessage|confirmAction)\(\s*[^,]+,\s*" + single),
    ]
    for path in (FLUTTER / "lib").rglob("*.dart"):
        text = path.read_text(encoding="utf-8")
        for pattern in patterns:
            for match in pattern.finditer(text):
                key = match.group(1)
                if "$" not in key:
                    keys.add(key.replace(r"\'", "'").replace(r"\n", "\n"))
    return keys



def controlled_runtime_keys() -> set[str]:
    """Audit messages surfaced through Drive's configuration/error boundaries.

    These are controlled English literals translated at the UI boundary, not
    remote API text. Include computed conflict descriptions and auth statuses.
    Tokenizing comments separately avoids treating apostrophes in docs as Dart
    string delimiters.
    """
    token = re.compile(r"//[^\n]*|/\*[\s\S]*?\*/|'(?:\\.|[^'\\])*'|\"(?:\\.|[^\"\\])*\"")
    keys: set[str] = set()
    for relative in (
        "data/drive_auth.dart",
        "data/drive_repository.dart",
        "core/drive_sync_controller.dart",
        "features/drive_sync_screen.dart",
    ):
        for match in token.finditer((FLUTTER / "lib" / relative).read_text(encoding="utf-8")):
            value = match.group(0)
            if value[0] not in "\"'":
                continue
            value = value[1:-1].replace(r"\'", "'").replace(r'\"', '"')
            if value and value[0].isupper() and " " in value and "$" not in value:
                keys.add(value)
    return keys

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Validate generated catalogs without writing")
    args = parser.parse_args()
    catalogs: dict[str, dict[str, str]] = {}
    supplements: dict[str, dict[str, str]] = {}
    native: dict[str, dict[str, str]] = {}
    for language in LANGUAGES:
        native[language] = native_catalog(language)
        supplements[language] = read_json(FLUTTER / "tool" / "l10n_overrides" / f"{language}.json")
        catalogs[language] = {**native[language], **supplements[language]}
    for language in LANGUAGES:
        if native[language].keys() != native["en"].keys():
            raise ValueError(f"Native {language} keys differ from English")
        if supplements[language].keys() != supplements["en"].keys():
            raise ValueError(f"Supplemental {language} keys differ from English")
        for key, value in catalogs[language].items():
            if placeholders(key) != placeholders(value):
                raise ValueError(f"Formatting tokens changed in {language}: {key!r}")
        changed_native = [key for key, value in supplements[language].items()
                          if key in native[language] and value != native[language][key]]
        if changed_native:
            raise ValueError(f"Supplement would replace native {language} values: {changed_native}")
    missing = sorted((used_literal_keys() | controlled_runtime_keys()) - catalogs["en"].keys())
    if missing:
        raise ValueError("Missing Flutter literal keys: " + ", ".join(repr(key) for key in missing))
    for language in LANGUAGES:
        target = FLUTTER / "assets" / "l10n" / f"{language}.json"
        output = json.dumps(catalogs[language], ensure_ascii=False, indent=2, sort_keys=True) + "\n"
        if args.check:
            if target.read_text(encoding="utf-8") != output:
                raise ValueError(f"Catalog is out of date: {target}")
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(output, encoding="utf-8")
    print(f"{'Validated' if args.check else 'Generated'} {len(catalogs['en'])} matching keys in en/ko/ja "
          f"({len(native['en'])} unchanged native keys, {len(supplements['en'])} supplemental keys).")
    print("Literal UI keys, controlled Drive runtime messages, and formatting tokens validated. Other computed/runtime keys require manual review.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(error, file=sys.stderr)
        sys.exit(1)
