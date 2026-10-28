# Release UI performance checks — 2026-10-28

Production changes preserve the existing design and behavior. Native sources
were inspected read-only; no device or emulator was controlled for these checks.

## Verified reductions

- Saved previously decoded every saved work, then scanned that list once for
  every folder and eagerly constructed all folder widgets. `libraryOverview`
  now obtains counts and at most four decoded covers per folder. The SQL window
  ranks only keys; large JSON payloads are fetched after the four-cover cutoff.
  The folder grid now builds visible/cache-extent cards lazily.
- A 10,000-work, 40-folder fixture decodes **160** folder covers instead of
  **10,000** work payloads. Multi-folder memberships and imported Unfiled aliases
  retain their previous counts and newest-cover order. Mode separation and
  bookmarked-key lookup are covered by tests.
- Artwork layout preferences are frozen once per parent grid build. Rebuilding
  a tile or laying out a scroll row performs no preference queries. Preference
  changes obtain a fresh snapshot on the next controller notification.
- Explore bookmark lookup queries only the lazy grid's current 64-candidate
  chunk, once per chunk/snapshot, rather than querying each tile or reading all
  saved works. Saving/restoring the library obtains a fresh parent snapshot.
- Near-end scrolling avoids calling search while already loading or after the
  final page, avoiding source/settings lookups on each scroll update.
- Collection typing and selection reuse one decoded collection snapshot until
  a controller notification invalidates it. Search text is normalized once per
  snapshot rather than decoding JSON and reconstructing search fields on every
  character or selection change.
- Keyboard inset dependencies are scoped to the small scroll-tail/search
  builders. Five simulated keyboard inset frames caused zero extra overview
  reads and zero Explore preference reads in the targeted widget tests.

## Evidence and limits

`test/core/library_overview_test.dart` validates membership semantics and the
10,000-work bound. One local host test sample measured 96.096ms for the former
full-decode/folder-rescan path and 15.611ms for the overview. These are a single
non-device sample, provided for diagnosis only; they are not an FPS result or a
product performance guarantee.

`test/ui/release_scroll_performance_test.dart` checks lazy folder construction,
bounded bookmark batches, immutable layout reads, keyboard-frame queries and
collection snapshot invalidation. It is run with the existing library action,
folder organization and Explore flow regression tests.

The implementation follows the native folder-preview limit in
`native-ios/TEGNAL/Core/Storage/AppDatabase.swift` and avoids per-cell bookmark
queries, following the snapshot approach in `Core/Booru/BooruStore.swift`.

GPU frame timing and physical-device FPS were not measured. Existing blur and
navigation appearance were retained. Initial collection loading still uses the
existing full-record API; pagination of that route is outside this release fix.
