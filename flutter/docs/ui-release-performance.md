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

Initial collection loading still uses the existing full-record API; pagination
of that route is outside this release fix.

# Android device measurements — 2026-10-31

Measured with `tool/perf_bench.dart` in profile mode on one Android 15 phone
(Snapdragon 888 class, 7 GB RAM, 120 Hz) over its live connection, using public
Safebooru thumbnails. Network figures are single runs and vary with the network.

| Measurement | Before | After |
| --- | --- | --- |
| 40 thumbnails, cold | 7,770 ms | 2,332–2,535 ms |
| 40 thumbnails after restart | refetched from network | 23 ms from disk |
| Reader page requested behind 23 thumbnails | 1,328 ms | 757–817 ms |
| Longest UI gap while images arrive | 19 ms | 7–9 ms |
| Reading-position write, p50 | 0.66 ms | 0.04 ms |

Image delivery, not drawing, was the limiting cost. Raster time stayed under the
8.3 ms budget for almost every frame of a synthetic 2-column grid, and no pass
lost a meaningful number of frames (about 2,150 frames in 18 s).

The floating dock's blur was kept. It adds about 1.3 ms of raster time, but its
passes sometimes ran near the budget (5–246 of about 2,150 frames over budget,
against 0–2 without blur). This device dropped no meaningful number of frames,
yet weaker GPUs have less margin, so re-measure there before relying on it.

A 122 KiB catalog response takes about 6 ms to decode on this device, most of a
120 Hz frame, so responses over 16 KiB are decoded off the UI thread. Not
measured: lower-end hardware, and scrolling the real app with live images.
