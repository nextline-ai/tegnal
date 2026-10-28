# Android release verification — 1.0.0 (version code 2)

Two locally signed release APKs were produced from the same source and signing certificate. The ARM64 package is the smaller choice for compatible 64-bit ARM Android devices; the universal package additionally includes 32-bit ARM and x86-64. Both require Android API 24 or later.

| File | Bytes | SHA-256 | Native ABIs |
| --- | ---: | --- | --- |
| `build/releases/TEGNAL-1.0.0-android-arm64.apk` | 52,344,747 | `85427f7227b0d112f43cc6ff7651b101a42bceffd3598087bcaedd606502d9cb` | arm64-v8a |
| `build/releases/TEGNAL-1.0.0-android.apk` | 131,342,616 | `e6ae97ec5384d8f951a6481da66e39b07e203740ca4a26b02d07dbccfdb92839` | arm64-v8a, armeabi-v7a, x86_64 |

Both verify with APK Signature Scheme v2 and the same certificate SHA-256 `9b529a92de328fbbfa2da980646a0e933863f8012d353f3d5f4bf3329ead8c59`. The manifest has no `android:debuggable` attribute, so it defaults to false; `aapt` reports package `work.nextline.tegnal`, version name `1.0.0`, version code `2`, min SDK 24, and target SDK 37. Release minification and resource shrinking are enabled. Both passed `zipalign -c -P 16 4`. Static `llvm-readelf` inspection found every LOAD segment of all 21 universal native libraries aligned to at least 16 KiB; the seven ARM64 native libraries in the smaller APK are byte-identical. This is a static compatibility check, not a runtime test on a 16 KiB-page device.

A separate temporary API 37 ARM64 emulator received the universal APK as a fresh install. Its first-run flow advanced through Connect, Import, and Mode without adding a website or importing data. A typed folder draft was canceled; the app then displayed Settings and all three Reader Guide tips. The universal APK was replaced with the identically signed ARM64 APK using `install -r`; the app restarted into the existing Saved screen without repeating first-run setup. The checked log contained no Flutter error or fatal-exception lines. The temporary emulator was shut down and its AVD removed; the pre-existing emulator and its app data were not modified. Captures are under `build/release-verification/screens/`.

The new release certificate differs from the prior debug certificate, so Android cannot update an existing debug-signed installation with these APKs directly. Preserve and export any needed data before changing installations. The certificate and private signing materials are separate from the deliverable APKs; see [android-signing.md](android-signing.md) for the local signing and backup instructions.

No physical phone, actual Danbooru verification/network, 16 KiB-page runtime, installed Google Translate flow, Drive account/sync, populated-library performance, or low-end-device FPS measurement was tested in this release smoke pass. See [image-cache-comparison.md](image-cache-comparison.md) and [ui-release-performance.md](ui-release-performance.md) for the performance changes and their evidence limits.


## Additional startup and reader changes

Normal library notifications no longer rebuild `MaterialApp` and regenerate its
themes; language, appearance and first-run configuration changes still update
immediately. A retained, hidden Smart tab defers replaying the analysis history
until it becomes visible again. An already initialized library reads saved keys
at startup instead of decoding all saved payloads for a completed one-time seed.
The 1,000-record startup test observes zero full-item reads on this path, while
first-run seeding and imported-item detection remain covered. Shell, setup and
taste regression tests passed.

Reader sequences preserve caller order in linear time. Continuous reading uses
cached cumulative page heights and binary search for the visible page instead
of accumulating every previous page on each scroll callback. Visible images and
neighbor prefetch use the same original/reduced-data policy and cache key; image
sequence prefetch waits 200ms for navigation to settle, following the native app.
Known page dimensions are not remeasured unnecessarily. The reader's 26 focused
tests passed, including 10,000-item ordering, 20,000-page geometry and boundary
cases, cache-key parity, first-frame dimension resolution and debounce timing.
These are correctness and bounded-work checks, not measured physical-device FPS.
