# Native visual and folder workflow comparison

The reference is the actual Korean marketing screenshots in
`user_data/marketing/generated/screenshots/ko`, inspected together with the
read-only SwiftUI sources in `native-ios/TEGNAL/Presentation`. Flutter keeps
Material UI controls, icons and modal behavior, with bundled Pretendard and
Pretendard JP.

## Matched surfaces

- Saved: native 2×2 folder previews, one baseline for title and trailing count,
  two folder columns, native ordering and color, compact All Favorites row,
  create-folder then server toolbar actions, floating split dock.
- Explore/collections: the same per-mode density settings, compact 44pt search,
  3-column reference artwork grid, native selection indicators, grouped compact
  selection toolbar with the full collection title at 402pt. Saved collections
  use a context menu without covering each image with an overflow button.
- Search: distinct history and saved-search sections, gold saved indicators,
  two saved rows above the simulated keyboard inset. The Korean placeholder
  uses the native `Search tags` localization key, translated as `태그 검색`.
- Reader capture: the fourth native artwork (olive branches), 4/24 sequence,
  original-resolution local media and the reference's bottom-menu preference.
- Settings, Safe Mode and backup: captured using their real app routes; settings
  typography explicitly retains Pretendard in Material segmented controls.

At 402×874 logical pixels, the first artwork rows in the native screenshots are
Saved 206pt, Explore 234pt, and selection 184pt. Flutter's corresponding rows
are 206pt, 235pt, and 184pt. The native reference configures two folder columns
and three artwork columns. Automatic density separately follows the native
160pt minimum and five-column ceiling, with 240pt folder minimum on wide layouts.

## Folder behavior

Long press or secondary click opens Change Color, Reorder Folders, Rename Folder
and Delete Folder. Color selection accepts any opaque RGB value through a grid,
channel sliders or hexadecimal input and commits immediately. Reordering remains
a draft until Save; Cancel discards it. The built-in Unfiled row has color and
order controls, cannot be renamed and cannot be deleted while it contains works.

Folder creation asks only for a name. LibraryStore assigns the first unused
color from the native 28-color palette; once all are present, it uses the native
golden-ratio hue formula with saturation 0.75 and value 0.88. Deleted colors
become available again, while cancellation consumes no color. Later Change
Color remains available. Manga reuses an existing trimmed folder name, while
Booru permits distinct folders with duplicate names.

Customizing an initially virtual Unfiled row creates a metadata-marked native
folder only at that point. Image export maps it to `unsorted`; Comics export
retains the native `미분류` name. Custom color and order survive native-compatible
export/import without creating a duplicate visible Unfiled row. Both formats
have focused round-trip tests. Moving images replaces their folder membership;
adding Comics to a folder preserves their other memberships and notes.

## Reproducible evidence

See `tool/ui_capture.md` for the native-parity command. Fifteen PNGs and a
framework-error report are written to `build/ui-captures/native-parity/after/`.
Five original baseline frames remain under `before/`. Browsing captures require
decoded artwork before being written. Fixture requests use isolated local
artwork and an in-memory database, with no production seeding or network access.

The capture harness does not draw OS status indicators or a platform keyboard;
the history frame applies keyboard insets. Material icon shapes, switches,
menus and dialogs intentionally remain Material. The native screenshots use
system typography, while Flutter intentionally retains Pretendard.

## Reader guide follow-up

The guide now uses the **exact native ReaderGuide image**, copied read-only from
`native-ios/TEGNAL/Assets.xcassets/ReaderGuide.imageset/reader-guide.png` to
`assets/branding/reader-guide.png` (both SHA-256:
`c11599897d68e142524460924d123ed7b34c1b29cf63536720ad87a74578fa3e`).
It follows `ReaderHelpView` in `ReaderPreferences.swift`: three illustrated
Taps, Zoom & Translate, and Exit lessons, native 30/40/30 tap zones and badge
positions, step selection, next/back, Close, and Don't Show Again.

Flutter gesture demonstrations cover RTL taps, double-tap/pinch zoom and pan,
and continuous scrolling's top-handle exit; dragging the illustration's page
body does not demonstrate an exit. First-open dismissal persists, and Reader
Settings always reopens the complete guide. At 320px and 2× text scale, short
step/button labels and readable diagram badges keep dismissal/navigation
visible; full descriptions and the reopen caption remain accessible by scrolling.

Five focused guide tests pass, plus the first-open/hide reader regression
(**5 + 1**). They cover navigation, RTL/zoom, continuous exit, persistent hide
and manual reopen, and scrolling to both ends of enlarged descriptions.
Five inspected captures are under `build/ui-captures/reader-guide/`:
`01-taps.png`, `02-zoom-translate.png`, `03-exit.png`,
`04-continuous-exit.png`, and `05-large-text.png`.
Regenerate with `flutter test --no-pub --dart-define=TEGNAL_CAPTURE_GUIDE=true test/ui/reader_guide_capture_test.dart`.
