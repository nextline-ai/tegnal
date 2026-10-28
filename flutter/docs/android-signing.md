# Android production signing

The first public Android release is `1.0.0+2`. The owner confirmed that previous
Android APKs had not been publicly distributed and authorized a new production
key on 2026-10-28. Debug/profile and production APKs intentionally use different
certificates. A debug-signed local installation cannot be overwritten by this
production APK. Export its library before removing it if its data is needed.

## Private local material

- Keystore: `~/.local/share/tegnal/android-signing/tegnal-release.jks`
- Credentials: `~/.local/share/tegnal/android-signing/release-signing.properties`
- `flutter/android/key.properties` is an ignored symlink to that credentials file.

The directory is owner-only (0700); both private files are owner-readable and
writable only (0600). The RSA-4096 signing key has a 10,000-day validity period.
Passwords are generated locally and are not recorded in source, logs or APKs.
Keep a secure backup of the entire private directory; future direct APK updates
need this signing key. Never place that directory in a public release or commit.

## Repeatable build

From `flutter/`, with the local signing configuration available:

```sh
flutter build apk --release --no-pub
```

For the smaller ARM64 APK, use Flutter's ABI split so dependency JNI libraries
are filtered as well. Keep its version code equal to the universal APK:

```sh
env 'ORG_GRADLE_PROJECT_force-version-code-ignoring-abi=true' \
  flutter build apk --release --target-platform android-arm64 --split-per-abi --no-pub
```

Do not replace this with `--target-platform android-arm64` alone. In the current
Flutter toolchain that leaves other-ABI dependency libraries in the APK, causing
it to advertise unsupported ABIs without their Flutter runtime. Verify the
result with `aapt dump badging` and `apksigner verify --print-certs`.

The production Gradle build uses the release key, R8 code shrinking and resource
shrinking. It no longer falls back to the debug key. A release invocation without
the required signing properties fails with an explicit configuration error.
Debug/profile development remains independent of these credentials.

For a signing machine other than this workstation, securely restore the private
keystore, create an ignored `android/key.properties` containing `storeFile`,
`storePassword`, `keyAlias`, and `keyPassword`, and update the absolute keystore
path. Do not transmit the private material through chat or a public repository.
Increment the `pubspec.yaml` build number for every subsequent release.

See `android-release-1.0.0.md` for actual APK checksums, certificate fingerprint,
compatibility checks and install-verification limits for this release.
