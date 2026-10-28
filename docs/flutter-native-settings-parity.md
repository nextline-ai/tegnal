# Flutter / native settings parity

Audit baseline: `native-ios/TEGNAL/Presentation/Settings`, `Presentation/Content/ReaderPreferences.swift`, `Presentation/Content/SearchHistorySection.swift`, `Presentation/Booru/BooruSettingsView.swift`, `BooruValidationView.swift`, `BooruBackupView.swift`, and `Presentation/Taste/TasteSettingsView.swift`. Visual baseline: `user_data/marketing/generated/screenshots/ko`, particularly `09-settings.png` and `10-safe-mode.png`.

The Flutter screens keep Material UI 1.8 controls, Pretendard / Pretendard JP, and platform-native dialogs/navigation. All exposed preference controls have a persisted value and a consumer. Native iOS sources are read-only.

## Inventory and consumers

| Native settings area | Flutter behavior / consumer | Scope |
| --- | --- | --- |
| Website connection, detected engine, server rename / removal / selection | Existing detector/import validation; server management includes multiple selected image servers. Removal retains saved works and original source identity. `AppController`, `BooruSourceDetector`, Settings server screen. | Per connection; manga and images separate |
| Website account / API key / password hash | `BooruCredentialsStore` uses platform secure storage. `BooruAuthenticatedClient` attaches Danbooru HTTP Basic, Gelbooru `user_id`/`api_key`, or Moebooru `login`/`password_hash` only to the configured HTTPS origin. Applies to post, search, pool, and note APIs. Old Gelbooru continues browser sign-in. | Per canonical server; excluded from backups |
| Validate Client / Cookies / Reset Cookies | Existing Android WebView verification; Settings lists cookies visible at the server URL. Reset waits for cookie expiration callbacks, deletes that origin's web storage, and invalidates session image caches. Favorites and secure API credentials remain. Desktop opens the external browser and does not import its cookies. | Android cookie APIs expose URL-visible cookies, not a complete domain/path database; UI explains this restriction |
| Use Embedded Browser | Item opening routes to `BrowserScreen` instead of native reader when selected. | Per mode |
| Show Work Information Before Reading | Manga opens the information sheet when enabled, reader directly otherwise. | Manga |
| Challenge Roulette / Servers / Pools / Downloads | Existing feature routes, with the four-row image settings group ordered as native screenshot 09. | Image mode / existing download scopes |
| Dark / Light / System appearance | Inline segmented selection; `AppController.appearanceFor` drives the application theme on mode changes. | Per mode, with previous shared appearance fallback |
| Folder Columns / Grid Columns | Automatic or 1–5; `ArtworkLayout` drives saved library, folder contents, and Explore. | Per mode; local device |
| Show Without Spacing | `ArtworkLayout` removes margins, gaps, thumbnail corners and card padding. | Per mode |
| Preview Columns / Preview Rows per Page | 0 means twice the resolved artwork columns; explicit columns 1–10. Rows 1–10 set preview tile extent. Reader preview grid consumes both. Native default rows: 5. | Manga |
| Show Work Titles / Show Work Artists | `ArtworkLayout` and `ContentTile` independently show/hide each text line and adjust card geometry. | Manga |
| App Language | Existing English / Korean / Japanese / system locale mechanism. Latest native strings plus Flutter-only overrides generate all three catalogs reproducibly. | Application |
| Language Filter Exceptions | `MangaSource` unions Game CG, Artist CG and Image Set across languages before applying remaining filters. Indexed catalogs union sorted IDs; document catalogs merge two disjoint category lanes while preserving sort/cursor order. | Manga searches |
| Default Search Tags / Default Excluded Tags | `effectiveSearchQuery` merges and deduplicates explicit/includes/excludes; excluded tags receive one minus prefix. Original typed query stays in history. Source search helper also covers recommendation and challenge retrieval. | Manga |
| Content language | Explore's language picker adds the selected language filter without rewriting search text. Explicit typed `language:` terms take priority. Recommendation language is independently scoped by server. | Current manga Explore state; recommendation scope separate |
| Reader resume: ask / continue / beginning | `ReaderScreen` resolves stored progress; ask offers explicit Continue Reading / Start from Beginning. Direct page selection takes priority. | Manga |
| Horizontal / Vertical / Continuous reading | Existing paging/scrolling mechanism. | Manga |
| Swipe Up for Previews | Continuous page swipes open previews only when enabled; downward exit remains restricted to the top handle. Preview action remains available in the menu. | Manga continuous mode |
| Right to Left / Tap the Sides | Reader taps, keyboard navigation, swipes, spread order, and image sequence navigation consume these options. | Separate reader preferences by mode |
| Pages per View | 1–4 pages grouped into aligned spreads; next/previous, jump, saved position and layout changes use group boundaries. Continuous mode retains individual pages. | Manga |
| Auto Advance / Seconds | Timer uses 2–120 seconds; pauses with quick menu/settings/guide/zoom/inactive state, stops on final page/image. | Per mode |
| Show Quick Menu at Bottom | Bottom alignment when enabled, centered menu otherwise (native default). Screenshot fixture 04 explicitly chooses bottom alignment. | Per mode |
| Show Page Number / Keep Awake / Dim Screen | Reader overlay; existing wakelock restoration; 0–0.65 dimming overlay. Native page-number default is off. | Per mode |
| Prefetch Pages | Off / 2 / 3 / 5. Off schedules no speculative manga image requests; enabled loading is bounded to one prior page and the selected forward neighborhood. Image sequences retain bounded adjacent-post manifest/image reuse. | Manga loading option; image mode fixed neighbor policy |
| Reader Guide / Don't Show Again | Guide opens on first manga reading until hidden, can always reopen from Reader Settings. Working gestures are described; images also expose guide text. Flutter uses the exact native ReaderGuide artwork with three illustrated, interactive lessons; RTL, scrolling, zoom and the top-handle exit are reflected in the diagrams. | Manga hide preference; no inert help switch |
| Original Images / Reduce Image Data Further | Original secure file URL takes priority. Otherwise reduced-data mode selects the preview image, normal mode retains viewing-size compressed media. Video keeps its playback source. | Image reader |
| Show Notes on Images | Existing note API / rendered overlays; toggle persists and controls overlays. Two-finger video tap opens the quick menu. | Image reader |
| Fit Entire Thumbnails | `ArtworkLayout.fitsThumbnails` switches image card fitting between cover and contain. | Image mode |
| Remember Search History / Keep History / Clear | Per-mode recording switch, Always / 3 / 7 / 30 days retention with mode-scoped pruning, confirmed clear. Saved searches remain separate. | Per mode |
| Taste Analysis enabled / pause | Persisted local SQLite event collection stops while disabled; saved works and existing evidence remain. Recommendation retrieval is disabled while paused. Folder/note edits do not create organic saves. | Local analysis control |
| Analysis excluded tags / Excluded taste tags | Per-mode defaults and per-server overrides. Excluded taste tags can be removed to include them again; they affect analytical/seed/scoring eligibility, not a blanket content blacklist. | Per mode/server |
| Recommendation filters | Per-server mandatory included tags, independent manga language and supported source sort. Manga supports latest and native day/week/month/year popularity ranges. Candidates must match all included tags. Recommended output retains taste ranking; latest sorts IDs descending; popularity modes preserve deterministic query/page order regardless of network completion. | Per source ID in this installation |
| Weekly statistics / Monthly Recap | Separate report destinations select the intended period. Indexed save/open activity produces device-local calendar-week / calendar-month totals, including past activity of subsequently removed works. Enough observed/organic evidence enables lift scoring. | Local historical events, retained until reset |
| Delete all analysis data | Confirmed deletion clears the independent event table, retains saved libraries, and preserves the bootstrap marker. Old saved works are not silently reanalyzed. Newly imported works produce non-organic imported evidence only. | Both local analysis modes |
| Safe Mode / Age Guide / Default Search Tag | Native `g` / `s` / `q` rating defaults; explicitly typed rating rules override. Manga mode cannot activate while safe mode is on. Computed rating tag is shown in Settings. | Image browsing |
| Library backup / restore | Existing native-compatible JSON inspection, confirmed merge and export. Both modes, folders, tags/artists/searches, server/filter metadata and challenges retain existing format behavior. | Library metadata; media/credentials/caches excluded |
| Violet `user.db` / `data.db`, Anime Boxes | Existing importer; catalog import now exposes match-saved-only vs entire catalog, progress and acknowledged cancellation. Source files stay read-only; cancellation does not commit partial library writes. | Explicitly selected file |
| Fill Covers, Titles, and Tags / Pause / status | Sequential background-in-app detail fetching merges metadata without changing folder membership/note or recreating works deleted during requests. Cover loading warms the authenticated shared bounded cache. Can pause/retry; status reports progress/failures. | Saved manga library |
| Clear Image Cache | Confirmed `SessionImageLoader.clearCache` clears decoded, encoded-memory and managed disk image cache. Saved library and completed downloads remain. | Local cache |
| Replay Onboarding | Existing mode-aware onboarding route. | Per open action |
| Keyboard & Mouse | Guide describes implemented arrow/Page/Home/End/Space/Escape/zoom/bookmark operations. | Supported input devices |
| Privacy / licenses / version / developer destinations | Native policy destination, Flutter license registry, app version, NextLine website/email/community/GitHub. Links open only on user action. Android image Share uses a real system ACTION_SEND chooser. | Application |
| Discord invitation | Native cadence: display schedules next invitation after 3 days; dismissal after 7 days. Local preference and live visibility survive mode changes. | Device |

## Platform-specific exclusions and differences

- **iCloud / Sync analysis with iCloud**: Android and desktop Flutter targets cannot use this app's iOS ubiquity container and iCloud entitlements. The Google Drive library sync implementation is retained but temporarily disabled by the current product flag. Bootstrap does not create its auth/sync controller; stored account and sync choices are preserved. It does not claim to sync local taste events or reader/layout settings. Native-compatible JSON remains the cross-platform library transfer mechanism.
- **Translation**: Android reader translation now hands the visible image to the installed Google Translate app, rather than an AI service. A declared image-share handler receives a scoped temporary PNG URI. Otherwise Android 10+ offers an explicit save-and-open route and instructions for Google Translate’s Camera → All Images. Missing/unsupported apps receive a clear message. Google Translate chooses languages and may use its own network; TEGNAL downloads no models and exposes no inert Apple translation-language selector. See [implementation and official references](../flutter/docs/installed-google-translate.md).
- **Cookie inspection**: Android `CookieManager` exposes name/value cookies matching a URL, not full expiry/domain/path attributes or a safe server-isolated cookie database. Reset affects visible cookie names at the configured/parent URL paths and origin web storage; other cookie paths can retain sign-ins. It never calls global cookie deletion. Desktop cannot inspect another application's browser session.
- **Branded support presentation**: The native reader-help illustration and three-step layout are now reused. The developer section retains its functional support destinations with Flutter controls rather than duplicating the native web artwork.
- **Analysis persistence implementation**: Flutter reconstructs deterministic local reports from its indexed event table. It does not exchange native iCloud taste epochs, report cache documents, device author IDs, or discovery-session attribution. New organic saves, removals, opens, imported baseline evidence, pause, source filters and reset are implemented; this is not an assertion of byte-for-byte native analysis storage compatibility.

## Preference persistence and import boundaries

New choices live in `LibraryStore.settings`: `appearance.<mode>`, `folderColumns.<mode>`, `gridColumns.<mode>`, `removesGridPadding.<mode>`, manga text/preview/search keys, `reader.<mode>` JSON, history keys, and source-specific recommendation maps. Existing Flutter reader JSON decodes missing fields to native-compatible reader defaults; unknown enum values and out-of-range spreads/intervals/dimming are safely bounded. The previous shared `appearance` value remains a fallback until a per-mode choice is made.

Native iOS stores these preferences in UserDefaults under different keys. Native library JSON backups intentionally carry library metadata rather than UserDefaults; Flutter does not treat a JSON library restore as a preference migration. Credentials and cookies have separate secure/platform stores and are never serialized into library backups. Settings surviving an Android/desktop restart are verified independently from cross-platform library transfer.

## Focused validation

- `test/core/settings_parity_test.dart`: per-mode persistence, default tag merge, rating override/mode restriction, retention, spread boundaries, disabled/bounded prefetch, native credential protocols and origin isolation.
- `test/core/manga_source_test.dart`: indexed and document catalog language exceptions, cursor/filter behavior, plus existing transport/manifest regression cases.
- `test/ui/settings_trailing_alignment_test.dart`: inline theme persistence and trailing alignment.
- `test/ui/reader_controls_test.dart`, `test/ui/reader_flow_parity_test.dart`: reader action behavior, constrained widths, spread navigation/layout replacement, explicit resume choice, sequences, previews, auto advance and exit gesture policy.
- `test/core/taste_controller_test.dart`, `test/core/insights_test.dart`: independent analysis persistence/pause/reset and source filters/historical recap rules.
- `flutter/tool/sync_localizations.py --check`: native read-only catalogs plus maintained overrides, matching English/Korean/Japanese keys and format tokens.

Screenshots and the Android runtime/build checks are recorded separately by the integrating task; widget captures alone do not verify Android secure storage, WebView cookie deletion, or system share sheets on a physical device.

Final affected-settings run: 46 tests passed across the seven core/UI files listed above. Two additional focused regressions passed for first-reader guide/hide behavior and notifying an existing analysis listener when a work opens (48 distinct tests total). The native localization regeneration check and `git diff --check` passed.
