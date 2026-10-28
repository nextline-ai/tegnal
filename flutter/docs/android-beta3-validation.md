# Android beta 3 validation

Version: `1.0.0-beta.3+5`. This update adds the supported Android bookmark database migration behind **Import Data from Other Manga Viewers** (`다른 만화 뷰어 데이터 가져오기`), keeps older formats under Settings, and improves image-mode navigation.

## Import

See [mapping and limitations](android-bookmark-import.md). Synthetic regression coverage includes immutable preview, merging, reimport, cancellation, transaction rollback, existing edits, native JSON restoration and worker-isolate responsiveness. A separate read-only validation of the supplied database checked unchanged source bytes and stable counts after repeat import. Private content and the source database are not repository fixtures or release assets.

UI tests cover file extensions, preview/confirmation, successful import, cancelled import, rejected incompatible files and the separate legacy path. Korean onboarding captures were visually inspected. English, Korean and Japanese locale-key checks passed.

## Image-mode navigation

The current post's two preceding and two following neighbors are scheduled nearest-first with at most two concurrent speculative jobs. Obsolete queued jobs are discarded after navigation. The manifest cache and prepared-provider registry each retain at most five entries; Flutter's decoded-image cache remains responsible for pixel eviction.

Prefetch and visible rendering use the same media-selection policy, request headers and decode dimensions. A completed prepared image is reused only while its image-cache entry is present and the session revision, URL, page headers and decode size match. Headers are refreshed asynchronously; changed sessions invalidate prepared entries. Cached manifests are consumed synchronously.

Regression coverage decodes real synthetic PNGs and checks that next/previous navigation does not show a loading indicator in the first frame or repeat manifest resolution. Cookie reset invalidation is tested. These are deterministic regression checks, not real-device frame-time or live-network benchmarks. Network delays, videos, evicted images and unfinished prefetch still require normal loading.

## Final automated checks

`flutter analyze --no-pub` passed with no issues. The complete `flutter test --no-pub` run passed 359 tests with two skipped tests. One onboarding replay test initially tapped an off-screen row behind the dock; the test now scrolls that row to the center before tapping, retains its route/dock assertions, and the complete rerun passed. Production code was unchanged by this test correction.

## Distribution

[Artifact verification](android-play-bundle-1.0.0-beta.3.md) records signed APK/AAB checks. Play Console upload, internal testing, pre-launch report and review submission remain separate pending steps; see the [submission checklist](../../docs/google-play/submission-checklist.md).
