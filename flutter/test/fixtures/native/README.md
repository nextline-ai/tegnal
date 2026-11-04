# Native backup fixtures

Golden backup files written by the native iOS app's own Swift code, so the Dart
port can be tested against byte-for-byte native output.

**Every value in these files is synthetic test data.** Server addresses use
`*.example` hosts only; no real library, account or site data is included.

## How they were generated

- Native source: commit `c95a18e7c9258fb9ab48a5bb5f52fa75fceff67c` (`native-ios/`, unmodified).
- A temporary XCTest, `TEGNALTests/ZZNativeFixtureExportTests/testWriteNativeBackupFixtures`,
  was added, the project regenerated with `xcodegen generate --spec native-ios/project.yml`, and run with:

  ```sh
  TEST_RUNNER_FIXTURE_DIR=<this directory> xcodebuild -project native-ios/TEGNAL.xcodeproj \
    -scheme TEGNAL -testPlan Unit -destination 'platform=iOS Simulator,id=<device>' \
    -parallel-testing-enabled NO -enableCodeCoverage NO \
    -only-testing:TEGNALTests/ZZNativeFixtureExportTests/testWriteNativeBackupFixtures test
  ```

  The test file was then deleted and the generated project files restored with `git checkout`.
- Device: simulator "TEGNAL Recap (Claude)", iOS 27.0 runtime (24A434), Xcode 27.2 (27B52).
- Stores: `AppDatabase.inMemory()` (comics) and `BooruStore()` (images, in memory; challenges live in it too).

## Files

| File | Produced by |
| --- | --- |
| `library_backup.json` | `LibraryBackup.capture(database:images:).encoded()`, format `tegnal-library` |
| `comics_backup_v2.json` | `MangaLibraryBackup.export(database:)` (comics-only, version 2, no `format` key) |
| `comics_backup_legacy_group.json` | Hand-written version 1 comics backup whose folders use `legacy_group_id` instead of `source_group_id`. Native `LibraryBackupImport.decode` accepts it (results in `restore_expectations.json`) |
| `image_backup.json` | `BooruStore.exportBackup().encoded()`, format `tegnal-image-library` |
| `image_backup_historical.json` | The same bytes with the format replaced by `number-memo-image-library` (accepted on import, normalised to `tegnal-image-library`) |
| `challenge_backup.json` | `ChallengeBackup(games: ChallengeStore(images).definitions()).encoded()` |
| `restore_expectations.json` | Database state after `LibraryBackupImport.decode(library_backup.json).restore(...)` into fresh stores, plus decode/restore results for the other files. A second restore gave identical state (`after_second_restore_identical: true`) |

Fixed values were used wherever the API allows (bookmark dates, `used_at`, `savedAt`, ids).
These still vary between runs: `exportedAt`/`exported_at`, folder `created_at`, artist
`bookmarked_at`, comics folder sync ids (random UUIDs, never exported; replaced by
`<sync:FolderName>` placeholders in `restore_expectations.json`), and the order of comics
`folder_rules` (sorted by the random sync-id row key).

## Encoding notes

- `library_backup.json` and `challenge_backup.json` use `[.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]`.
  `comics_backup_v2.json` and the image backups use `[.prettyPrinted, .sortedKeys]`, so `/` is escaped as `\/`.
- Formatting is Apple's pretty printer: `" : "` between key and value, 2-space indent, empty arrays as `[\n\n  ]`, no trailing newline (the hand-written legacy file and `restore_expectations.json`, written with `JSONSerialization`, do end in a newline).
- Dates: the top-level `exportedAt` and comics `exported_at` are ISO 8601 strings without fractional seconds
  (`2026-11-03T16:40:20Z`). The image section's `exportedAt` is a `Date` with the default strategy: seconds since
  2001-01-01 as a Double (e.g. `815416820.664167`).
- Optional nil fields are left out entirely, never written as `null`. Bools are `true`/`false`; URLs are plain absolute strings.
  Whole-number Doubles print without a fraction (`1767323045`).
- `LibraryBackup.capture` keeps only http(s) preview/sample/file URLs (`cloudMetadata`). Restoring a favorite goes through
  `BooruPost.onServer`, which drops `reducedDataURL`, `tagCategories`, `animated` and `animationVideoURL`.
  `restore_expectations.json` shows the payloads after that loss.

## Later schema changes

- `works.site` (migration `v13_work_site`, native and Dart): every work row in
  `restore_expectations.json` gained `"site": null`, which is what the native dump now writes for
  backups that carry no site.
