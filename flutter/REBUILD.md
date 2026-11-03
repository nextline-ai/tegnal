# Android app rebuild guide

A guide to hand to the AI in the next session. Read [CLAUDE.md](CLAUDE.md) first: it holds the identity and signing rules that must not change.

## Background

- The earlier Flutter app moved the native iOS app over roughly with another AI and was then patched repeatedly. Its quality fell far short of the native app, so it was deleted in full.
- The old code can still be viewed from GitHub history. Commit `b40a143` is the last one that contains it, viewable with `git show b40a143:flutter/lib/...`. Use it only as a reference for implementation ideas; never copy its structure.
- What remains is only the Android shell needed for Play updates: app ID, signing, version code, app name, icon, splash screens and backup rules. `lib/main.dart` is a placeholder screen.

## Goal

Build an Android app with the same features and quality as the native app (`../native-ios/`). Users should not feel that the iOS app and the Android app are different apps.

## Approach: depends on the layer

### 1. Core logic: port the Swift code almost line by line

Keep the same types, the same rules and the same edge cases. Port the Swift tests (`../native-ios/TEGNALTests/`) to Dart tests too, to show that the same input gives the same result.

| Area | Native source |
| --- | --- |
| Site recognition, lists, works and images | `TEGNAL/Core/Content/`, `TEGNAL/Core/Parser/GalleryIDParser.swift`, `TEGNAL/Core/Network/` |
| Saved works, folders, smart folders, search | `TEGNAL/Core/Storage/` |
| Backup format | `TEGNAL/Core/Storage/LibraryBackup.swift`, `TEGNAL/Core/Booru/BooruBackup.swift` |
| Image mode (booru) | `TEGNAL/Core/Booru/` |
| Taste analysis, recommendations, recap | `TEGNAL/Core/Taste/` |
| Challenges, downloads, imports | `TEGNAL/Core/Challenge/`, `TEGNAL/Core/Downloads/`, `TEGNAL/Core/Migration/` |
| Models | `TEGNAL/Domain/` |

- **Backups:** read and write exactly the same format as the native app, so a library can move between iOS and Android.
- **Sites:** the native app recognizes three site types by page structure alone (indexed, document, keyed). The keyed type includes sign-in, account favorites and keys recovered by searching the number. Keep this recognition approach as it is.

### 2. Platform layer: build it the Android way

Swift code cannot be translated here. The completion criterion is "the same result as the native app."

- **Network blocking:**
  - In Korea some sites are blocked by SNI.
  - Native: when the direct connection fails, it falls back to a hidden WebKit session (`ContentTransport.swift`, `ContentBrowserTransport.swift`).
  - Previous Android app: it used OkHttp with Android 17's ECH (`b40a143:flutter/android/app/src/main/kotlin/work/nextline/tegnal/MangaHttpTransport.kt`).
  - Check both, and verify on a real device.
- **Secure storage:** native uses the keychain; on Android use the Android Keystore (for example `flutter_secure_storage`). Sign-in cookies and API keys must never go into the database, backups or logs.
- **Sync:** native syncs through iCloud; Android uses Google Drive. See `../docs/google-drive-setup.md`.
- **Website sign-in:** native uses a sign-in page in a private WebKit session (`TEGNAL/Presentation/Settings/SiteAccountSettings.swift`). On Android, use a WebView and keep only the identity cookies.
- **Reader translation, downloads and file import/export:** build them with Android equivalents.

### 3. UI: rebuild screen by screen to match the iOS screens

- **Do not translate SwiftUI code line by line.** Match the iOS app's screens, wording and interactions, building them in a way that is natural on Android.
- **Wording:** use `../native-ios/Shared/{en,ko,ja}.lproj/Localizable.strings` as the source, with the same keys and the same wording.
- **Reference screens:** the native UI tests (`../native-ios/TEGNALUITests/`) save screenshots. See `../docs/native-screenshots.md` for capturing screens.

## Order

Replace one area at a time so the app works at every step.

1. Foundation: data model, storage and backup compatibility (load native backup files as-is)
2. Comics explore: site connection, list, search, filters
3. Work details and reader
4. Saved works: folders, smart folders, bookmarks
5. Settings, website accounts, sync
6. Image mode (booru)
7. Taste analysis, recommendations, recap, challenges

For each area, finish in this order: logic tests passing, then screens compared with iOS, then checked on a real device or emulator.

## Release checks

- Increase the version code in `pubspec.yaml` (it must be greater than the latest value in the Play Console).
- Build with `flutter build apk --release` or `flutter build appbundle --release`, and confirm with `apksigner verify --print-certs` that the certificate SHA-256 matches the value in CLAUDE.md.
- Check with `aapt dump badging` that the package is `work.nextline.tegnal`.