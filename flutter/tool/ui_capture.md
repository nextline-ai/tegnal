Run the optional screenshot check from `flutter/` on macOS:

```sh
flutter test --dart-define=TEGNAL_CAPTURE_UI=true test/ui/ui_capture_test.dart
```

The test uses the actual app screens, an in-memory SQLite library, a disposable
download directory, and 24 local marketing artworks from
`user_data/marketing/generated/asset-manifest.json`. It creates six folders,
saved searches, and artist records only inside that in-memory database. Explore
results and image requests use offline fixtures; unexpected image URLs fail.
It never opens the installed app's database or writes production sample content.

PNG captures at 2x resolution and `validation.txt` are saved in
`flutter/build/ui-captures/`. Captures cover Korean dark/light mobile, populated
library/explore/tags/settings/smart screens, the Google Drive setup screen in
Korean/English/Japanese, desktop sidebar, and a 320-point window with 150% text.
Drive capture uses real unconfigured Android authentication without initiating
sign-in; it confirms the setup requirement and disconnected state. Widget captures omit OS status indicators. Bundled Pretendard and Pretendard JP
fonts provide readable text alongside the official Material icon font. A separate
Android emulator capture verifies installed runtime appearance without replacing
or clearing its data.

For the focused UX comparison added on 2026-10-27:

```sh
flutter test --no-pub --dart-define=TEGNAL_CAPTURE_UI=true --dart-define=TEGNAL_CAPTURE_PARITY_FLOWS=true test/ui/ui_capture_test.dart
```

This captures 14 affected screens/steps in `build/ui-captures/parity-flows/`,
including the direct image viewer, history-to-Explore routing, compact Manga
header, offline batch addition, gallery previews and import onboarding. To
refresh only the Saved toolbar after a visual change, use
`--dart-define=TEGNAL_CAPTURE_LIBRARY_ONLY=true` instead of the parity-flows flag;
its single image is written under `build/ui-captures/library-selector/`.

For the onboarding, source-sheet, icon and floating-header refinement:

```sh
flutter test --no-pub --dart-define=TEGNAL_CAPTURE_POLISH=true test/ui/ui_capture_test.dart
```

This captures nine focused frames in `build/ui-captures/polish/`: Saved before
and after scrolling, the root server sheet above the dock, Explore with search
shown/hidden, reader controls at 320px, and the three onboarding steps. It uses
only the same isolated in-memory fixtures and checks framework errors and
unexpected network requests. Installed-device data is never used or seeded.

For the keyboard/settings/detail performance refinement, use the focused flag:

```sh
flutter test --no-pub --dart-define=TEGNAL_CAPTURE_REFINEMENTS=true test/ui/ui_capture_test.dart
```

Frames under `build/ui-captures/refinements/` cover the unobstructed replay route,
settings trailing alignment at normal/320px widths, artwork without overflow
buttons, and manga metadata before/after deliberate scrolling to previews.
Fixtures implement the same HTTP client interface as the shared authenticated
image transport; decoded-image assertions prevent error placeholders from being
mistaken for successful artwork rendering.
