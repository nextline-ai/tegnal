# Flutter UX alignment validation — 2026-10-27

Compared native presentation source and the Korean marketing captures. Repetitive
screen audits, implementation and verification used GPT-6 Luna; the parent owned
shared navigation/reader integration and final review. Material UI 1.8.0 and
bundled Pretendard remain in use. Native Apple code was not changed.

## Focused checks

32 affected tests passed across these files (not a full regression suite):

- `test/ui/library_flow_parity_test.dart`: 6 — mode scope, local artist grid, batch offline work addition, duplicate preservation/export, saved edits and source selection.
- `test/ui/setup_flow_parity_test.dart`: 5 — setup/replay/import-only, fixed-mode reader preferences, empty Pools feedback.
- `test/ui/explore_flow_parity_test.dart`: 3 — token completion, focused history management and returning search controls.
- `test/core/booru_sort_test.dart`: 5 — source intersections, API query mappings, preserved constraints, explicit rejection vs valid empty response.
- `test/core/explore_flow_test.dart`: 3 — empty source persistence, rejected-sort rollback and source capability changes.
- `test/ui/shell_reactivity_test.dart`: 4 — live settings, nested Back, retained mode navigation and async feed updates.
- `test/ui/reader_flow_parity_test.dart`: 4 — ordered post sequence/save identity, Back hierarchy, preview selection and paused automatic advance.
- `test/ui/reader_controls_test.dart`: 2 — existing reading actions and narrow/large-text controls.

Full Flutter static analysis passed; subsequent source-picker/Pools integration
also passed scoped analysis. Localization validation passes for 1,264 matching
en/ko/ja keys. `git diff --check` passed. Final Android ARM64 debug APK build passed.

## Visual and Android evidence

The isolated in-memory capture run produced 14 affected screens in
`flutter/build/ui-captures/parity-flows/`, with no framework errors or unexpected
network requests. The final Saved toolbar capture is
`flutter/build/ui-captures/library-selector/booru-library-source-selector.png`.
The 320-point Manga header fits; long folder names truncate rather than overflow.

The existing `emulator-5554` was reused and the APK installed with `adb install -r`.
Checks covered shared tab selection during mode switching, reader settings,
replay onboarding Back/Continue/Done, tutorial mode isolation, the import reminder,
the actual Saved server picker and Android Back, and More → Pools with no sources.
Final device captures are in `flutter/build/ui-captures/ux-android/`.

During an initial live raw-file database comparison, two default-valued setting
rows (`glass` and `rememberHistory.manga`) were absent from a captured copy.
No deletion action was identified. Only those two keys were restored from the
protected preinstall snapshot with the app stopped. A cold launch and mode
roundtrip did not reproduce the difference. All ten tables and every row then
matched the original baseline; SQLite integrity checks passed. A live raw-copy
race is a possible explanation, not an established cause. Future checks should
stop the app before copying SQLite or use SQLite's consistent backup API.

No native iOS suite/simulator, full Flutter regression suite, physical Android
phone, live source/account/Google Drive flow, Windows or Linux runtime was tested
in this pass. Remaining native differences are listed in `flutter-parity.md`.


## Android feedback fixes — follow-up

This pass addresses the eight reported Android issues. Bulk edits used GPT-6
Luna; the parent reviewed integration, networking, and Android build configuration.

- Folder, note, and blocked-tag dialog controllers now live through route exit.
- The 96 × 48 mode control accepts a tap across the pill and directional drags.
- Add-source sheets use the root navigator and keyboard-safe constraints.
- Content paints behind the clipped translucent dock. Only scroll tails reserve
  dock space, including the physical bottom safe inset. Reduced motion does not
  disable transparency; high contrast can use an opaque surface. The experimental
  preference is removed, including its hidden reader behavior.
- The privacy cover uses the native app's light/dark artwork, 600 ms resume hold,
  and 900 ms slide (150 ms fade with reduced motion). Android overlays its window
  before pause/stop for the resume transition. Recents capture can precede
  these callbacks, so API 33+ uses OS snapshot suppression (an opaque task card);
  older Android uses a secure window, also restricting screenshots/recording.
  Flutter additionally covers routes and excludes underlying input and accessibility. Delayed keyboard metrics and duplicate resume events
  have regression tests.
- Explore/Saved content long-press toggles its bookmark; management remains on
  overflow/secondary click. The reader supports downward dismissal with native
  thresholds and guards for zoom, controls, continuous reading, and multitouch.
- Reader manifests are deduplicated in a four-entry cache. Previous/next two
  images use the visible image provider and viewport-bounded decoding. Speculative
  work is bounded and lifecycle/generation gated. A real-decoder regression
  verifies portrait/landscape aspect ratios under resize limits. Already-issued image requests
  can still finish; no measured frame-rate or real-phone latency claim is made.

### Connection handling

The user confirmed hitomi.la and k-hentai.org open in the same phone's Chrome.
Both publish ECH configurations in HTTPS DNS records; ordinary host HTTPS probes
were reset while a control HTTPS site succeeded. ECH/network-stack differences
are a plausible cause, not a confirmed diagnosis of that phone.

WebView main-frame connection failures now hand the same HTTPS URL to a browser
Custom Tab once, with localized retry/recovery controls. TLS certificate errors
still cancel. Browser cookies remain separate; opening a Custom Tab does not
claim to authenticate the app's catalog client.

Manga catalog requests use the bounded Android OkHttp 5.5 bridge first. On a
connection-level failure only, eligible source-scoped HTTPS GETs can retry
through pinned `ech_http` 0.2.3. That retry resolves only the exact configured,
data or CDN hostname through Cloudflare DNS-over-HTTPS, requires acceptance of
its discovered ECH route, disables redirects, and retains request cancellation
and response bounds. Aborts, HTTP status responses and Android certificate
validation failures do not retry. `ech_http` validates chains against its
bundled Mozilla roots, which are distinct from Android's platform trust store.
The ECH fallback uses no AI model downloads or user proxy. This code change has
not yet been device-verified. Flutter's Android compile/target SDK is 37 and
AGP is 9.1.1; the minimum SDK remains 24. Other platforms keep their prior client.

References: [Android ECH support](https://developer.android.com/privacy-and-security/encrypted-client-hello),
[Custom Tabs](https://developer.chrome.com/docs/android/custom-tabs/guide-get-started).

### Focused validation

Relevant widget and adapter tests passed for folder cancel, keyboard layout,
mode gestures, bookmark actions, reader gestures/cache bounds, privacy lifecycle,
dock/safe insets, URL-scoped sessions, Android transport cancellation, and manga
protocol fixtures. Scoped Dart analysis and localization checks passed. Android
ARM64 debug APK built successfully with compile/target SDK 37.

Four isolated fixture captures are under `flutter/build/ui-captures/bugfixes/`:
`saved-dock-background.png`, `source-add-keyboard-insets.png`,
`privacy-cover-inactive.png`, and `manga-mode-header.png`. They use an in-memory
library, local non-sensitive marketing images, and no unexpected network calls.
The keyboard capture supplies fake metrics; actual IME behavior is checked
separately on the retained emulator.

No full Flutter/native regression suite, device matrix, Google Drive account
flow, Windows/Linux runtime, or physical-phone performance benchmark was run.


Final runtime evidence:

- Metadata-only host probes using a real ordinary TLS primary plus ECH retry
  parsed 20 catalog items with more available on both hitomi.la and k-hentai.org.
- The APK's packaged ECH client ran on the retained API 37 emulator: both hosts
  returned HTTP 200 with `echAccepted=true`. Actual `MangaSource.search` in that
  running APK also returned 20 items per site. No catalog contents, artwork, or
  cookies were displayed/logged by these probes; no library data was written.
- Recents exposed Saved content with lifecycle overlays alone, including an
  early `onUserLeaveHint` attempt. The final OS snapshot-suppression change was
  verified to show an opaque card; the native branded resume cover remained.
- The gesture-arena mode implementation failed real ADB swipes. The final raw
  pointer implementation passed two settled swipes in each direction; whole-pill
  taps, folder Cancel with Gboard visible, and empty Pools were also checked.
- Final device captures are in `flutter/build/ui-captures/bugfixes-android/`.
- Every baseline database row remained unchanged. A consistent stopped-app copy
  also contained one new hitomi.la source plus `archivedSources` and `source.manga`
  settings, timestamped before the final probes. This was not attributable to
  the recorded verification actions and was preserved rather than deleted.
- Only OS-version properties were read from the attached physical Android 15
  phone. It was not installed, navigated, benchmarked, or otherwise modified.
  Physical-device reconfirmation remains necessary; no full regression claim.

The final Add Website flow was also checked with real Gboard on the retained
emulator: title, Cancel, both fields, type controls and Add stayed visible; the
dock was hidden and no privacy cover appeared. The form was canceled without
input/submission. A stopped-app database dump afterward exactly matched the
previous final snapshot (including the preserved new source). The final app was
left stopped after that comparison.

## Onboarding, source detection, icons and floating headers — 2026-10-27

The native `OnboardingView.swift` was used to align the three-step hierarchy:
inline navigation with Back/Done, progress inside the scrolling content,
leading titles and mode guide, rounded import/tutorial cards, a 560px content
limit with 24px margins, and a fixed bottom primary action. The connection step
also keeps the privacy-policy link below its primary action. Flutter's supported
backup/import actions remain functional; the Apple-only iCloud toggle is not
represented as an available Android integration. Tutorial mode selection is a
preview and does not change the user's active library.

The shared source form now identifies known Booru hosts immediately and checks
other HTTPS homepages against the native engine markers. Unknown/failed results
allow retry or explicit manual selection; no guessed engine is silently saved.
Detection has a deadline, size/redirect bounds, URL-scoped sessions, cancellation
and stale-result protection. Onboarding detects either content mode and adopts
the returned source mode only after the user presses Add. Existing source records
and storage schemas are unchanged.

The supplied 1920px `design-output/JPG/symbol.jpg` now produces the 1024px branding
and Android adaptive foreground, standard Android density icons, Linux PNG and a
seven-size Windows ICO. No logo was redrawn. Shared icon themes, navigation,
headers, settings, lists and reader controls were enlarged; explicit small glyph
sizes were reviewed so they do not defeat the theme defaults.

Root pages use floating label/mode/action capsules over the full scrolling
viewport, without an opaque rectangular toolbar backdrop. Explore/Tags search
hides on downward scrolling and returns on upward scrolling; focused search stays
visible. Source selection and other affected sheets use the root navigator so
that the dock cannot paint above their controls.

Focused checks passed: source detector/form cases, setup-flow cases, Explore
search/gesture cases, Artists search, and the new real-shell source-picker
root-navigator test. Scoped analysis and generated localization checks passed.
Nine isolated widget captures under `flutter/build/ui-captures/polish/` were
inspected, including all onboarding steps, scrolled headers, a sheet covering
the dock, and the reader at 320px. The capture reported no framework errors or
unexpected fixture network requests. Android ARM64 debug APK built successfully.

No full Flutter/native regression suite, device matrix, Windows/Linux runtime,
Google Drive account flow, or physical-phone benchmark was run for this pass.

Final installed-runtime check used only retained `emulator-5554`. The final APK
was installed with data retained. The app-drawer icon showed the high-resolution
wordmark on its white adaptive background (the cyan ring on a home shortcut was
launcher decoration). With real Gboard open, the Add Website sheet stayed above
the dock and kept Cancel/Add visible. Entering `https://safebooru.org` identified
Gelbooru immediately; the form was canceled without saving. Onboarding's Connect
step was captured on-device. The Import/Mode Preview device frames were not
verified because the navigation advanced before capture; their layout evidence
is the passing isolated widget capture, not a claimed device check. Device
captures are under `flutter/build/ui-captures/polish-android/`. The final
stopped-app SQL dump exactly matched the preinstall snapshot, with no restore
needed; the app was left force-stopped. The attached physical phone was untouched.

## Keyboard, work details and low-memory image refinements — 2026-10-27

The outer AppShell no longer resizes along with its nested Scaffold. Tabs mount
lazily, retain their navigator instances, and suspend tickers/focus plus keyboard
inset updates while hidden or behind a root modal. A focused regression changes
keyboard insets repeatedly with an unsaved folder name: the dialog/text persist,
the background viewport does not shrink, and Cancel does not create a folder.
Android's inactive/window-focus notification alone no longer shows privacy art;
actual pause/hidden handling and native Recents protection remain. This addresses
IME-before-insets races, without relaxing background snapshot protection.

Settings values shrink-wrap at the far right, with bounded width for long text;
only actual chevrons reserve space. Noninteractive on-device values align to the
same outer edge as the chevrons. Replay Onboarding now uses the root navigator;
a real-shell test confirms its primary action is reachable and the dock cannot
intercept it. Onboarding's existing footer SafeArea is retained.

Manga details use the native Work Details label (작품 정보), metadata/Read/Save
hierarchy, and deliberate-scroll preview gate. Previews use a lazy sliver grid,
source thumbnail URLs and bounded decode size. Opening metadata alone does not
load page previews. Both modes no longer show a per-work overflow overlay;
existing long-press bookmarking remains. Thumbnail decoding, page selection,
missing-thumbnail placeholders, local files, headers/redirects, request limits
and timeout cancellation have focused regression coverage.

Booru APIs/extras/detection and images now share the scoped Android transport.
Network/HTTP/certificate/abort distinctions and exact-URL cookie boundaries are
preserved. Live metadata-only host probes for Danbooru/Gelbooru still returned
TLS connection resets (HTTP000); Cloudflare DoH had no HTTPS/ECH answers for
these hosts. The user confirmed Chrome also needs a VPN/HTTPS bypass application.
Consequently this is not claimed as resolved live connectivity. Exhausted native
connection failures show conditional network guidance. At the user's request,
Android WebView no longer automatically launches an external browser on failure,
and its external recovery button was removed. Retry/Back/Close and certificate
cancellation remain.

Affected shell, privacy, settings alignment, source transport, image transport,
actual image decode, detail preview and selected manga/reader tests passed.
Scoped Dart analysis and localization checks passed. Android ARM64 profile APK
built successfully; this avoids treating debug/JIT overhead as release behavior.
No full test suite, device matrix or low-end physical-device benchmark was run.

The installed profile APK was checked on retained `emulator-5554`. A folder
name typed without saving persisted when Gboard was dismissed and reopened;
recorded transition frames showed the dialog remaining visible without a black
privacy cover. The dialog was then canceled. Replay onboarding progressed through
Connect → Import → mode preview using the fixed footer and returned to More with
Images mode unchanged. Settings values/chevrons aligned at the trailing edge.
The stopped-app SQL dump after verification exactly matched the preinstall
snapshot. The app was left stopped. Evidence is under
`flutter/build/ui-captures/polish-android/profile-*`, including
`profile-folder-ime-reopen.mp4`. This is qualitative emulator evidence, not a
measured low-end-device frame-rate improvement. The earlier debug recording's
Back/tap sequence was ambiguous and is not treated as proof of dialog state loss.


Eight focused fixture screenshots were inspected under
`flutter/build/ui-captures/refinements/`, including actual decoded artwork in
Explore, Work Details and lazy previews, 320px settings alignment, and the replay
route above the dock. The capture HTTP fake was updated for `http.IOClient` and
thumbnail fixtures now use real local assets within the 2MiB byte budget.
Decoded-image assertions catch silent placeholders; no production data or
external image requests were used. The final capture reported no framework
errors. These fixture-only adjustments required no APK rebuild.
