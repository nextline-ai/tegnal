# Android beta 5 build verification

Technical release candidates built from `1.0.0-beta.5+7` using the existing production signing configuration. No Play Console upload, submission, or device test was performed. Play app-content and policy assessment remains outstanding.

| Artifact | Bytes | SHA-256 |
| --- | ---: | --- |
| `build/releases/TEGNAL-1.0.0-beta.5-android-arm64.apk` | 52,555,069 | `52f562065145549210dcfbc6d78a99a04d957f2972b3f899c87090f5abafd01a` |
| `build/releases/TEGNAL-1.0.0-beta.5-android.apk` | 131,733,158 | `b9e34505f0499908aea5a664c01e5d37feeb6b6044f6b3ae40abbad5683b2af1` |
| `build/releases/TEGNAL-1.0.0-beta.5.aab` | 105,593,649 | `93f98f609fec3dd2cca854ba0d9dc5a6661444182369829e09a03081d47d94d5` |

`build/releases/TEGNAL-1.0.0-beta.5-SHA256SUMS.txt` lists only the two public APKs. The AAB is a separate Play candidate.

Builds from `flutter/`:

```sh
env 'ORG_GRADLE_PROJECT_force-version-code-ignoring-abi=true' flutter build apk --release --target-platform android-arm64 --split-per-abi --no-pub
flutter build apk --release --no-pub
flutter build appbundle --release --no-pub
```

- APK manifests and bundletool manifest identify package `work.nextline.tegnal`, version name `1.0.0-beta.5`, version code 7. APK minimum SDK is 24 and target SDK is 37; the APK manifest has no `debuggable` attribute.
- APKs pass `apksigner verify` with v2 signing, and AAB passes `jarsigner -verify`. All certificates match the existing production certificate, SHA-256 `9B:52:9A:92:DE:32:8F:BB:FA:2D:A9:80:64:6A:0E:93:38:63:F8:01:2D:35:3F:3D:5F:4B:F3:32:9E:AD:8C:59`. Java 25 reports self-signed certificate, absent timestamp, and JarInputStream ZIP-entry ordering warnings for the AAB.
- ZIP CRC and Android bundletool 1.18.3 validation pass. ARM64 APK contains arm64-v8a; universal APK and AAB contain arm64-v8a, armeabi-v7a, and x86_64. APKs pass `zipalign -c -P 16 4`; a static ELF program-header check of all 21 universal APK libraries found all 66 LOAD segments have alignment at least 16 KiB. This does not replace device or Play testing.
- Archive entry-name inspection found no `user_data/`, source database filename, `key.properties`, `.keystore` or `.jks` entries. This is a targeted filename check, not a general proof about arbitrary embedded data.



## Limited release string inventory

Each artifact was scanned with `tool/audit_release_strings.py`; the three `.string-audit.txt` files next to the artifacts retain per-path counts without printing matched content. For the listed exact patterns, all three artifacts had zero matches in locale JSON keys and values for import brands, the former category tokens, explicit block-rule example, and Safe Mode disable recommendation. The category and old example/recommendation patterns also produced no matches in the scanned AOT, DEX or resource binary text. These are exact-pattern findings, not proof of absence of every variant or policy compliance.

Each ABI's AOT library has 2 import-brand pattern matches; targeted counting identifies both as the historical `anime-boxes` spelling. The source uses that identifier for existing imported-source identity and database compatibility (`lib/data/legacy_import.dart` and `lib/data/library_store.dart`); it is not evidence by itself of visible UI text. Existing engine brands remain: 12 matches per AOT ABI and 9 in each locale JSON key and value. Some old localization entries remain packaged, so their presence must not be described as brand-free or conclusively non-visible without reviewing the call sites. Compatibility engine identifiers remain necessary.
