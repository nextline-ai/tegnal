# Android Play bundle: 1.0.0-beta.2

This is a technically validated candidate, not a claim of Play review readiness. App-content and Play policy review remain outstanding. No upload or publication was performed.

- Build: `flutter build appbundle --release --no-pub`, from `flutter/`, using the existing production signing configuration.
- Artifact: `build/releases/TEGNAL-1.0.0-beta.2.aab`, 105,211,341 bytes; SHA-256 `8781bf0378928536afcdc78fc7ca77dbe484c3dc8224cc7d2c97dbb46be7199f`.
- Bundletool manifest: package `work.nextline.tegnal`, version name `1.0.0-beta.2`, version code `4`.
- Signing certificate SHA-256: `9B:52:9A:92:DE:32:8F:BB:FA:2D:A9:80:64:6A:0E:93:38:63:F8:01:2D:35:3F:3D:5F:4B:F3:32:9E:AD:8C:59`, matching the existing beta APK certificate. `jarsigner -verify -certs` returned success; Java 25 reported self-signed certificate, absent timestamp, and JarInputStream ZIP-entry ordering warnings.
- ZIP CRC verification passed; `BundleConfig.pb`, base manifest and dex entries are present. Native libraries include arm64-v8a, armeabi-v7a and x86_64.
- Android bundletool 1.18.3 `validate` returned success. Java 25 emitted runtime deprecation warnings.

No Play Console processing, Play-generated APK install, device test, or content-policy approval was performed for this bundle. The older beta 1 bundle is retained for history and contains the former bundled site connections; it is not the current submission candidate.
