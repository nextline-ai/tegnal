# TEGNAL Android (Flutter)

This folder is the Android version of TEGNAL. It is published on Google Play as `work.nextline.tegnal`. The rebuild plan is in [REBUILD.md](REBUILD.md).

## Never change (Google Play updates depend on these)

- **App ID:** `applicationId` and `namespace` in `android/app/build.gradle.kts` stay `work.nextline.tegnal`. The Kotlin package path `android/app/src/main/kotlin/work/nextline/tegnal/` stays as well. A different ID makes it a different app, and existing installs can no longer update.
- **Release signing:** keep the `releaseSigning` / `signingConfigs` block in `android/app/build.gradle.kts`.
  - `android/key.properties` is a symbolic link ignored by git that points to `~/.local/share/tegnal/android-signing/release-signing.properties`. Never delete, regenerate or commit it.
  - Never touch the keystore `~/.local/share/tegnal/android-signing/tegnal-release.jks`.
  - The release certificate's SHA-256 is `9b529a92de328fbbfa2da980646a0e933863f8012d353f3d5f4bf3329ead8c59`. Check the release APK with `apksigner verify --print-certs`.
  - Details are in [docs/android-signing.md](docs/android-signing.md).
- **Version code:** the `+N` at the end of `version:` in `pubspec.yaml`.
  - It must be greater than the last code uploaded to Google Play. The last value in this repository is 8, but always check the Play Console before uploading.
  - Increase it for every upload, and never lower it.
- **Shared identity:**
  - **App name:** `TEGNAL` (`android:label`).
  - **Icon:** generated from `tool/symbol.jpg` by `tool/sync_app_icons.py`.
  - **Splash screens:** in `assets/branding/` and `android/app/src/main/res/`.
- **SDK levels:** `minSdk` 24. Do not lower `targetSdk` (currently 37); keep it at or above Google Play's requirement.
- **Google Drive sign-in:** the OAuth clients are tied to the package name and the signing certificate's SHA-1. See `../docs/google-drive-setup.md`.
- **Play policy documents:** `../docs/privacy-policy-android.md` is linked from the Play listing. When what the app collects changes, update this document too.

## Working rules

- **The native app is the reference.** `../native-ios/` is the reference for features, behavior, wording and screens. Do not change the native app to match Android.
- **No site names in code:** website names and addresses must never appear in code, tests or strings. Recognize sites only by page structure and response fields, as the native app does.
- **Commit or push only when asked.**
- **Test what changed:** run only the tests related to a change, and report exactly what a check verified and what it did not.
