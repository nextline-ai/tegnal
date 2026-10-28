# Android beta 5 — resource and category audit

Target: `1.0.0-beta.5+7`. This change addresses four concrete source/resource findings. It does not certify Google Play eligibility or assert a known keyword-blocking rule.

## Changes

1. Removed the built-in numeric-to-name category table from the document manga adapter. Requests without a type filter now use the server's default scope. Numeric `type:` filters use category IDs; named filters require matching labels actually supplied by the server. Unknown labels fail explicitly rather than broadening the query. Negative filters use server IDs without inventing a universal category list. Existing saved work and backup data are not rewritten.
2. Removed obsolete third-party importer branding from generated English, Korean and Japanese localization keys and values. Generic UI identifiers and importer method names replace internal names that are unrelated to stored-data compatibility. An explicit retired-copy catalog, with reasons and a check against active Dart references, prevents shared Apple translations from reintroducing retired Flutter copy. The Apple catalog remains unchanged.
3. Replaced the rating example in block-rule help with neutral tag/ID/artist examples. The block parser still accepts existing rating rules; removing help text does not disable a user's existing exclusions.
4. Replaced the display name of the old safety setting with **Image Rating Filter** and removed instructions to disable it to access another mode. The copy explains default image-search ratings and unsupported source types. Existing persisted settings and the manga-mode restriction remain intact. This is a search filter, not an age-verification or content-safety guarantee.

The fixed-category language-exception behavior was also removed. Language searches now stay strict instead of adding hard-coded visual categories. Its old persisted preference is retained for data compatibility but the unsupported toggle is not offered. This is an intentional behavior change, not an equivalent rename.

## Compatibility boundaries

For document sources that return only numeric categories, a previous named filter such as `type:manga` cannot be resolved until the source supplies a corresponding label. Use the source's numeric category ID. The indexed protocol continues to accept category terms provided by its server; remote content labels are not censored or rewritten. Legacy backup schemas, source-engine identifiers and user-entered data remain compatible.

The source adapters and user-selected external connections still exist. Removing local category names and obsolete resource copy does not remove all access to external content or resolve the separate product/content policy assessment.

## Artifact audit

`tool/audit_release_strings.py` inspects localization keys/values, other asset JSON, Flutter `libapp.so`, DEX and compiled Android resources separately. Its exact-pattern inventory distinguishes retired import branding/category/help text from source-engine compatibility identifiers. It reports only pattern names, counts and archive entry paths, never matching personal content. It does not encode, split or hide strings to evade review.

Flutter's Android release Dart code is AOT-compiled to native machine code, so checking only DEX would miss relevant app strings. This is why the audit includes the Flutter native library and JSON assets. See the [Flutter FAQ](https://docs.flutter.dev/resources/faq).

Google's published content policy concerns actual content and functionality. No official evidence of a blanket automatic rejection for the reported individual tokens was established. See [Inappropriate Content](https://support.google.com/googleplay/android-developer/answer/9878810?hl=en). Zero matches in this limited scan is not proof of compliance or absence of all possible encodings.

Build evidence and final validation counts are recorded with [beta 5 artifacts](android-play-bundle-1.0.0-beta.5.md). Play Console submission and live-source/device validation are separate from these checks.

## Regression validation

- `flutter analyze`: no issues.
- `flutter test`: 392 passed, 2 skipped (existing opt-in UI capture cases).
- Localization generator `--check`: 1,454 matching keys in English, Korean and Japanese.
- Localization generator unit tests: 4 passed.
- Device/network behavior and Play Console submission were not tested in this pass.
