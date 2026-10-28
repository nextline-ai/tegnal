# TEGNAL Flutter

> **Android beta:** [Download the signed APK](https://github.com/nextline-ai/tegnal/releases/tag/android-v1.0.0-beta.1). Version `1.0.0-beta.1+3` bundles Hitomi and Danbooru connections through an explicit one-time user-database bootstrap. Saved connections survive removal of the bootstrap code; existing/deleted connections and user selection are respected. Image favorites use persistent site folders matching the native app. Google Drive synchronization is temporarily disabled; translation hands off to the installed Google Translate app.


Android-first port of TEGNAL, with Windows and Linux runners. This is an implementation in progress, not a claim of complete native parity. The native Apple application remains the behavioral reference. See the [delivery roadmap](../docs/flutter-roadmap.md) for current implementation, validation gates and remaining work, and [the parity contract](../docs/flutter-parity.md) for the full native behavior matrix.

## Implemented in source

- Independent Comics/Image libraries and preferences in local SQLite; mode switching, five destinations, narrow-screen tabs and a wide-screen sidebar.
- Folder mosaic/list layouts, folder names/colors/order, saved-work search, notes and memberships, plus source-scoped artist/group/tag bookmarks.
- Connected-site browsing: indexed and document manga catalogs, namespaced/keyword searches, cursor/range pagination, gallery manifests, and Danbooru/Gelbooru/legacy Gelbooru/Moebooru adapters. Supported public Danbooru/Moebooru pools and image notes have separate adapters and UI.
- Detail/save/search flows; horizontal, vertical and continuous comic reading; progress, RTL, pinch/double-tap zoom, keyboard navigation, image notes, video controls and reader preferences.
- Persisted foreground download queue with pause/resume/retry/remove, page-file verification, saved manifests and completed offline opening. Backgrounding pauses work; it does not promise an Android background-download service.
- Native-compatible metadata backups and selected-file legacy imports; weighted Challenge definitions, editors, deadline/count goals, score bands/endings, local sessions and source/folder reference selection.
- Deterministic saved-metadata analysis and collection-based discovery/ranking, with source-scoped exclusions and saved-date recaps. These do not establish equivalence with the native activity-event recommendation/report engine.
- Native English/Korean/Japanese catalogs with Flutter supplements. Theme/language choices and an optional blur/tint chrome adapter are wired into the app.
- An Android WebView/cookie bridge and source-scoped request transport. Desktop opens an external browser; external browser sessions are not imported.

On Android, manga GET requests first use the bounded OkHttp transport. Only a
connection-level failure for a URL already allowed by that configured manga
source may retry with pinned `ech_http` 0.2.3. That retry makes a DNS-over-HTTPS
HTTPS-record lookup for the exact destination hostname through Cloudflare DNS;
when the hostname has an ECH route, the TLS connection fails closed unless ECH
is accepted. Aborts, HTTP responses and certificate-validation failures never
trigger a second TLS attempt. The ECH client uses its own bundled Mozilla CA
roots, which differ from Android's platform trust store. This transport does
not download AI models or route through a proxy.

These statements describe the implementation in this workspace. They do not establish live-server compatibility, successful platform builds, device behavior, full reader parity or release readiness.

## Material interface and typography

All application widgets use the official `material_ui` **1.8.0** package. The
Material 3 theme enables `StyleVariant.material3Expressive` for the supported
Expressive components, with native Material icons, switches, selection controls,
dialogs, sliders, fields and buttons. The collection layout remains image-led:
colorful folder mosaics, compact mode controls, floating destinations, and a
wide-screen sidebar with Ctrl+1–5 navigation. Application source no longer
imports Cupertino. The official Material package itself has a transitive
Cupertino dependency; it is not an application UI dependency.

Pretendard **1.3.9** and Pretendard JP fallback are bundled for offline use with
their OFL license. The same family applies to screens, dialogs, menus, reader
controls and startup errors. The floating dock always uses bounded translucency
(high contrast may use an opaque surface); there is no experimental toggle.

For populated comparisons without editing an installed library, see
[the capture harness](tool/ui_capture.md). PNGs in `build/ui-captures/` include
Korean mobile dark/light, desktop, enlarged text and Google Drive setup screens.
The always-on `shell_reactivity_test.dart` covers retained routes updating
switches and asynchronous search results. These checks do not establish full
native parity or Windows/Linux binary compatibility.

## Google Drive synchronization

See [Google Cloud and OAuth setup](../docs/google-drive-setup.md). Android uses
the official Google Sign-In plugin; Windows/Linux use system-browser PKCE and
OS secure credential storage. This repository contains no OAuth client IDs, so
an unconfigured build displays setup guidance. Live account connection and a
real two-device Drive round trip still require your Google project.

Drive stores immutable, complete native-compatible JSON revisions in its own
visible TEGNAL folder using only `drive.file` access. Foreground automatic sync
is optional and off by default. Unchanged local data can receive an updated
Drive copy, including deletions. Divergent changes and concurrent revision
branches pause for an explicit whole-library choice: device, selected Drive
copy, or combine (Drive values win duplicate metadata). Account switches turn
automatic sync off and require fresh review. Prior Drive revisions remain;
ten local recovery copies protect local replacements and can be restored in
Settings. Recovery restoration also disables automatic sync.

Import an iPhone export in Library Management, then sync it. A JSON revision
downloaded from Drive can be imported back into the existing iPhone app. This
does not add Google sign-in to native iOS. Metadata transfer excludes media,
download files, reading progress and credentials. Manga source configuration
and Booru memos omitted by the native envelope remain local. The ordinary JSON
import remains a merge; exact replacement is specific to accepted sync copies.

## Build a preview

The current SDK baseline is Flutter **3.47.8** / Dart **3.13.7**. Run commands from `flutter/`; keep `pubspec.lock` when reproducing a build. Resolve packages once:

```sh
flutter pub get
```

### Android first

Install the Android SDK/toolchain and a compatible JDK. The generated Gradle 9.3.1 / AGP 9.1 configuration supports JDK 17 according to the [official compatibility table](https://developer.android.com/build/releases/agp-9-1-0-release-notes); the first local build used Java 25. An ARM64 debug APK can be built without launching a device:

```sh
flutter build apk --debug --target-platform android-arm64 --split-per-abi
```

Output: `build/app/outputs/flutter-apk/app-arm64-v8a-debug.apk`. An explicit local device run is a separate check:

```sh
flutter run -d <existing-device-id>
```

The Android release configuration still needs production signing and distribution review. A debug APK or a successful compile is not evidence of a working save/read/download/login workflow.

### Windows

Build on Windows with Visual Studio's **Desktop development with C++** workload and Windows SDK installed:

```powershell
flutter config --enable-windows-desktop
flutter pub get
flutter build windows --release
```

Distribute the complete `build/windows/x64/runner/Release/` directory, including its DLLs and `data/`, rather than the executable alone. Installer packaging, signing and clean-machine runtime behavior remain unverified.

### Linux

Build on Linux. For an Ubuntu/Debian development host, the current Flutter and `media_kit` integration needs GTK, compiler/CMake tooling and libmpv/epoxy development libraries:

```sh
sudo apt-get update
sudo apt-get install -y clang cmake ninja-build pkg-config libgtk-3-dev libstdc++-12-dev liblzma-dev libmpv-dev libepoxy-dev libsecret-1-dev mpv
flutter config --enable-linux-desktop
flutter pub get
flutter build linux --release
```

The media dependency follows the installed [`media_kit` Linux setup](https://github.com/media-kit/media-kit#gnulinux). Run/distribute the complete `build/linux/x64/release/bundle/`. libmpv and its codec dependencies remain system dependencies. The bundle includes a desktop entry and icon under `data/`; registering a launcher requires installing that metadata and making `tegnal` resolvable from the launcher's `Exec` path. No AppImage, Flatpak or distribution package has been validated.

### Manual CI

[Flutter platform build](../.github/workflows/flutter-platform-builds.yml) is manually dispatched and builds **one selected target**: Android debug APK, Windows release ZIP or Linux release tarball. It has no push/PR/scheduled trigger, test matrix, deployment or signing secrets. It has not been remotely dispatched as part of this change. An uploaded bundle, if a maintainer later runs it successfully, is build evidence only.

## Assets and localization

All platform icons use the supplied 1920×1920 [`symbol.jpg`](../design-output/JPG/symbol.jpg), which matches the stacked wordmark in the native app icon; the wide `logotype.jpg` is not used as a square icon. `python3 tool/sync_app_icons.py` creates the 1024px Flutter branding PNG, Android density and adaptive-icon assets, a multi-size Windows ICO, and the Linux PNG with macOS's built-in `sips`. The conversion resizes the existing artwork without redrawing it; generated assets are checked in, so platform builds need no image-generation service or image library.

```sh
python3 tool/sync_localizations.py
python3 tool/sync_localizations.py --check
```

The script reads `native-ios/Shared/*/Localizable.strings` without changing native files, merges `tool/l10n_overrides/{en,ko,ja}.json`, and checks equal keys, native-value preservation, placeholder types/counts and literal Flutter UI-key coverage. Dynamic metadata, user-authored text, built-in Challenge content and raw runtime errors still require language-specific review where they bypass `L10n`.

## Metadata backup

`BackupCodec(LibraryStore)` provides `inspect(text)`, `importJson(text)`, and `exportJson()`. The codec supports native combined `tegnal-library` v1, comics v1/v2, standalone image v1, standalone challenges v1, and historical image/challenge format names on import.

Imports validate all sections before mutation and merge within one SQLite transaction. Repeated imports preserve existing unrelated records. Canonical server remapping preserves composite image identities, and comics retain global gallery IDs. Export includes all search history, independently of the UI's display limit, and preserves native timestamp units and portable extension metadata.

Backups contain library metadata, not an offline-media archive. Credentials, browser cookies, raw API responses, device preferences, local media paths, download files, full Taste activity history, and local challenge sessions are excluded. Imported remote URLs are still remote URLs; opening them can require reconnecting to the original website.

## Legacy imports

`LegacyImport(LibraryStore)` reads only a file the user explicitly chooses. `inspectFile(path)` previews the counts without changing the library; `importFile(path)` commits the selected import. Both return `LegacyImportSummary`, which extends `BackupSummary` with artist/catalog/match, duplicate, skipped-record, and added-server counts.

- Other Manga Viewer `user.db`: bookmarks, ordered/colored folders, default-folder normalization, multiple memberships and favorite artists/groups. Source databases open read-only. SQL values use bound parameters; discovered table identifiers are quoted.
- Other Manga Viewer `data.db`: default behavior matches metadata only to saved comics. `importFile(path, fullCatalog: true)` explicitly stores the entire catalog without bookmarking extra works. Both modes decode piped metadata, native HTML escapes and .NET publication ticks. Previously stored catalog metadata can fill a later bookmark import. Manual metadata remains protected when marked as manual.
- Anime Boxes `.abbj` version 1.0, up to 64 MiB: supported servers, favorites, search history/starred searches, banned-tag rules and selected servers. Unsupported server types/records are counted as skipped. Duplicate favorites keep their existing folder and saved date. Server accounts/API credentials are excluded. Default organization is one folder per site, matching the native import default.

For callers that already have Anime Boxes JSON, `inspectAnimeBoxes(text)` and `importAnimeBoxes(text)` are synchronous alternatives. The current importer uses the native defaults for history, blacklist, selection and site-based folders; alternate destination-folder and import-toggle controls are not exposed yet.

Catalog staging reads in bounded batches into a temporary on-disk SQLite database and yields between batches. Callers can supply `isCancelled` and `onProgress`; cancellation before completion leaves the library unchanged. Final destination writes form one synchronous atomic transaction. Large final commits may temporarily occupy the UI isolate; background-isolate integration and end-to-end progress/cancel UI still require platform validation.

Sources: [`MangaViewerImportService.swift`](../native-ios/TEGNAL/Core/Migration/MangaViewerImportService.swift), [`AnimeBoxesImport.swift`](../native-ios/TEGNAL/Core/Booru/AnimeBoxesImport.swift), and [`LibraryBackup.swift`](../native-ios/TEGNAL/Core/Storage/LibraryBackup.swift).

## Platform limits

Native translation/OCR uses Apple Vision, VisionKit and Translation. Native art-style similarity uses revision-specific archived Vision feature prints. Those APIs and fingerprints are not portable. Android integrations may use only installed and available system services; the port must not download or install external models. Smart statistics and recommendation ranking are deterministic and do not require AI.

Native live synchronization uses app-entitled iCloud Drive documents. iCloud synchronization remains available only in the native Apple application; portable JSON transfer does not implement live synchronization. Google Drive metadata sync is implemented separately with OAuth setup above. Android browser/file bridge code is present, but website verification/login, sharing grants and cookie reset/isolation need device validation. Desktop browser accounts are not integrated.

Web is unsupported by the current `dart:io`, native SQLite, filesystem/media and platform-channel architecture. The generated `web/` template is not a supported app target.

The floating dock uses clipped blur/tint independently of reduced motion. Reader controls remain opaque. The former translucency preference is no longer read.

Known functional gaps include native event-based recommendations/reports and analysis controls, metadata/cover backfill queue, the complete per-mode artwork/reader preference matrix, multi-page spreads and thumbnail/jump/gesture surfaces, saved-search controls, import-option/progress/cancel UI, platform share intake, and installed-system OCR/translation/similarity adapters. Manga reader URL selection currently uses WebP without the native image retry/AVIF fallback. Challenge advanced fields are available through JSON editing; native subeditors/reel animation are not reproduced. Check the roadmap before marking a native feature complete.

## Validation status

As of 2026-10-26, focused offline source/engine/storage/import/backup/transport/download fixtures exist and selected checks have passed during implementation. Manga source fixtures passed nine tests; Challenge engine/repository fixtures passed eight, with two affected backup checks rerun after the final core change. Scope-specific results do not validate the whole app.

Final validation on 2026-10-26: `flutter analyze` passed with no issues; the final navigation-only adjustment also passed scoped analysis. `flutter build apk --debug --target-platform android-arm64 --split-per-abi --no-pub` produced `build/app/outputs/flutter-apk/app-arm64-v8a-debug.apk`. APK inspection confirmed `work.nextline.tegnal`, version 0.1.0, Android API 24 minimum, and ARM64-only native code. This is a debug preview, not a signed production release.

Focused checks covered the source adapters, pools/notes, SQLite/controller races, backup/import, browser transport, download lifecycle/refresh, challenges and deterministic insights. The 2026-10-27 Material/Drive pass added focused library/search, reader, switch, screenshot/navigation, OAuth, Drive HTTP, conflict/recovery and native snapshot checks. Scoped analysis and the rebuilt Android ARM64 debug APK passed. Localization validation now covers 1,255 matching keys in English/Korean/Japanese. The existing Pixel_10_Pro Android emulator received an in-place install and selected UI checks; no app data was cleared. Populated screenshot fixtures use an isolated memory database. No full native suite, device matrix or live-site validation was run. Windows/Linux binary builds and clean-machine desktop launch remain unverified.

## Focused verification

Follow `AGENTS.md`; [native testing guidance](../docs/testing.md) applies to the Apple app. Flutter changes use focused checks such as the examples below and the optional [UI capture harness](tool/ui_capture.md).

```sh
flutter test test/core/legacy_import_test.dart
flutter test test/core/backup_codec_test.dart --plain-name 'exports all history entries without the UI display limit'
```

Importer tests use only synthetic SQLite/JSON fixtures. They cover immutable read-only sources, aliases, memberships, metadata conversion, manual-field protection, full-vs-targeted catalog import, cancellation, rollback, Anime Boxes mappings and duplicate handling. The backup codec has separate fixture coverage for compatibility, timestamps, canonical remapping and atomic failures. These checks do not verify live websites, device integrations or the entire app.


## Android connection and privacy fixes (2026-10-27)

Manga and Booru catalog requests, Booru extras, and network images share
OkHttp 5.5.0 with AndroidDns/ECH on Android 17.
On a generic connection failure, the app may retry through pinned `ech_http`
0.2.3 (libcurl/BoringSSL), which also works independently of platform ECH.
Only HTTPS GET requests to the configured or discovered source/data/CDN hosts
qualify. No retry is made for certificate rejection, cancellation or an HTTP
error response. The retry obtains HTTPS DNS records from Cloudflare DoH; only
those hostnames are sent for DNS resolution. Cookies remain URL/source scoped.
ECH must be accepted, and the fallback validates certificates against its bundled
Mozilla roots (the primary uses Android roots). Responses, concurrency, host
caches and cancellation are bounded. This young dependency remains experimental;
its native build hook downloads pinned, checksum-verified dependency SDKs, not
AI models. Windows/Linux runtime behavior has not been validated.

Build requires Android SDK 37 and AGP 9.1.1; minimum Android API stays 24.
Android WebView connection failures stay inside the app with Retry/Back/Close.
Automatic external-browser recovery and its button have been removed. Desktop
platforms still open their configured external browser.

If a site also requires a VPN or HTTPS bypass app in Chrome, the application
transport cannot guarantee access without that network assistance. In this
environment Danbooru and Gelbooru reset during TLS, and no ECH DNS records were
published for these hosts at verification time. The app reports a connection
failure with conditional network guidance instead of claiming API/auth failure.

The branded cover matches the native resume presentation. Android can snapshot
before pause callbacks, so API 33+ Recents previews are disabled and use an opaque
system/task background, not the brand artwork. On older Android, secure windows
also disable screenshots and recording. Normal foreground screenshots remain
available on API 33+. See [focused validation](../docs/flutter-ux-validation.md)
for actual checks and limitations.


## Image and keyboard refinements (2026-10-27)

Root navigation creates tabs on first visit and retains their state. Hidden tabs
and content behind root modals do not reflow for each keyboard inset frame; the
outer shell no longer resizes a second time. Android focus loss alone does not
trigger the privacy artwork; actual pause/background protection remains.

Comic Work Details mirrors the native metadata-first layout. Only deliberate
scrolling past metadata enables lazy page previews. Preview widgets use source
thumbnail URLs (or offline files), never the full remote reader page as fallback.
Thumbnails cap decoded edges at 768px with aspect ratio preserved and a 2MiB
encoded-byte limit. Readers keep their separate full-page resolution policy.
Image requests share two active jobs, a bounded latest-first queue and eight
reusable origin clients. A total deadline is passed into abortable requests; slots remain occupied
until the transport future completes. No extra unbounded byte cache is added.

The optimized Android profiling build is available with:

```sh
flutter build apk --profile --target-platform android-arm64 --split-per-abi --no-pub
```

Output: `build/app/outputs/flutter-apk/app-arm64-v8a-profile.apk`. This uses AOT
compilation with profiling support; it is not a production-signed release.
