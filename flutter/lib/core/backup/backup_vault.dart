import 'dart:io';
import 'dart:typed_data';

import '../sync/library_drive_sync.dart';
import 'backup_container.dart';

enum BackupPlace { local, drive }

/// One backup file as a vault lists it, from its name and size alone.
class BackupVaultFile {
  const BackupVaultFile({required this.name, required this.size, required this.place, required this.downloaded, this.downloading = false});
  final String name;
  final int size;
  final BackupPlace place;

  /// Whether the file's bytes are on this device.
  final bool downloaded;
  final bool downloading;
}

/// A place backups are kept. The store shows every vault as one list.
abstract interface class BackupVault {
  BackupPlace get place;
  Future<bool> available();
  Future<List<BackupVaultFile>> list();

  /// Puts a local file in the vault under [name]. The local vault moves it; a remote one uploads a copy.
  Future<void> add(File file, String name);

  /// Copies a backup into [folder].
  Future<File> fetch(String name, Directory folder);
  Future<void> delete(String name);

  /// The head of a backup already on this device; null when it would need a download.
  Future<BackupManifest?> manifest(String name);
}

/// `Backups/Vault` under the app's files directory, which Android Auto Backup leaves out.
class LocalBackupVault implements BackupVault {
  LocalBackupVault(this.folder);
  final Directory folder;

  @override
  BackupPlace get place => BackupPlace.local;

  @override
  Future<bool> available() async => true;

  @override
  Future<List<BackupVaultFile>> list() async {
    if (!folder.existsSync()) return [];
    return [
      for (final entity in folder.listSync())
        if (entity is File && BackupName.tryParse(entity.uri.pathSegments.last) != null)
          BackupVaultFile(name: entity.uri.pathSegments.last, size: entity.lengthSync(), place: BackupPlace.local, downloaded: true),
    ];
  }

  @override
  Future<void> add(File file, String name) async {
    folder.createSync(recursive: true);
    final destination = File('${folder.path}/$name');
    if (file.absolute.path == destination.absolute.path) return;
    if (destination.existsSync()) destination.deleteSync();
    try {
      file.renameSync(destination.path);
    } on FileSystemException {
      // The file came from another volume.
      file.copySync(destination.path);
      file.deleteSync();
    }
  }

  @override
  Future<File> fetch(String name, Directory target) async {
    final source = File('${folder.path}/$name');
    if (!source.existsSync()) throw BackupError.unavailable;
    target.createSync(recursive: true);
    final copy = File('${target.path}/$name');
    if (copy.existsSync()) copy.deleteSync();
    return source.copy(copy.path);
  }

  @override
  Future<void> delete(String name) async {
    final file = File('${folder.path}/$name');
    if (file.existsSync()) file.deleteSync();
  }

  @override
  Future<BackupManifest?> manifest(String name) async {
    try {
      return BackupArchive.open(File('${folder.path}/$name')).manifest;
    } on Object {
      return null;
    }
  }
}

/// The app's `TEGNAL` folder in Google Drive, beside the library sync files, which only list their own.
/// Active only where Drive sync is configured and the person is signed in.
class DriveBackupVault implements BackupVault {
  DriveBackupVault({required this.backend, required this.isSignedIn});

  /// The same backend library sync uses; a backend without [DriveBackupFiles] makes the vault unavailable.
  final DriveBackend backend;
  final bool Function() isSignedIn;

  /// The client sends and receives a file in one piece, so larger backups stay on the device only.
  static const sizeLimit = 32 << 20;

  @override
  BackupPlace get place => BackupPlace.drive;

  DriveBackupFiles? get _files => backend is DriveBackupFiles ? backend as DriveBackupFiles : null;

  @override
  Future<bool> available() async => backend.isConfigured && isSignedIn() && _files != null;

  @override
  Future<List<BackupVaultFile>> list() async {
    final files = _files;
    if (files == null || !await available()) return [];
    return [
      for (final file in await files.backupFiles(await backend.folder()))
        // A file name with no valid backup name is somebody else's.
        if (BackupName.tryParse(file.name) != null) BackupVaultFile(name: file.name, size: file.size, place: BackupPlace.drive, downloaded: false),
    ];
  }

  Future<DriveFile?> _find(String name) async {
    final files = _files;
    if (files == null || !await available()) throw BackupError.unavailable;
    return (await files.backupFiles(await backend.folder())).where((file) => file.name == name).firstOrNull;
  }

  @override
  Future<void> add(File file, String name) async {
    final files = _files;
    if (files == null || !await available()) throw BackupError.unavailable;
    if (file.lengthSync() > sizeLimit) throw BackupError.tooLarge;
    final existing = await _find(name);
    final Uint8List data = await file.readAsBytes();
    await files.uploadBackup(await backend.folder(), name, data, fileID: existing?.id);
  }

  @override
  Future<File> fetch(String name, Directory target) async {
    final found = await _find(name);
    if (found == null) throw BackupError.unavailable;
    if (found.size > sizeLimit) throw BackupError.tooLarge;
    final data = await backend.download(found.id);
    target.createSync(recursive: true);
    final copy = File('${target.path}/$name');
    await copy.writeAsBytes(data, flush: true);
    return copy;
  }

  @override
  Future<void> delete(String name) async {
    final files = _files;
    final found = await _find(name);
    if (files != null && found != null) await files.deleteFile(found.id);
  }

  @override
  Future<BackupManifest?> manifest(String name) async => null;
}
