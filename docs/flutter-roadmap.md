# Flutter delivery roadmap

Updated 2026-10-27. Android is the first delivery target; Windows and Linux follow the same domain implementation. The native Apple app stays read-only and remains the behavioral reference in [flutter-parity.md](flutter-parity.md).

## How to read status

- **Implemented** means executable source exists. It does not mean a platform or website was exercised.
- **Fixture-covered** means the named offline test file targets that behavior. A test file's presence alone is not a passing-run claim.
- **Build-verified** requires a recorded target, command, result and revision. Compilation does not establish runtime behavior.
- **Device-verified** requires an explicitly selected install/launch/workflow check on an existing target device. The 2026-10-27 record below covers selected emulator UI behavior only.

Integrated Android compile: **passed** — `flutter build apk --debug --target-platform android-arm64 --split-per-abi --no-pub` produced `flutter/build/app/outputs/flutter-apk/app-arm64-v8a-debug.apk`, including Kotlin browser/files integration, downloads and insights. Full Flutter static analysis passed with no issues; the final navigation adjustment passed scoped analysis. APK inspection confirmed ARM64-only native code, application ID `work.nextline.tegnal`, and Android API 24 minimum. Windows/Linux builds: **not run**. Android in-place installation and selected emulator UI navigation: **verified** on 2026-10-27. Live manga first-page connectivity: **verified** for hitomi.la and k-hentai.org on the retained Android emulator in the follow-up described in [UX validation](flutter-ux-validation.md). Live account/authentication workflows remain **not verified**. The manually dispatched [build workflow](../.github/workflows/flutter-platform-builds.yml) has not been dispatched; its definition is not build evidence.

## Screenshot parity pass — 2026-10-27

The root shell and core browsing/collection screens now follow the supplied iOS
marketing compositions. This includes compact mode capsules, floating tabs,
retained nested navigation, folder mosaics, three-column image grids, saved
searches, grouped backup settings, and the reader action palette. Shared
switches support touch/drag, keyboard, RTL, reduced motion and semantics.
The floating dock now always uses bounded translucency, with an opaque high-contrast fallback. The experimental toggle is removed; AI downloads remain absent.

Focused widget checks passed for bulk library organization, saved-search native
backup round trips, reader actions, and switch inputs. A separate opt-in harness
renders real screens with an isolated in-memory library and existing local
marketing artwork. It checks Korean layouts, larger text, nested navigation,
and consecutive Ctrl-number shortcuts; no production seed data is installed.
See [Flutter UI documentation](../flutter/README.md#screenshot-driven-interface)
for package provenance and reproduction instructions. The existing Pixel_10_Pro emulator was updated in place with `adb install -r`;
launch, library/settings/backup/collection presentation, mode switching,
Android back navigation, switch on/off state and accessibility labels were
checked without clearing app data. Original preferences were restored; a
read-only logical comparison matched all ten database tables before and after. Runtime captures are saved under
`flutter/build/ui-captures/android-*.png`. These checks do not validate live
website, account, or desktop binary behavior.

## Material and Google Drive pass — 2026-10-27

Application UI now uses official `material_ui` 1.8.0 with supported Material 3
Expressive component styling, bundled Pretendard/JP fonts, and native Material
controls. The previous Cupertino application imports and custom switch were
removed. Image-led layouts and responsive navigation remain.

Google Drive metadata synchronization is implemented with Android Google
Sign-In, desktop PKCE/secure storage, immutable native JSON revisions, explicit
whole-library conflicts, exact deletion propagation, account isolation, and
local recovery. Automatic foreground sync defaults off. Focused offline OAuth,
HTTP, controller and snapshot tests passed. OAuth IDs are deliberately absent:
real Google account/Drive validation awaits [project setup](google-drive-setup.md).
This is not native iOS Google sync; its existing JSON export/import is the
compatibility bridge. No cloud account was connected during implementation.

## Implementation inventory

| Area | Implemented source | Focused fixture surface | Remaining acceptance work |
| --- | --- | --- | --- |
| Shell and storage | `app.dart`, `core/app_controller.dart`, `data/library_store.dart`: two mode libraries, five destinations, adaptive sidebar/tabs, SQLite settings and persistence | `app_controller_test.dart`, `library_store_test.dart` | Restart/device persistence; mode/tab/scroll retention; inactive accessibility/focus; native mode swipe and full appearance preference behavior |
| Manga browsing | `data/manga_source.dart`: configured-host discovery, both protocols, range/cursor pagination, keyword/tag include/exclude search, manifest/page resolution | `manga_source_test.dart` | Authorized live checks for each backend, discovery movement and malformed/error responses; persistent endpoint caching; native WebP/AVIF and image retry behavior |
| Image browsing | `data/booru_source.dart`, `data/booru_extras.dart`: engine-specific public APIs/fallbacks, suggestions, details; supported Danbooru/Moebooru pools and notes | `booru_source_test.dart`, `booru_extras_test.dart` | Representative authorized server checks; unsupported extras on other engines remain explicit; native pool routing and full account-specific API behavior |
| Saved library | Folder mosaic/list/name/color/order, memberships, notes, search, artist/group/tag bookmarks | Controller/store fixtures cover data changes | UI create/edit/move/remove flows, many folders/large collections, text scaling, bookmark kind/source behavior and native saved-search/star controls |
| Reader/media | Paged horizontal/vertical and continuous reading, progress, RTL, zoom, keyboard, media playback, notes and preferences | Download/manifest fixtures cover persisted inputs; no whole reader UI result | Native multi-page spreads, thumbnails/jump and full exit/menu/gesture contract; zoom/scroll arbitration; lifecycle/wakelock/auto-advance; video/image codecs and notes on devices |
| Downloads | Persisted foreground queue, pause/resume/retry/remove, origin/content checks, completed manifests and offline opening | `download_manager_test.dart`, `download_lifecycle_test.dart` | Background/pause races and offline restart on Android; interrupted/expired catalog URLs; disk-full/file denial; metadata search/bytes UI parity; background service remains outside the current foreground design |
| Metadata backup | Native combined/standalone/historical formats, source remapping, atomic merges, all history, portable metadata and secret exclusion | `backup_codec_test.dart` | Android document selection/share grants and real export/restore; cross-platform file round trip; malformed/large files through the actual UI |
| Legacy import | Read-only Other Manga Viewer user/catalog SQLite and Anime Boxes `.abbj`; staging, defaults, rollback and cancellation APIs | `legacy_import_test.dart` | Match-only vs full-catalog/destination options, user-facing progress/cancel, background-isolate final writes, large-file device behavior |
| Challenges | Native-shaped definitions; weighted/filter/support choices; mixed stepped goals; score bands/endings; revision-safe local sessions; JSON advanced editor; source/folder reference picker | `challenges_test.dart` | Native subeditors and reel animation; multi-server source selection UI; background timer/reference flows on devices; custom-definition round trips through file pickers |
| Smart/statistics | `core/insights.dart`: saved-metadata tag policy, exclusions, statistical findings/recaps and collection-based source discovery/ranking; integrated Insights UI | `insights_test.dart` (eight offline cases passed); no native event/ranking equivalence claim | Native organic/discovered activity events, history boundaries/reset epochs, complete report/recap controls, and device/source checks for the new ranking path |
| Browser/session | Android WebView bridge, per-URL cookie lookup, scoped transport/media headers and validation entry point; desktop external browser fallback | `session_client_test.dart` plus source transport fixtures | Actual verification/login sites, redirects, secure/path/domain cookie rules, logout/reset and multi-account behavior; desktop embedded account adapters |
| Localization | Native catalogs plus Flutter supplements, generated en/ko/ja keys and placeholder validation | `tool/sync_localizations.py --check` | Runtime built-in Challenge/error text bypassing localization; counts/date/number formatting; layout and accessibility review in each language |
| Packaging | Android launcher PNGs, Windows ICO/product title, Linux application ID/icon/desktop entry; manual single-platform build workflow | Source/resource inspection only | Real builds/installers, release signing, desktop dependencies and clean-machine launch; Windows/Linux runtime behavior |

## Phase 1 — Android preview gate

Complete these before calling the port an Android preview ready for regular use:

- [x] Replace the Flutter counter template with the application shell, local library and actual source adapters.
- [x] Implement portable metadata transfer, foreground offline downloads and unavailable-system-AI behavior without model downloads.
- [x] Reuse existing TEGNAL branding and native localization; preserve the native app and user data.
- [x] Record the final integrated ARM64 debug build and artifact path (command/result above). Keep compilation separate from runtime behavior.
- [ ] With explicit device scope, install on one existing Android device/emulator and check cold start/onboarding, source entry, mode switching and restart persistence. Do not create a device matrix by default.
- [ ] Check one requested source workflow: browse/search → details → save → folder/note → read/resume → download → airplane-mode reopen → remove. Record the source/backend and authorization; offline fixture results are insufficient.
- [ ] Check Android verification/login, cookies on metadata and media requests, dialog/file cancellation and source deletion without leaking cookies into backups.
- [ ] Check downloads when backgrounded/resumed, rapid pause/resume, missing/changed files, low space and opening a completed manifest after app restart.
- [ ] Check back navigation, keyboard dismissal, text scaling, contrast and Korean default/system-locale layout. Distinguish visual inspection from UI automation.
- [ ] Replace debug release-signing configuration with a reviewed distribution setup before any public release.

Exit evidence: a reproducible APK plus recorded device workflows and a named list of unresolved defects. A successful build alone does not close this phase.

## Phase 2 — Finish native core workflows

Each item should be a small diff with the narrowest affected fixture/method or an explicitly requested UI check:

- [ ] Port the complete reader spread/preview/jump/menu/gesture contract and per-mode settings; retain progress and auto-advance lifecycle rules.
- [ ] Implement saved searches, history retention/star actions, native mode-specific tag/artist surfaces and complete pool entry routing.
- [ ] Finish artwork layout controls (columns, spacing, titles/artists, preview columns) and apply them consistently across modes.
- [ ] Add the metadata/cover backfill queue with recent-first prioritization, pause/resume and processed/failed/gone reporting.
- [ ] Move large import final commits off the UI isolate and expose destination, match/full-catalog, progress and cancellation controls.
- [ ] Port deterministic Taste event collection, contextual ranking, source constraints/exclusions, reset epochs, weekly/monthly boundaries and report controls. Do not label collection counts as recommendations.
- [ ] Replace Challenge advanced JSON-only workflows with native-equivalent subeditors where appropriate, finish source-selection UX, and verify resumable timers/references.
- [ ] Finish localization of runtime built-in text and number/date/count formatting; add all newly introduced literals to the supplemental catalogs.

Exit evidence: each applicable row of the [parity contract](flutter-parity.md) is implemented with proportional checks, or explicitly listed as a remaining limitation. No visible action should imply a service that does not exist.

## Phase 3 — Windows and Linux

- [ ] Run one manually selected Windows build on Windows with the C++ workload; retain the entire release bundle and dependency list.
- [ ] Run one manually selected Linux build with GTK/libmpv/epoxy tooling; retain the entire relocatable bundle and system-library requirements.
- [ ] Validate clean-machine launch, writable application-support paths, file pick/save/cancel, video/audio codecs, keyboard/focus, pointer context menus and resizing.
- [ ] Implement or explicitly limit desktop browser/account integration. Opening an external browser does not share its cookies with the app.
- [ ] Validate Windows signing/installer and Linux launcher/icon registration/package layout; the current ZIP/tar bundles are previews.
- [ ] Check desktop import/export and offline media without copying device-specific paths into portable metadata.

Build locally on the target OS or manually choose one platform in the CI workflow. Do not expand an Android fix into all-platform builds or a test matrix automatically.

## Phase 4 — Capability-specific integrations

- [ ] Add OCR/translation only when a real installed platform system service is available and its supported languages/geometry/cancellation can be verified. Unavailable remains a valid usable path.
- [ ] Keep AI model download/install APIs absent. Do not substitute silent cloud inference, bundled replacement models or hard-coded availability.
- [ ] Treat Apple Vision feature-print archives as nonportable. Any supported alternate similarity algorithm needs a separate revision/cache and an explicit description of different semantics.
- [ ] Add Android share-intent intake and platform-specific save/share/permission handling with real adapters and device checks.
- [x] Implement Google Drive metadata synchronization and OAuth setup guidance. Live project/account validation remains pending; iCloud Drive stays native-Apple-only.
- [x] Replace the Cupertino application UI with official Material 3 Expressive components. The dock always uses bounded translucency, with no experimental setting.

Web remains unsupported by this app's current `dart:io`, native SQLite/filesystem/media and method-channel design. A real web target would require a separate storage/transport/media integration plan, not a template build.

## Verification record and commands

Recorded during implementation: manga fixtures passed nine tests; Challenge fixtures passed eight, then two affected backup tests passed after the last core adjustment. Other focused fixture files are listed above; do not extrapolate these into a full-suite or whole-app result. Packaging received source/resource inspection; the primary agent also compiled the integrated Android target. Windows/Linux remain unbuilt.

For future logic changes, select the affected file or test name, for example from `flutter/`:

```sh
flutter test test/core/manga_source_test.dart --plain-name 'range mismatch and executable script suffixes fail without evaluation'
flutter test test/core/challenges_test.dart --plain-name 'deadline timer survives restore, pauses accurately and awards only when ready'
python3 tool/sync_localizations.py --check
```

Follow [AGENTS.md](../AGENTS.md). The native test-selection and simulator rules in [testing.md](testing.md) apply to `native-ios/`. Flutter validation should target changed behavior; the opt-in visual harness is documented in [ui_capture.md](../flutter/tool/ui_capture.md). Use existing devices, preserve data, and record exactly what a focused check did and did not establish.
