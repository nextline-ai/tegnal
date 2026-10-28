# Android bookmark SQLite import

The default onboarding and Settings action, **Import Data from Other Manga Viewers**, reads the Android bookmark SQLite format (`.sqlite` or `.db`). Older database/catalog/ABBJ formats remain under **Settings → Other Backup Formats**. TEGNAL JSON restore stays separate.

The picker previews counts before asking to merge. The source file is opened read-only. Parsing and staging run in a worker isolate; the final native-library merge is transactional. Cancelling before the merge or rejecting an invalid file leaves the library unchanged. Reimporting the same file does not duplicate saved works, artists or archived records. Existing work metadata, notes, reading positions and folder choices take precedence.

| Source | Destination / behavior |
| --- | --- |
| `BookmarkGroup` | Manga folders; preserves names, ARGB colors and relative ordering for newly created folders. Existing matching folders retain user customization. |
| `BookmarkArticle` | Saved manga items keyed by numeric work ID, linked to imported folders. Numeric-only records display `#ID` until metadata is explicitly obtained. |
| `BookmarkArtist` | Saved artists/groups, distinguished by `IsGroup`. |
| `SearchLog` | Search history, deduplicated by query. |
| `ArticleReadLog` | Original records retained locally; not applied as reader positions because the source page-index convention is unverified. |
| `BookmarkCropImage` | Original records retained locally; opaque areas are not converted into reader crops. |
| `BookmarkUser` / `HistoryUser` (when present) | Original records retained locally where there is no native equivalent. |
| `DownloadItem` | Not imported. External file paths, request headers and download credentials are not copied. |

No source connection is created by import. After a successful import, the app automatically fills missing covers, titles and tags using the user’s configured compatible source and shows progress above the main screen. Without a source, the queue waits for a connection and explains that state. The user can pause or resume the queue. A backup without titles or cover URLs cannot supply those fields offline. Remote cover URLs remain portable; fetched cover bytes use the existing session-scoped disk cache.

Native works, folders, artists and search data participate in the existing TEGNAL JSON backup. Original archival records use local `legacy.*` storage and are **not included in JSON export**; retain the original SQLite backup if those records are needed for future migration. Import does not promise restoration of downloaded image files.

Validation uses synthetic fixtures in the repository. Private input databases are never committed, embedded in builds, or used as public review fixtures. Import size is bounded to 256 MiB and parsed record count to one million.

The eight importer regressions cover preview without mutation, integer/JSON article IDs, row-ID-zero default groups, signed ARGB colors, existing edits, repeated imports, cancellation, late-write rollback, rejection of older formats and native JSON roundtrip without private archival fields. A 5,000-work synthetic case verifies staging allows the caller isolate to process timer events. The importer plus existing legacy/backup regression group passed 24 cases; Android import UI has a separate six-case group. These checks do not claim a measured frame-rate guarantee.

A separate read-only private-file dry run used a temporary target database, verified unchanged source bytes, stable counts after reimport and native-library JSON restoration, and removed the temporary data afterward. Only aggregate results were reported privately. Empty or invalid records can be omitted from native fields while their original row remains in the local archive; summary search/read/crop counts describe source records, not necessarily unique imported queries or applied reader features.
