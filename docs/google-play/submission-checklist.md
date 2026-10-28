# Google Play submission checklist

Draft reviewed against source and Google documentation on 2026-10-28. **Not ready to submit.** This folder prepares decisions and materials; it does not record a Console submission, approval, or publication.

## Blocking product decision

Historical audit finding: the earlier bootstrap registered `hitomi.la` and `danbooru.donmai.us`; that default adult-content connection configuration was a Google Play Sexual Content policy blocker. The owner directed removal, and the bootstrap call/module have now been removed. Two targeted tests confirm empty connections on a fresh install and preservation of existing user DB records. Do not describe the current build as blocked solely by a default connection that no longer exists.

The remaining submission gate is assessment of **all actual reachable content paths**, arbitrary compatible-site connections, existing user connections, supported imports/downloads, and the final product scope. Removing host names or using generic marketing terms does not by itself establish compliance. An age rating, user-controlled Safe Mode or non-explicit screenshots is also insufficient evidence. The limited catalog exception is not presumed to apply. Confirm the public product offering for all users against the [Sexual Content policy](https://support.google.com/googleplay/android-developer/answer/9878810?hl=en) before declaring it ready.

Do not hide sites or features from reviewers, detect review accounts, change remote content after approval, or use a review-only build. Metadata and review access must describe the same product users receive. See [Deceptive Behavior](https://support.google.com/googleplay/android-developer/answer/17006354?hl=en).

## Owner decisions and Console information

- [x] Remove bundled default connections from bootstrap code; fresh-install/preserved-DB tests reported passing.
- [ ] Resolve the remaining content-policy assessment above and record the approved public product scope.
- [x] Owner confirms an **organization account**, developer verification complete, and app name registered.
- [ ] Confirm the exact Console legal/display identity, contact address/email/phone, countries, pricing and distribution eligibility; these details are not filled from repository names.
- [ ] Complete target-audience and IARC questionnaires from the entire reachable product. Do not guess a rating or select children as an audience to improve discoverability.
- [ ] Confirm content licenses, site/API terms, artwork rights and rights to screenshots/branding; retain written evidence. Public accessibility does not establish permission. See [Intellectual Property](https://support.google.com/googleplay/android-developer/answer/9888072?hl=en).
- [ ] Decide app category/tags, ads declaration and any relevant app-content declarations in Console. No ad SDK was found in the reviewed direct Flutter dependencies; inspect the final dependency/SDK inventory before answering.
- [x] The new-personal-account 12-tester/14-day production-access requirement is **not applicable to the confirmed organization account**. Internal release testing and other Console requirements remain necessary. See [testing requirements](https://support.google.com/googleplay/android-developer/answer/14151465?hl=en).

## Privacy and reviewer access

- [ ] Approve [Android privacy draft](privacy-policy-android-draft.md), publish an active public non-geofenced HTML policy URL, and link the Android policy in the app and Console. The current app links to `docs/privacy-policy.md`, which contains Apple/iCloud/Vision claims and must not stand in for this Android review. Existing public policy was not overwritten. See [User Data](https://support.google.com/googleplay/android-developer/answer/10144311?hl=en).
- [ ] Complete [Data safety investigation](data-safety-draft.md), including content sites, WebView/API handoff, Cloudflare DNS, Google Translate, OS backup, merged permissions and transitive SDKs. Do not automatically answer “No data collected/shared.”
- [ ] Complete [review instructions](review-instructions.md) with approved, lawful working content and any required third-party test credentials. No credentials are supplied in these files.

## Release artifact

- [x] A **pre-removal candidate** AAB was created and validated locally; see [artifact evidence](../../flutter/docs/android-play-bundle-1.0.0-beta.1.md) (105,241,649 bytes, bundletool 1.18.3 validation and signing-certificate comparison reported). This records artifact validation, **not policy or Console approval**.
- [x] Rebuilt the candidate with bootstrap removed and generic import UI: [beta.2 validation](../../flutter/docs/android-play-bundle-1.0.0-beta.2.md), version code 4. Any subsequent privacy/product changes require another build. This is technical validation only. Configure Play App Signing/upload-key ownership and backup separately; never commit private signing material. The universal APK is a direct-distribution artifact, not the new-app Play upload artifact. See [Android App Bundles](https://developer.android.com/guide/app-bundle).
- [x] Verified candidate package, versionName/versionCode, signing identity, ABIs and base manifest. Full transitive SDK/data-flow declarations still require completion. Source currently uses `work.nextline.tegnal` and targetSdk 37; use final artifact values, not a stale draft version number.
- [ ] The current official phone/tablet submission minimum is target API 36 from 2026-08-31. Recheck at upload. Targeting above that minimum does not establish overall compliance. See [target API requirements](https://support.google.com/googleplay/android-developer/answer/11926878?hl=en).
- [ ] Run Play internal testing/pre-launch report and test current Android/WebView versions, network failure, browser sign-in, source removal, imports, downloads, accessibility and Google Translate unavailable/manual/direct states. Record results and remaining issues.
- [ ] Check large native libraries/16 KB page-size support on the final bundle and the warnings shown by Console; this document does not certify binary compatibility.

## Listing and graphics inventory

Use [Korean](listing-ko-draft.md) and [English](listing-en-draft.md) text only after the product scope is settled. Name/short/full limits are 30/80/4,000 characters. See [store listing setup](https://support.google.com/googleplay/android-developer/answer/9859152?hl=en).

| Asset | Required preparation |
| --- | --- |
| Store icon | 512 × 512, 32-bit PNG, maximum 1,024 KB. Review full-square treatment against the current icon specification. |
| Feature graphic | 1,024 × 500, JPEG or 24-bit PNG without alpha. Needed for the listing; not created here. |
| Phone screenshots | At least two; up to eight per device type. JPEG or 24-bit PNG without alpha; dimensions 320–3,840, longest dimension at most twice the shortest. For screenshot-based promotion eligibility, prepare at least four at 1,080 × 1,920 portrait or 1,920 × 1,080 landscape. |
| Large-screen assets | If distributing to tablets/Chromebooks, prepare actual large-screen captures following the dedicated section of the current specification; do not reuse phone captures as evidence of tablet layouts. |

Specifications: [Google Play preview assets](https://support.google.com/googleplay/android-developer/answer/9866151?hl=en), [icon design](https://developer.android.com/distribute/google-play/resources/icon-design-specifications). Recheck Console validation before upload.

Existing references: `flutter/assets/branding/app-icon.png` is 1,024 × 1,024; `flutter/web/icons/Icon-512.png` is 512 × 512 but visual inspection confirmed it is the Flutter placeholder logo and must not be submitted; `docs/assets/app-icon.png` is only 152 × 152. No icon was converted or approved here. Existing internal native-parity captures are QA evidence, not cleared store assets. Record final screenshot dimensions, language, app version, artwork provenance and owner approval before use. Suggested scenes: lawful library/folders, reader controls, search, settings. No feature graphic or cleared screenshot set is ready in this folder.

## Submit gate

All blocking items require owner sign-off and evidence. Console upload, review submission and rollout remain separate actions. This preparation did not access Console, upload artifacts, publish a policy, or contact third parties.
