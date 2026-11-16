import 'dart:io';
import 'dart:isolate';

import '../booru/booru_store.dart';
import '../content/recent_works.dart';
import '../support/document_files.dart';
import 'app_database.dart';
import 'library_backup.dart';

/// What a backup holds before it is restored, for the confirmation prompt.
extension LibraryBackupPreview on LibraryBackupImport {
  int get comicWorks => comics?.works.length ?? 0;
  int get imageFavorites => images?.favorites.length ?? 0;
  int get challengeGames => challenges?.games.length ?? 0;
}

/// `LibraryBackupSection`'s file work: export both libraries to one JSON file the person
/// saves, read a picked file for confirmation, then merge it into the libraries.
class LibraryBackupActions {
  LibraryBackupActions({
    required this.database,
    required this.images,
    this.files = const DocumentFiles(),
    Directory? temporary,
    RecentWorks? recentWorks,
    RecentImages? recentImages,
  }) : temporary = temporary ?? Directory.systemTemp,
       recentWorks = recentWorks ?? RecentWorks.shared,
       recentImages = recentImages ?? RecentImages.shared;

  final AppDatabase database;
  final BooruStore images;

  /// The app's recent lists; the backup carries them and a restore merges into them.
  final RecentWorks? recentWorks;
  final RecentImages? recentImages;
  final DocumentFiles files;
  final Directory temporary;

  /// JSON files saved by other apps can arrive as plain text or untyped data.
  static const importTypes = ['application/json', 'text/json', 'text/plain', 'application/octet-stream'];

  /// The backup file under [temporary], named as the native share sheet names it.
  File exportFile() => LibraryBackup.export(
    database,
    images,
    temporary: temporary,
    recentWorks: recentWorks?.entries ?? const [],
    recentImages: recentImages?.entries ?? const [],
  );

  /// Writes the backup and asks where to keep it. False when the person cancels. With a password
  /// the file is locked ([LockedBackup]) and named so people can tell it apart.
  Future<bool> export({String? password}) async {
    var file = exportFile();
    try {
      if (password != null) {
        final plain = file.readAsBytesSync();
        // Deriving the key takes a moment; it runs away from the interface.
        final locked = await Isolate.run(() => LockedBackup.lock(plain, password));
        final lockedFile = File('${file.parent.path}/tegnal-backup-locked.json')..writeAsBytesSync(locked, flush: true);
        file.deleteSync();
        file = lockedFile;
      }
      return await files.createDocument(name: file.uri.pathSegments.last, source: file);
    } finally {
      _discard(file);
    }
  }

  /// A picked backup, read and validated; null when nothing was picked or the person gave no
  /// password for a locked one. A wrong password throws [LockedBackupError.wrongPassword].
  Future<LibraryBackupImport?> pick({Future<String?> Function()? password}) async {
    final file = await files.openDocument(mimeTypes: importTypes);
    if (file == null) return null;
    try {
      try {
        return LibraryBackupImport.read(file);
      } on LockedBackupError catch (error) {
        if (error != LockedBackupError.passwordRequired || password == null) rethrow;
        final entered = await password();
        if (entered == null) return null;
        final data = file.readAsBytesSync();
        final plain = await Isolate.run(() => LockedBackup.unlock(data, entered));
        return LibraryBackupImport.decode(plain);
      }
    } finally {
      _discard(file);
    }
  }

  /// Merges the backup. The caller then restarts the cover queue and marks sync for a fresh upload.
  void restore(LibraryBackupImport backup) {
    backup.restore(database, images);
    recentWorks?.merge([for (final record in backup.comics?.recentWorks ?? const <MangaRecentRecord>[]) record.work]);
    recentImages?.merge(backup.images?.recentImagesOn(images.servers) ?? const []);
    database.syncFoldersToAppGroup();
  }

  static void _discard(File file) {
    try {
      if (file.existsSync()) file.deleteSync();
      final parent = file.parent;
      if (parent.existsSync() && parent.listSync().isEmpty) parent.deleteSync();
    } on FileSystemException {
      // A leftover temporary file is cleared with the cache.
    }
  }
}
