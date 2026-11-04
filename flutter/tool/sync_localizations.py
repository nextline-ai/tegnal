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


# Wording iOS supplies itself (PasteButton, ContentUnavailableView.search), which the
# native strings files do not hold. Keys are the English system wording.
SYSTEM = {
    "Paste": {"en": "Paste", "ko": "붙여넣기", "ja": "ペースト"},
    "No Results": {"en": "No Results", "ko": "결과 없음", "ja": "結果なし"},
    "No Results for “%@”": {"en": "No Results for “%@”", "ko": "‘%@’에 대한 결과 없음", "ja": "“%@”の結果なし"},
    "Check the spelling or try a new search.": {
        "en": "Check the spelling or try a new search.",
        "ko": "철자를 확인하거나 새로운 검색을 시도하십시오.",
        "ja": "スペルを確認するか、新しい検索を試してください。",
    },
}

# Android-only wording, where the native app names an Apple service (iCloud) that the
# Android app replaces with Google Drive. The rest of the sync wording is native.
ANDROID = {
    "Challenge definitions, progress and image sources stay on this device.": {
        "en": "Challenge definitions, progress and image sources stay on this device.",
        "ko": "챌린지 정의, 진행 상태와 이미지 출처는 이 기기에 저장됩니다.",
        "ja": "チャレンジの定義、進行状況、画像の出典はこのデバイスに保存されます。",
    },
    "This removes the challenge and its progress from this device.": {
        "en": "This removes the challenge and its progress from this device.",
        "ko": "이 기기에서 챌린지와 진행 상태를 삭제합니다.",
        "ja": "このデバイスからチャレンジと進行状況を削除します。",
    },
    "Google Drive": {"en": "Google Drive", "ko": "Google 드라이브", "ja": "Google ドライブ"},
    "Google Drive Sync": {"en": "Google Drive Sync", "ko": "Google 드라이브 동기화", "ja": "Google ドライブ同期"},
    "Connect Google Account": {"en": "Connect Google Account", "ko": "Google 계정 연결", "ja": "Google アカウントを接続"},
    "Disconnect Google Account": {"en": "Disconnect Google Account", "ko": "Google 계정 연결 해제", "ja": "Google アカウントの接続を解除"},
    "Google Account": {"en": "Google Account", "ko": "Google 계정", "ja": "Google アカウント"},
    "Google Drive backup is coming soon. For now, back up manually to a local file in Library Management.": {
        "en": "Google Drive backup is coming soon. For now, back up manually to a local file in Library Management.",
        "ko": "Google 드라이브 백업은 준비 중입니다. 지금은 라이브러리 관리에서 로컬 파일로 직접 백업하세요.",
        "ja": "Google ドライブのバックアップは準備中です。現在はライブラリ管理からローカルファイルに手動でバックアップしてください。",
    },
    "Sign in to Google to sync.": {
        "en": "Sign in to Google to sync.",
        "ko": "동기화하려면 Google에 로그인하세요.",
        "ja": "同期するには Google にサインインしてください。",
    },
    "Waiting for Google Drive": {"en": "Waiting for Google Drive", "ko": "Google 드라이브를 기다리는 중", "ja": "Google ドライブを待っています"},
    "Google Drive Sync On": {"en": "Google Drive Sync On", "ko": "Google 드라이브 동기화 켜짐", "ja": "Google ドライブ同期オン"},
    "Some Google Drive files could not be read. Other changes were merged. Try syncing again.": {
        "en": "Some Google Drive files could not be read. Other changes were merged. Try syncing again.",
        "ko": "일부 Google 드라이브 파일을 읽지 못했습니다. 나머지 변경 사항은 병합되었습니다. 다시 동기화해 보세요.",
        "ja": "一部の Google ドライブのファイルを読み込めませんでした。ほかの変更は統合されました。もう一度同期してください。",
    },
    "Google Drive Sync Documents": {"en": "Google Drive Sync Documents", "ko": "Google 드라이브 동기화 문서", "ja": "Google ドライブ同期書類"},
    "Keeps both libraries, folders and general settings in sync across your Android devices through a TEGNAL folder in your Google Drive. Layout, viewer preferences, downloaded media and sign-in details stay on each device.": {
        "en": "Keeps both libraries, folders and general settings in sync across your Android devices through a TEGNAL folder in your Google Drive. Layout, viewer preferences, downloaded media and sign-in details stay on each device.",
        "ko": "Google 드라이브의 TEGNAL 폴더를 통해 Android 기기 사이에서 두 라이브러리, 폴더, 일반 설정을 동기화합니다. 레이아웃, 뷰어 설정, 다운로드한 미디어, 로그인 정보는 각 기기에만 남습니다.",
        "ja": "Google ドライブの TEGNAL フォルダを通じて、Android デバイス間で両方のライブラリ、フォルダ、一般設定を同期します。レイアウト、ビューアの設定、ダウンロードしたメディア、サインイン情報は各デバイスに残ります。",
    },
    "Turn Off Google Drive Sync?": {"en": "Turn Off Google Drive Sync?", "ko": "Google 드라이브 동기화를 끌까요?", "ja": "Google ドライブ同期をオフにしますか？"},
    "Changes on this device will stop syncing. Existing data on this device and in Google Drive will be kept. Turning sync on again will merge changes.": {
        "en": "Changes on this device will stop syncing. Existing data on this device and in Google Drive will be kept. Turning sync on again will merge changes.",
        "ko": "이 기기의 변경 사항이 더 이상 동기화되지 않습니다. 이 기기와 Google 드라이브에 있는 기존 데이터는 유지됩니다. 동기화를 다시 켜면 변경 사항이 병합됩니다.",
        "ja": "このデバイスの変更は同期されなくなります。このデバイスと Google ドライブにある既存のデータは保持されます。同期を再びオンにすると変更が統合されます。",
    },
    "Unable to connect Google Account: %@": {
        "en": "Unable to connect Google Account: %@",
        "ko": "Google 계정을 연결할 수 없습니다: %@",
        "ja": "Google アカウントを接続できません: %@",
    },
}


def main() -> None:
    TARGET.mkdir(parents=True, exist_ok=True)
    for language in ("en", "ko", "ja"):
        table = parse(SOURCE / f"{language}.lproj" / "Localizable.strings")
        for key, values in {**SYSTEM, **ANDROID}.items():
            table.setdefault(key, values[language])
        output = TARGET / f"{language}.json"
        output.write_text(json.dumps(table, ensure_ascii=False, indent=1, sort_keys=True) + "\n", encoding="utf-8")
        print(f"{output.relative_to(ROOT)}: {len(table)} strings")


if __name__ == "__main__":
    main()
