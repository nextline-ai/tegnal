# Android beta 3 build verification

Technical release candidates built from `1.0.0-beta.3+5` using the existing production signing configuration. No Play Console upload, submission, or device test was performed. Play app-content and policy assessment remains outstanding.

| Artifact | Bytes | SHA-256 |
| --- | ---: | --- |
| `build/releases/TEGNAL-1.0.0-beta.3-android-arm64.apk` | 52,347,299 | `fe933872971910ff68e0345c0b64eabde86e5a0a1f397e1022e361e07abc4e2a` |
| `build/releases/TEGNAL-1.0.0-beta.3-android.apk` | 131,476,240 | `221ddc32adf35b93364e79332b96a72c49f6d83768413b5bfc1edded56402774` |
| `build/releases/TEGNAL-1.0.0-beta.3.aab` | 105,405,381 | `15f2967d1e658f4791b2de78daa2d522e2096b0c83e61bb23eb9f034578604fa` |

`build/releases/TEGNAL-1.0.0-beta.3-SHA256SUMS.txt` lists only the two public APKs. The AAB is a separate Play candidate.

Builds from `flutter/`:

```sh
env 'ORG_GRADLE_PROJECT_force-version-code-ignoring-abi=true' flutter build apk --release --target-platform android-arm64 --split-per-abi --no-pub
flutter build apk --release --no-pub
flutter build appbundle --release --no-pub
```

- APK manifests and bundletool manifest identify package `work.nextline.tegnal`, version name `1.0.0-beta.3`, version code 5. APK minimum SDK is 24 and target SDK is 37; the APK manifest has no `debuggable` attribute.
- APKs pass `apksigner verify` with v2 signing, and AAB passes `jarsigner -verify`. All certificates match the existing production certificate, SHA-256 `9B:52:9A:92:DE:32:8F:BB:FA:2D:A9:80:64:6A:0E:93:38:63:F8:01:2D:35:3F:3D:5F:4B:F3:32:9E:AD:8C:59`. Java 25 reports self-signed certificate, absent timestamp, and JarInputStream ZIP-entry ordering warnings for the AAB.
- ZIP CRC and Android bundletool 1.18.3 validation pass. ARM64 APK contains arm64-v8a; universal APK and AAB contain arm64-v8a, armeabi-v7a, and x86_64. APKs pass `zipalign -c -P 16 4`; a static ELF program-header check of all 21 universal APK libraries found all 66 LOAD segments have alignment at least 16 KiB. This does not replace device or Play testing.
- Archive entry-name inspection found no `user_data/`, source database filename, `key.properties`, `.keystore` or `.jks` entries. This is a targeted filename check, not a general proof about arbitrary embedded data.
