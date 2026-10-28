# Android Play bundle: 1.0.0-beta.1

This is a technically validated bundle candidate, not a claim of Play review readiness. The default connections to adult-content sites require a separate Play policy review. No upload or publication was performed.

- Build: `flutter build appbundle --release --no-pub`, from `flutter/`, with the existing production signing configuration; version `1.0.0-beta.1+3`.
- Artifact: `build/releases/TEGNAL-1.0.0-beta.1.aab`, 105,241,649 bytes; SHA-256 `60e0b1dbab53ff2b64cddd96c50388a42b85534daeaa156f8d2eca2ca065c736`.
- Production signing certificate SHA-256: `9B:52:9A:92:DE:32:8F:BB:FA:2D:A9:80:64:6A:0E:93:38:63:F8:01:2D:35:3F:3D:5F:4B:F3:32:9E:AD:8C:59`, matching the existing beta APK certificate. `jarsigner -verify -certs` returned success. Java 25 reported the self-signed certificate, absent timestamp, and differing JarInputStream ZIP-entry ordering warnings; standard JarFile verification passed.
- ZIP CRC verification passed; `BundleConfig.pb`, base manifest and dex entries are present. Native libraries include arm64-v8a, armeabi-v7a and x86_64.
- Android bundletool 1.18.3 `validate` returned success. Java 25 emitted runtime deprecation warnings.

No Play Console processing, Play-generated APK install, device test, or content-policy approval was performed for this bundle.
