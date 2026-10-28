# Android beta verification — 1.0.0-beta.1 (version code 3)

Two APKs were built from the frozen beta source and signed with the same certificate as the prior 1.0.0 release. ARM64 is the smaller download for compatible 64-bit ARM Android devices. The universal APK additionally supports 32-bit ARM and x86-64. Both require Android API 24 or later.

| File | Bytes | SHA-256 | Native ABIs |
| --- | ---: | --- | --- |
| `build/releases/TEGNAL-1.0.0-beta.1-android-arm64.apk` | 52,344,823 | `3f7a8a4d67b24f887fd52bcb2d975f078c5da54df4922ae722f69fde1d5f345d` | arm64-v8a |
| `build/releases/TEGNAL-1.0.0-beta.1-android.apk` | 131,359,076 | `8367873799bce8e931509c4e8c94dd7a28b75eec9fbd02c242f95689459cf866` | arm64-v8a, armeabi-v7a, x86_64 |

`apksigner` verified the same single v2 signer on both APKs; its certificate SHA-256 is `9b529a92de328fbbfa2da980646a0e933863f8012d353f3d5f4bf3329ead8c59`, matching version 1.0.0. `aapt` reports package `work.nextline.tegnal`, version name `1.0.0-beta.1`, version code `3`, min SDK 24 and target SDK 37. The manifest omits `android:debuggable`, which defaults to false. Both archives passed `zipalign -c -P 16 4`. Static `llvm-readelf` inspection found all LOAD segments of the universal APK's 21 native libraries aligned to at least 16 KiB; the ARM64 APK's seven native libraries are byte-identical. This does not substitute for a runtime test on a 16 KiB-page device.

A newly created, isolated API 37 ARM64 emulator was used for the upgrade check. The previous signed 1.0.0/code 2 APK was installed and a synthetic Images folder named `BetaFixture` created. The beta ARM64 APK was installed over it with `install -r`; version code 3 launched with that folder still present and without an Images Unfiled tile. Comics retained its Unfiled tile. One Danbooru source and one hitomi.la source appeared, and each was still displayed once after force-stop and restart. The inspected log contained no Flutter error or fatal-exception lines. The temporary emulator and its AVD were then removed; the existing emulator and physical phone were untouched. Captures are under `build/beta-verification/screens/`.

The device check used an empty preexisting folder and a single seeded Booru source; it did not exercise populated folders across multiple Booru sites or actual website connectivity. Source deletion and no-reseeding behavior require the associated automated tests. No physical-device, account, Google Drive, installed Google Translate, 16 KiB-page runtime, or low-end performance validation was performed in this pass. The earlier 1.0.0 release verification is recorded separately in [android-release-1.0.0.md](android-release-1.0.0.md); key management remains in [android-signing.md](android-signing.md).
