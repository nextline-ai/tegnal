#!/usr/bin/env python3
"""Update the shared AltStore Classic / SideStore feed from an exported IPA."""

import argparse
import datetime
import json
import pathlib
import plistlib
import subprocess
import tempfile
import zipfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
SOURCE_URL = 'https://nextline-ai.github.io/tegnal/source.json'
ASSETS_URL = 'https://nextline-ai.github.io/tegnal/assets'
BUNDLE_ID = 'work.nextline.tegnal'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('ipa', type=pathlib.Path)
    parser.add_argument('--download-url', required=True)
    parser.add_argument('--date', default=datetime.date.today().isoformat())
    parser.add_argument('--notes', default='TEGNAL for iPhone and iPad.')
    args = parser.parse_args()
    if not args.download_url.startswith('https://'):
        parser.error('--download-url must be HTTPS')
    datetime.datetime.fromisoformat(args.date)

    icon_data = None
    with tempfile.TemporaryDirectory(prefix='tegnal-source-') as directory:
        extracted = pathlib.Path(directory)
        with zipfile.ZipFile(args.ipa) as archive:
            archive.extractall(extracted)
        apps = list((extracted / 'Payload').glob('*.app'))
        if len(apps) != 1:
            parser.error('IPA must contain exactly one app in Payload')
        app = apps[0]
        info = plistlib.loads((app / 'Info.plist').read_bytes())
        if info['CFBundleIdentifier'] != BUNDLE_ID:
            parser.error(f'Expected {BUNDLE_ID}, got {info["CFBundleIdentifier"]}')
        if info.get('CFBundleSupportedPlatforms') != ['iPhoneOS']:
            parser.error('IPA must be a device build')
        entitlements = set()
        privacy = {}
        bundles = [app, *app.rglob('*.appex')]
        for bundle in bundles:
            bundle_info = plistlib.loads((bundle / 'Info.plist').read_bytes())
            for key, value in bundle_info.items():
                if key.startswith('NS') and key.endswith('UsageDescription'):
                    if key in privacy and privacy[key] != value:
                        parser.error(f'Conflicting privacy descriptions for {key}')
                    privacy[key] = value
            if bundle_info.get('CFBundleVersion') != info['CFBundleVersion']:
                parser.error(f'Build number mismatch in {bundle.name}')
            signed = subprocess.run(
                ['codesign', '-d', '--xml', '--entitlements', '-', str(bundle)],
                check=True, capture_output=True,
            )
            entitlements.update(plistlib.loads(signed.stdout).keys())
        entitlements.difference_update({
            'application-identifier', 'com.apple.developer.team-identifier',
        })
        version = {
            'version': info['CFBundleShortVersionString'],
            'buildVersion': info['CFBundleVersion'],
            'date': args.date,
            'localizedDescription': args.notes,
            'downloadURL': args.download_url,
            'size': args.ipa.stat().st_size,
            'minOSVersion': info['MinimumOSVersion'],
        }
        icon_names = info.get('CFBundleIcons~ipad', {}).get('CFBundlePrimaryIcon', {}).get('CFBundleIconFiles', [])
        icons = [p for p in app.glob('*.png') if any(p.name.startswith(n) for n in icon_names)]
        if icons:
            icon = max(icons, key=lambda p: p.stat().st_size)
            # Xcode emits CgBI PNGs; source icons must also decode in web browsers.
            converted = extracted / 'source-icon.png'
            subprocess.run(
                ['xcrun', 'pngcrush', '-q', '-revert-iphone-optimizations',
                 str(icon), str(converted)], check=True, capture_output=True,
            )
            icon_data = converted.read_bytes()

    source_path = ROOT / 'docs/source.json'
    source = json.loads(source_path.read_text()) if source_path.exists() else {
        'name': 'TEGNAL · NextLine',
        'identifier': 'work.nextline.tegnal.source',
        'sourceURL': SOURCE_URL,
        'subtitle': 'Comics. Images. Your collection.',
        'description': 'The official TEGNAL source for AltStore Classic and SideStore.',
        'iconURL': f'{ASSETS_URL}/app-icon.png',
        'website': 'https://nextline-ai.github.io/tegnal/',
        'tintColor': '#737373',
        'apps': [],
        'news': [],
    }
    existing = next((a for a in source['apps'] if a['bundleIdentifier'] == BUNDLE_ID), None)
    app_metadata = existing if existing is not None else {
        'name': 'TEGNAL',
        'bundleIdentifier': BUNDLE_ID,
        'developerName': 'NextLine',
        'subtitle': 'Comics. Images. Your collection.',
        'localizedDescription': 'A native iOS app for discovering comics and illustrations, enjoying them, and building your own collection. Connect your own sites, organize bookmarks and folders, translate text in images, and back up both libraries in one JSON file. Supports Korean, English and Japanese.',
        'iconURL': f'{ASSETS_URL}/app-icon.png',
        'tintColor': '#737373',
        'category': 'entertainment',
        'versions': [],
    }
    versions = app_metadata['versions']
    matching = [v for v in versions if (v['version'], v.get('buildVersion')) == (version['version'], version['buildVersion'])]
    if matching and matching[0] != version:
        parser.error('This version/build is already published with different metadata; increment the build number')
    if not matching:
        versions.insert(0, version)
    app_metadata['appPermissions'] = {'entitlements': sorted(entitlements), 'privacy': privacy}
    if existing is None:
        source['apps'].append(app_metadata)
    source_path.write_text(json.dumps(source, ensure_ascii=False, indent=2) + '\n')
    if icon_data is not None:
        (ROOT / 'docs/assets/app-icon.png').write_bytes(icon_data)
    print(f'Updated {source_path.relative_to(ROOT)}: {version["version"]} ({version["buildVersion"]}), {version["size"]:,} bytes')
    print('Declared entitlements:', ', '.join(sorted(entitlements)))


if __name__ == '__main__':
    main()
