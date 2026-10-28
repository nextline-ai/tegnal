# Android beta 4 build verification

Technical release candidates built from `1.0.0-beta.4+6` using the existing production signing configuration. No Play Console upload, submission, or device test was performed. Play app-content and policy assessment remains outstanding.

| Artifact | Bytes | SHA-256 |
| --- | ---: | --- |
| `build/releases/TEGNAL-1.0.0-beta.4-android-arm64.apk` | 52,544,857 | `2c1a5bcb57e2565f29162dba2a8d9f79e5b77a3c0b8a13c58a29732c5a66df4e` |
| `build/releases/TEGNAL-1.0.0-beta.4-android.apk` | 131,722,946 | `7f4badf03b10637093db3dbe11cb906418c9f881d1b004ef0d2b8419286deaea` |
| `build/releases/TEGNAL-1.0.0-beta.4.aab` | 105,594,905 | `56c33ed31b12405bde8a77fc1a46092cac0bf0460562262477ff4f8999776506` |

`build/releases/TEGNAL-1.0.0-beta.4-SHA256SUMS.txt` lists only the two public APKs. The AAB is a separate Play candidate.

Builds from `flutter/`:

```sh
env 'ORG_GRADLE_PROJECT_force-version-code-ignoring-abi=true' flutter build apk --release --target-platform android-arm64 --split-per-abi --no-pub
flutter build apk --release --no-pub
flutter build appbundle --release --no-pub
```

- APK manifests and bundletool manifest identify package `work.nextline.tegnal`, version name `1.0.0-beta.4`, version code 6. APK minimum SDK is 24 and target SDK is 37; the APK manifest has no `debuggable` attribute.
- APKs pass `apksigner verify` with v2 signing, and AAB passes `jarsigner -verify`. All certificates match the existing production certificate, SHA-256 `9B:52:9A:92:DE:32:8F:BB:FA:2D:A9:80:64:6A:0E:93:38:63:F8:01:2D:35:3F:3D:5F:4B:F3:32:9E:AD:8C:59`. Java 25 reports self-signed certificate, absent timestamp, and JarInputStream ZIP-entry ordering warnings for the AAB.
- ZIP CRC and Android bundletool 1.18.3 validation pass. ARM64 APK contains arm64-v8a; universal APK and AAB contain arm64-v8a, armeabi-v7a, and x86_64. APKs pass `zipalign -c -P 16 4`; a static ELF program-header check of all 21 universal APK libraries found all 66 LOAD segments have alignment at least 16 KiB. This does not replace device or Play testing.
- Archive entry-name inspection found no `user_data/`, source database filename, `key.properties`, `.keystore` or `.jks` entries. This is a targeted filename check, not a general proof about arbitrary embedded data.

- The universal APK Korean localization asset contains the current “다른 만화 뷰어 데이터 가져오기” import label.
