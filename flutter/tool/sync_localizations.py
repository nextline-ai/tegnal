#!/usr/bin/env python3
"""Copy the native app's wording into the Flutter app.

Reads native-ios/Shared/{en,ko,ja}.lproj/Localizable.strings, the source of
every string, and writes assets/l10n/{en,ko,ja}.json with the same keys.
Run it whenever the native strings change.
"""
import json
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parents[2]
SOURCE = ROOT / "native-ios" / "Shared"
TARGET = ROOT / "flutter" / "assets" / "l10n"
ESCAPES = {"n": "\n", "t": "\t", "r": "\r", '"': '"', "\\": "\\", "'": "'", "0": "\0"}
ENTRY = re.compile(r'"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;')


def unescape(text: str) -> str:
    def replace(match: re.Match) -> str:
        code = match.group(1)
        if code.startswith("U"):
            return chr(int(code[1:], 16))
        return ESCAPES.get(code, code)

    return re.sub(r"\\(U[0-9A-Fa-f]{4}|.)", replace, text)


def parse(path: pathlib.Path) -> dict:
    text = path.read_text(encoding="utf-8")
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    text = "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("//"))
    return {unescape(key): unescape(value) for key, value in ENTRY.findall(text)}


def main() -> None:
    TARGET.mkdir(parents=True, exist_ok=True)
    for language in ("en", "ko", "ja"):
        table = parse(SOURCE / f"{language}.lproj" / "Localizable.strings")
        output = TARGET / f"{language}.json"
        output.write_text(json.dumps(table, ensure_ascii=False, indent=1, sort_keys=True) + "\n", encoding="utf-8")
        print(f"{output.relative_to(ROOT)}: {len(table)} strings")


if __name__ == "__main__":
    main()
