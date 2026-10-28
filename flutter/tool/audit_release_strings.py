#!/usr/bin/env python3
"""Count specified release strings; no contents, credentials or user data are printed.

This is a limited exact-pattern inventory, not a Play compliance determination.
JSON keys and values are reported separately; binary matches need manual review
because an AOT string can be either compatibility data or user-facing text.
"""
import argparse
import json
import re
import zipfile
from pathlib import PurePosixPath

PATTERNS = {
    'engine_brand_tokens': re.compile(r'(?<![a-z0-9])(?:danbooru|gelbooru|moebooru|safebooru|hitomi)(?![a-z0-9])', re.I),
    'import_brand_tokens': re.compile(r'(?<![a-z0-9_])(?:violet|anime[ -]?boxes)(?![a-z0-9_])', re.I),
    'hardcoded_category_tokens': re.compile(r'(?<![a-z0-9_])(?:doujinshi|non-h)(?![a-z0-9_])', re.I),
    'old_blocked_example_en': re.compile(re.escape('One rule per line. Use tags, rating:explicit, id:123, or artist:name. Remove a rule to unblock content.'), re.I),
    'old_blocked_example_ko': re.compile(re.escape('한 줄에 규칙 하나를 입력하세요. 태그, rating:explicit, id:123, artist:name을 사용할 수 있습니다. 규칙을 지우면 차단이 해제됩니다.')),
    'old_blocked_example_ja': re.compile(re.escape('1行に1つのルールを入力します。タグ、rating:explicit、id:123、artist:nameが使えます。ルールを削除するとブロックが解除されます。')),
    'explicit_rating_token': re.compile(r'(?<![a-z0-9_])rating:explicit(?![a-z0-9_])', re.I),
    'old_safe_mode_advice_en': re.compile(re.escape('Turn off Safe Mode in More to use Comics Mode.'), re.I),
    'old_safe_mode_advice_ko': re.compile(re.escape('만화 모드를 사용하려면 더보기에서 세이프 모드를 꺼주세요.')),
    'old_safe_mode_advice_ja': re.compile(re.escape('コミックモードを使うには「その他」でセーフモードをオフにしてください。')),
}


def counts(text):
    return {name: len(matches) for name, pattern in PATTERNS.items()
            if (matches := pattern.findall(text))}


def report(section, path, found):
    for name, count in found.items():
        print(f'{section}\t{name}\t{count}\t{path}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive', help='APK or AAB to inspect')
    args = parser.parse_args()
    with zipfile.ZipFile(args.archive) as archive:
        for info in archive.infolist():
            name = info.filename
            path = PurePosixPath(name)
            if '/assets/l10n/' in name and path.suffix == '.json':
                try:
                    obj = json.loads(archive.read(info))
                    if not isinstance(obj, dict):
                        raise ValueError('expected localization object')
                except (ValueError, UnicodeError) as error:
                    raise SystemExit(f'Invalid localization JSON: {name}: {type(error).__name__}')
                report('json_keys', name, counts('\n'.join(str(k) for k in obj)))
                report('json_values', name, counts('\n'.join(v for v in obj.values() if isinstance(v, str))))
            elif '/assets/' in name and path.suffix == '.json':
                report('asset_json', name, counts(archive.read(info).decode('utf-8', errors='replace')))
            elif (path.name == 'libapp.so' or path.suffix == '.dex'
                  or path.name in ('resources.arsc', 'resources.pb')):
                data = archive.read(info)
                report('binary_utf8', name, counts(data.decode('utf-8', errors='replace')))
                # UTF-16LE strings can begin at odd byte offsets in binaries.
                for offset in (0, 1):
                    if len(data) > offset:
                        report(f'binary_utf16le_{offset}', name,
                               counts(data[offset:].decode('utf-16le', errors='replace')))
    print('NOTE: exact patterns only; binary matches require contextual review; this is not a policy assessment.')


if __name__ == '__main__':
    main()
