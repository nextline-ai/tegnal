# Android bundle, signing and store asset inventory

Snapshot: 2026-10-29. This is preparation material, not a Play submission or a statement that content-policy review is complete. No asset, bundle, certificate or key was uploaded during this inventory. Store artwork and claims still need owner review, rights confirmation and current-product verification.

## Existing bundle and APKs

- The locally built Play candidate is `flutter/build/releases/TEGNAL-1.0.0-beta.5.aab` (105,593,649 bytes). Its SHA-256, rechecked against the file, is `93f98f609fec3dd2cca854ba0d9dc5a6661444182369829e09a03081d47d94d5`. Its package is `work.nextline.tegnal`, version name `1.0.0-beta.5`, version code **7**. These build outputs are local and may need to be rebuilt if unavailable or if production code changes.
- The AAB signature certificate SHA-256 in the [build report](../../flutter/docs/android-play-bundle-1.0.0-beta.5.md) is `9B:52:9A:92:DE:32:8F:BB:FA:2D:A9:80:64:6A:0E:93:38:63:F8:01:2D:35:3F:3D:5F:4B:F3:32:9E:AD:8C:59`, matching the direct beta APKs. The report records bundletool validation, signature verification, version, ABI and limitations. This is the certificate that signed this AAB, **not proof of the eventual Play-distributed app-signing certificate**.
- The ARM64 and universal APKs are direct-distribution artifacts; the AAB is the bundle candidate for Play, which generates device-specific APKs. Do not upload the checksum file or direct APK as a substitute for the AAB. Current APK checksums are in `flutter/build/releases/TEGNAL-1.0.0-beta.5-SHA256SUMS.txt`.

## Signing decision before first Play release

Android accepts an update when package identity and signing certificate match, or a valid signing-key rotation is provided; Google Play also uses a higher version code to identify an available update. A Play-generated app-signing key different from the existing direct-APK key can therefore prevent those existing installations updating directly from Play. Matching the *upload* certificate alone does not solve that: the app-signing key signs APKs delivered to devices. See [Android app updates](https://developer.android.com/google/play/app-updates) and [Play App Signing](https://developer.android.com/studio/publish/app-signing).

Before configuring the first release, the owner should decide whether direct APK users must receive Play updates without reinstalling. If yes, inspect the Console's available **Change app signing key** options for securely providing the existing app-signing key, and compare the resulting Play **app signing certificate** fingerprint with the installed APK certificate above. Follow Google's current official Console instructions and its encrypted key-transfer workflow; never commit, paste, attach or expose private key material. Choosing a separate upload key can reduce risk, but record and back up both roles separately. If the owner chooses a Google-generated different app-signing key, assess the resulting incompatibility and migration before rollout; a future version code alone will not fix mismatched signing. Verify actual Console state and Play-generated artifacts before making compatibility claims. Google's [App Bundle FAQ](https://developer.android.com/guide/app-bundle/faq) describes same-key and Play-generated distribution options. No signing option was selected in this task.

## Image inventory

Google's [preview-asset requirements](https://support.google.com/googleplay/android-developer/answer/9866151?hl=en) specify a 512 × 512 PNG app icon (32-bit, maximum 1,024 KB); feature graphic 1,024 × 500 JPEG or 24-bit PNG without alpha; and at least two screenshots as JPEG or 24-bit PNG without alpha, with dimensions from 320 to 3,840 pixels and longest side at most twice the shortest. Requirements and listing eligibility can change; recheck the live Console before upload.

| Existing file | Observed properties and assessment |
| --- | --- |
| `flutter/assets/branding/app-icon.png` | 1,024 × 1,024, 8-bit RGB PNG, 50,826 bytes; inspected image is the TEGNAL wordmark. Useful source, but wrong dimensions for the final 512 × 512 store icon; full-square presentation, rights and final exported file still need review. |
| `flutter/web/icons/Icon-512.png` | 512 × 512 RGB PNG, 8,252 bytes, but inspected image is the Flutter placeholder, not TEGNAL branding. Do not submit it. |
| `design-output/screenshot/info_Android.jpg` | 1,071 × 1,023 JPEG, 419,156 bytes, no alpha. Promotional composition with a phone mockup and “Cloud BackUP support”; not 1,024 × 500, so not a ready feature graphic. The image appears to show iPhone-style UI, and the cloud claim must be verified against Android: `AppFeatures.googleDriveSyncEnabled` is currently `false`. Do not represent disabled functionality as available. |
| `design-output/screenshot/Frame 1.png` through `Frame 5.png` | Each 1,206 × 2,622, 8-bit RGBA PNG: longest side is about 2.17 times shortest, exceeding the screenshot aspect limit; PNG contains an alpha channel. Frame 1 explicitly says “Viewer for iPhone”, Frame 2 says “iCloud BackUP”, Frame 4 says “Apple intelligence”, and Frame 5 is primarily a company logo; Frame 3 also depicts iPhone-styled UI. These are not ready Android store screenshots. |
| `flutter/assets/branding/splash_dark.jpg`, `splash_light.jpg` | Each 886 × 1,920 JPEG without alpha; splash assets, not a verified feature graphic or an approved set of Android screenshots. |
| `flutter/assets/branding/reader-guide.png` | 1,024 × 1,536 RGB PNG; an in-app reader guide, not a checked Android store screenshot. |
| `flutter/assets/branding/developer-github-*.png`, `developer-discord-*.png` | 1,200 × 370 (Korean) or 1,200 × 401 (English), RGBA PNG; developer links, not store icon/feature graphic candidates. |

The five frames are visual inspection references only; they are neither evidence of Android functionality nor cleared artwork. No suitable feature graphic, final 512 × 512 TEGNAL store icon, or verified set of at least two Android screenshots has been established by this inventory. Create or approve accurate assets separately, including review of image licenses and any product claims. No image was edited or generated.
