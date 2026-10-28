# Image library site folders

Native reference: `BooruStore.swift` defaultFolder/saveFavorite/toggleFavorite and
legacy migrations. A site's first saved image creates a real folder identified
by `site:<canonical HTTPS address>`, named after the server. Empty registered
sites do not create empty folders. Explicit user folders replace the default;
ordinary resaves retain the existing folder. Manga behavior is unchanged.

Flutter now uses those rules at the LibraryStore saving boundary. The image
library, folder order sheet and move chooser never synthesize Unfiled. Archived
sources still supply site identity; active feed server selection does not hide
saved images. Equal display names retain independent address-based identities.

Existing unassigned images, imported native unsorted aliases and the legacy
anime-boxes shared folder are assigned to their respective site folders using
identity-only SQL. Custom-folder memberships, works, notes and save dates are
preserved. Old generic folder rows and portable metadata are retained in the
database, while those rows are omitted from the image folder list. Repaired
backups use native site folder IDs. Imported site IDs, renamed titles and colors
are recognized rather than duplicated on subsequent saves.

If source metadata is missing, `site:source:<sourceId>` keeps its works accessible
under the source ID. Later registration resolves that temporary folder into the
canonical site folder, preserving its color and any customized title. No source
is registered or contacted automatically by this repair.

Deleting a custom image folder returns its works to their site defaults. A
populated default site folder consequently reappears if deleted, preserving all
works; an empty one can be deleted. This intentionally differs from native's
deletion fallback to Unsorted, following the requested absence of image Unfiled.

The library overview retains SQL counts and at most four decoded covers per
folder. Repair runs only after relevant writes/opening, extracts identity without
decoding full ContentItems, and invalidates safely after an outer rollback.
Focused tests cover defaults, duplicate names, archives, missing sites, later
registration, legacy repair, custom data, rollback, deletion and native backup
roundtrip. Widget tests cover the absent image Unfiled and unchanged Manga
Unfiled, plus bounded overview/keyboard behavior. Device FPS was not measured.
