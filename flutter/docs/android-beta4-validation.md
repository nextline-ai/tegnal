# Android beta 4 validation

Version: `1.0.0-beta.4+6`. The complete Flutter test run passed 381 tests, with two opt-in capture tests skipped. `flutter analyze --no-pub` and `git diff --check` passed.

## Automatic metadata enrichment

Successful SQLite, legacy and JSON imports request enrichment of missing manga covers, titles and tags. The existing native queue behavior is the reference: newest saved works first, one work/cover at a time, a 150 ms interval and foreground-only scheduling. Progress notifications are throttled. Missing source connections, pause/resume and failures have explicit notice states, including onboarding. Large batches show the native heat/battery notice; the text remains accessible at large font sizes.

The queue is single-flight, preserves existing titles/tags/artists, notes and folder membership, and does not recreate a work deleted during a request. Repeated connection failures stop after three consecutive failures; isolated HTTP 404/410 responses allow later works to proceed. Incomplete cover requests are recorded before awaiting them so interruption can be retried. Cover warming uses the same 2 MiB request limit, Referer and session revision as displayed thumbnails, with the existing session-scoped disk cache. Remote cover URLs remain in portable library records.

Synthetic tests cover connection-dependent resume, overlapping requests, pause/resume, background interruption, stored retry state, deletion during fetching, preservation of edits, repeated failures and narrow/large-text notices. Network access follows the user's configured source; this is not a live-site or physical-device performance benchmark.

## Community settings

Discord and GitHub buttons are rasterized at 1200 pixels from the native app's existing outlined SVG assets. The reproducible conversion is `tool/generate_community_buttons.cjs`; source assets and unrelated existing PNGs remain unchanged. Both modes use the native destinations, matching English/Korean buttons and accessible link labels.

Invitation eligibility no longer uses the old permanent-dismiss preference. Display is recorded when the banner is actually visible, setting the next presentation to three days later. Dismissing it schedules seven days. Tests cover the cadence, translated buttons and destinations. Captures were visually inspected, and both bounds and tap tests verify that the final GitHub button can be scrolled fully above the dock.

## Reader dismissal

The reader uses a shared non-opaque route so its previous screen is visible during dismissal. A downward drag translates the reader surface; a cancelled gesture returns with a spring, while a completed gesture moves off-screen before popping without a second route exit animation. The reduced-motion setting bypasses motion. Zoom, multi-touch, controls and continuous-reader exit-zone restrictions remain covered by tests.

Synthetic frame checks cover drag, restoration, completed dismissal and reduced motion, alongside prior navigation/prefetch regressions. Mid-drag and restored captures were inspected. No new image copies or decoding are introduced by the transition; the previous route remains mounted. No physical-device frame-rate claim is made.

## Distribution

See [signed artifact verification](android-play-bundle-1.0.0-beta.4.md). Play Console submission and pre-launch testing remain pending; the updated [submission checklist](../../docs/google-play/submission-checklist.md) and privacy/data-flow drafts describe the automatic source requests.
