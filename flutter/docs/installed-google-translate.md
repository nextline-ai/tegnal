# Installed Google Translate handoff

TEGNAL's reader Translate action uses the installed Android Google Translate app (`com.google.android.apps.translate`). TEGNAL does not perform OCR, call a translation API, install a model or application, or select a substitute translation service.

## Supported routes

1. Query the installed, enabled Google Translate package and resolve its exported `ACTION_SEND` handler for `image/png`.
2. If supported, capture the current visible reader content (excluding quick-menu controls) as a PNG bounded to 2048 pixels on its longest edge. Share a private temporary file through a narrowly scoped `FileProvider` content URI, `ClipData`, and temporary read permission, directed only to the resolved Google Translate component.
3. Some installed Google Translate versions do not register an image share handler. On Android 10+, the reader then offers an explicit **Save Image and Open Google Translate** action. Only after this choice does it save the visible image to `Pictures/TEGNAL` through MediaStore and open the installed app. The user chooses **Camera → All Images** inside Google Translate.
4. Missing packages, unsupported handlers/platform versions, invalid images, and failed launches produce a clear message. No store page, application install, or model download opens automatically.

The manual fallback intentionally leaves the user-selected saved image in their gallery. Private direct-share cache files are pruned after 24 hours on subsequent use. Neither route grants access to the library database, accounts, source credentials, or unrelated files.

Google Translate controls translation, language choices and its own network behavior. This handoff does not promise an offline translation result or that a receiving app successfully translated the content merely because Android launched it.

## Why capability detection is necessary

Google's public help documents image import inside the Translate app, including **Camera → All Images**. It does not establish a third-party image-translation API contract. Android's standard image-sharing mechanism can be used only when the installed package declares a matching exported handler. The bridge checks this at runtime rather than assuming support or invoking an undocumented private activity/extra.

Primary references reviewed:

- [Google Translate: translate text in images](https://support.google.com/translate/answer/6142483?hl=en&co=GENIE.Platform%3DAndroid)
- [Android: send binary content to another app](https://developer.android.com/training/sharing/send)
- [Android: securely share files through content URIs](https://developer.android.com/training/secure-file-sharing)
- [Android: package visibility declarations](https://developer.android.com/training/package-visibility/declaring)
- [Android: app-owned media and scoped storage](https://developer.android.com/training/data-storage/shared/media)

## Google Drive temporary disablement

`AppFeatures.googleDriveSyncEnabled` is currently false. Bootstrap constructs no Drive auth/sync controller. A disabled `DriveSyncController` also refuses initialization, sign-in, background restoration, sync, and preference mutation. Existing account records, sync state, recovery files and the user's stored connected/automatic-sync choices remain intact. JSON library backup/import remains available. Tests explicitly opt the controller into enabled operation when testing its retained implementation.

## Verification boundaries

Method-channel tests cover direct image handoff, missing/unsupported package results, explicit manual import, failures and desktop behavior. Reader widget tests verify that declining the manual route writes nothing and that the direct route sends a captured PNG rather than reader chrome. The Drive regression verifies zero auth restore/connect/disconnect calls and no sync-state directory creation while disabled.

These tests validate TEGNAL's routing. A real installed Google Translate build is needed to verify its declared image handler and its own translation UI/network behavior. An emulator without Google Translate can verify the missing-app branch only.
