import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:characters/characters.dart';
import 'package:crypto/crypto.dart';

import '../support/l10n.dart';
import 'update_backup.dart';

/// Why a backup was made.
enum BackupKind {
  /// First launch after an update that changed the first or second version number, or from a
  /// version that left no marker.
  minor,

  /// First launch after any other version or build change.
  patch,

  /// "Back Up Now".
  manual,

  /// Made just before a restore.
  safety,

  /// Made every few days while the app is used, then thinned as it ages.
  periodic,
}

enum BackupErrorCode {
  notBackup,
  damaged,
  otherPlatform,
  newerApp,
  tooLarge,
  notDownloaded,
  unavailable,
  databaseUnreadable,
  safetyBackupFailed,
  snapshotFailed,
}

/// Everything that can refuse or stop a backup or a restore. The wording is the iOS engine's, so the
/// two apps say the same thing.
class BackupError implements Exception {
  const BackupError._(this.code, [this.reason = '']);
  factory BackupError.snapshotFailed(String reason) => BackupError._(BackupErrorCode.snapshotFailed, reason);

  static const notBackup = BackupError._(BackupErrorCode.notBackup);
  static const damaged = BackupError._(BackupErrorCode.damaged);
  static const otherPlatform = BackupError._(BackupErrorCode.otherPlatform);
  static const newerApp = BackupError._(BackupErrorCode.newerApp);
  static const tooLarge = BackupError._(BackupErrorCode.tooLarge);
  static const notDownloaded = BackupError._(BackupErrorCode.notDownloaded);
  static const unavailable = BackupError._(BackupErrorCode.unavailable);
  static const databaseUnreadable = BackupError._(BackupErrorCode.databaseUnreadable);
  static const safetyBackupFailed = BackupError._(BackupErrorCode.safetyBackupFailed);

  final BackupErrorCode code;
  final String reason;

  String get message => switch (code) {
    BackupErrorCode.notBackup => L10n.text('This file is not a TEGNAL backup.'),
    BackupErrorCode.damaged => L10n.text('This backup is damaged and cannot be used.'),
    BackupErrorCode.otherPlatform => L10n.text('This backup was made on another kind of device and cannot be restored here.'),
    BackupErrorCode.newerApp => L10n.text('This backup was made by a newer version of TEGNAL. Update the app to restore it.'),
    BackupErrorCode.tooLarge => L10n.text('The backup is too large.'),
    // Kept for the shared wording; no vault on Android has files that still need downloading to a device folder.
    BackupErrorCode.notDownloaded => L10n.text('The backup is still downloading from iCloud. Try again in a moment.'),
    BackupErrorCode.unavailable => L10n.text('This backup is no longer available.'),
    BackupErrorCode.databaseUnreadable => L10n.text("The backup's library could not be opened. Your data was not changed."),
    BackupErrorCode.safetyBackupFailed => L10n.text('The current data could not be backed up first, so nothing was restored.'),
    BackupErrorCode.snapshotFailed => L10n.text('The backup before the update could not be made: %@', [reason]),
  };

  @override
  bool operator ==(Object other) => other is BackupError && other.code == code && other.reason == reason;

  @override
  int get hashCode => Object.hash(code, reason);

  @override
  String toString() => message;
}

/// An ISO 8601 date in whole seconds with a `Z`, the only form the iOS decoder reads.
String backupDateText(DateTime date) {
  final utc = date.toUtc();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${utc.year.toString().padLeft(4, '0')}-${two(utc.month)}-${two(utc.day)}T${two(utc.hour)}:${two(utc.minute)}:${two(utc.second)}Z';
}

/// The JSON at the head of a `.tegnalbackup` file.
class BackupManifest {
  BackupManifest({
    required this.id,
    required this.kind,
    this.platform = 'android',
    required this.createdAt,
    required this.dataVersion,
    required this.dataBuild,
    required this.appVersion,
    required this.appBuild,
    required this.device,
    this.counts,
    List<BackupManifestEntry>? entries,
  }) : entries = entries ?? [];

  final String format = 'tegnal-backup';
  final int version = 1;
  final String id;
  final BackupKind kind;
  String platform;
  DateTime createdAt;
  final String? dataVersion;
  final String? dataBuild;
  final String appVersion;
  final String appBuild;
  final BackupDevice device;
  final BackupCounts? counts;
  List<BackupManifestEntry> entries;

  BackupManifest copy() => BackupManifest(
    id: id,
    kind: kind,
    platform: platform,
    createdAt: createdAt,
    dataVersion: dataVersion,
    dataBuild: dataBuild,
    appVersion: appVersion,
    appBuild: appBuild,
    device: device,
    counts: counts,
    entries: [...entries],
  );

  /// Keys sorted and slashes unescaped, as the iOS encoder writes them. An unknown data version is
  /// written as null rather than left out.
  Map<String, Object?> toJson() => {
    'appBuild': appBuild,
    'appVersion': appVersion,
    if (counts case final counts?) 'counts': counts.toJson(),
    'createdAt': backupDateText(createdAt),
    'dataBuild': dataBuild,
    'dataVersion': dataVersion,
    'device': device.toJson(),
    'entries': [for (final entry in entries) entry.toJson()],
    'format': format,
    'id': id,
    'kind': kind.name,
    'platform': platform,
    'version': version,
  };

  Uint8List encode() => Uint8List.fromList(utf8.encode(jsonEncode(toJson())));

  /// Null when [json] is not a version 1 manifest. The reader treats that as "not a backup".
  static BackupManifest? decode(List<int> bytes) {
    try {
      final json = jsonDecode(utf8.decode(bytes));
      if (json is! Map<String, Object?> || json['format'] != 'tegnal-backup' || json['version'] != 1) return null;
      final device = json['device'], counts = json['counts'], entries = json['entries'];
      if (device is! Map<String, Object?> || entries is! List) return null;
      final kind = BackupKind.values.where((value) => value.name == json['kind']).firstOrNull;
      final created = DateTime.tryParse(json['createdAt'] as String);
      if (kind == null || created == null) return null;
      return BackupManifest(
        id: json['id'] as String,
        kind: kind,
        platform: json['platform'] as String,
        createdAt: created.toUtc(),
        dataVersion: json['dataVersion'] as String?,
        dataBuild: json['dataBuild'] as String?,
        appVersion: json['appVersion'] as String,
        appBuild: json['appBuild'] as String,
        device: BackupDevice(id: device['id'] as String, name: device['name'] as String),
        counts: counts is Map<String, Object?> ? BackupCounts(works: counts['works'] as int, images: counts['images'] as int) : null,
        entries: [for (final entry in entries) BackupManifestEntry.fromJson(entry as Map<String, Object?>)],
      );
    } on Object {
      return null;
    }
  }

  /// The file name this backup is stored under.
  String get fileName => BackupName(kind: kind, dataVersion: dataVersion, dataBuild: dataBuild, createdAt: createdAt, deviceID: device.id).fileName;
}

class BackupDevice {
  const BackupDevice({required this.id, required this.name});
  final String id;
  final String name;
  Map<String, Object?> toJson() => {'id': id, 'name': name};
}

class BackupCounts {
  const BackupCounts({required this.works, required this.images});
  final int works;
  final int images;
  Map<String, Object?> toJson() => {'images': images, 'works': works};
}

class BackupManifestEntry {
  const BackupManifestEntry({
    required this.name,
    required this.policy,
    required this.size,
    required this.storedSize,
    required this.compression,
    required this.sha256,
  });

  final String name;
  final String policy;
  final int size;
  final int storedSize;
  final String compression;
  final String sha256;

  Map<String, Object?> toJson() => {'compression': compression, 'name': name, 'policy': policy, 'sha256': sha256, 'size': size, 'storedSize': storedSize};

  factory BackupManifestEntry.fromJson(Map<String, Object?> json) => BackupManifestEntry(
    name: json['name'] as String,
    policy: json['policy'] as String,
    size: json['size'] as int,
    storedSize: json['storedSize'] as int,
    compression: json['compression'] as String,
    sha256: json['sha256'] as String,
  );
}

/// `tegnal_<kind>_<dataVersion or 0>_<dataBuild or 0>_<yyyyMMdd'T'HHmmss'Z'>_<device id>.tegnalbackup`,
/// so a list needs neither a download nor the file's contents.
class BackupName {
  BackupName({required this.kind, String? dataVersion, String? dataBuild, required DateTime createdAt, required String deviceID})
    : dataVersion = _unknown(dataVersion),
      dataBuild = _unknown(dataBuild),
      // The name keeps whole seconds; the date read back from it must equal the one written.
      createdAt = DateTime.fromMillisecondsSinceEpoch((createdAt.millisecondsSinceEpoch / 1000).floor() * 1000, isUtc: true),
      deviceID = _part(deviceID);

  static const fileExtension = 'tegnalbackup';

  final BackupKind kind;
  final String? dataVersion;
  final String? dataBuild;
  final DateTime createdAt;
  final String deviceID;

  static String? _unknown(String? value) {
    final part = value == null ? null : _part(value);
    return part == '0' ? null : part;
  }

  static BackupName? tryParse(String fileName) {
    const suffix = '.$fileExtension';
    if (!fileName.endsWith(suffix)) return null;
    // Empty parts are kept, so a name with a missing device does not parse.
    final parts = fileName.substring(0, fileName.length - suffix.length).split('_');
    if (parts.length != 6 || parts[0] != 'tegnal') return null;
    final kind = BackupKind.values.where((value) => value.name == parts[1]).firstOrNull;
    final date = _parseDate(parts[4]);
    if (kind == null || date == null || parts[5].isEmpty) return null;
    if ([parts[2], parts[3], parts[5]].any((part) => part != _part(part))) return null;
    return BackupName(kind: kind, dataVersion: parts[2], dataBuild: parts[3], createdAt: date, deviceID: parts[5]);
  }

  String get fileName => '${['tegnal', kind.name, dataVersion ?? '0', dataBuild ?? '0', _formatDate(createdAt), deviceID].join('_')}.$fileExtension';

  /// Underscores separate the parts; anything but letters, digits, dots and dashes becomes a dash.
  static String _part(String value) {
    final cleaned = value.characters.map((character) => RegExp(r'^[A-Za-z0-9.\-]$').hasMatch(character) ? character : '-').join();
    return cleaned.isEmpty ? '0' : cleaned;
  }

  static String _formatDate(DateTime date) {
    final utc = date.toUtc();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${utc.year.toString().padLeft(4, '0')}${two(utc.month)}${two(utc.day)}T${two(utc.hour)}${two(utc.minute)}${two(utc.second)}Z';
  }

  static DateTime? _parseDate(String text) {
    final match = RegExp(r'^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z$').firstMatch(text);
    if (match == null) return null;
    final values = [for (var index = 1; index <= 6; index++) int.parse(match[index]!)];
    final date = DateTime.utc(values[0], values[1], values[2], values[3], values[4], values[5]);
    // A month 13 or an hour 25 would roll over into another date.
    final same = date.month == values[1] && date.day == values[2] && date.hour == values[3] && date.minute == values[4] && date.second == values[5];
    return same ? date : null;
  }

  @override
  bool operator ==(Object other) =>
      other is BackupName &&
      other.kind == kind &&
      other.dataVersion == dataVersion &&
      other.dataBuild == dataBuild &&
      other.createdAt == createdAt &&
      other.deviceID == deviceID;

  @override
  int get hashCode => Object.hash(kind, dataVersion, dataBuild, createdAt, deviceID);
}

/// The entries a backup may hold. A name from a file is only ever looked up here, never used as a path.
abstract final class BackupEntry {
  static const databases = ['memo.sqlite', 'booru.sqlite'];
  static const databaseSuffixes = ['', '-journal', '-wal', '-shm'];
  static final databaseEntries = [
    for (final name in databases)
      for (final suffix in databaseSuffixes) 'db/$name$suffix',
  ];

  /// Every preference of the one store, with the image mode's keys under their own prefix.
  static const preferences = 'prefs/store.json';
  static const preferenceEntries = [preferences];
  static const fileEntries = [
    'files/gallery-keys',
    'files/work-missing-sites',
    'files/downloads.json',
    'files/downloads-settings.json',
    'files/generated-index.json',
  ];

  /// Every known entry, in the order a backup stores them.
  static final all = [...databaseEntries, ...preferenceEntries, ...fileEntries];

  /// `replace` or `ifMissing`; null for a name this app does not know.
  static String? policy(String name) {
    if (fileEntries.contains(name)) return 'ifMissing';
    return all.contains(name) ? 'replace' : null;
  }
}

/// `.tegnalbackup` files: write and read, streamed so no entry is ever held whole in memory.
abstract final class BackupContainer {
  static final magic = Uint8List.fromList(utf8.encode('TEGNALBK'));
  static const containerVersion = 1;
  static const headerSize = 13;
  static const manifestLimit = 1 << 20;
  static const fileLimit = 512 << 20;

  /// The most an entry, and all entries together, may inflate to.
  static const inflatedLimit = 2 << 30;

  /// Raw DEFLATE (RFC 1951), as iOS reads and writes it.
  static final deflate = ZLibCodec(raw: true);

  /// The header: magic, container version and the manifest's length, big-endian.
  static Uint8List header(int manifestLength) {
    final bytes = BytesBuilder()
      ..add(magic)
      ..addByte(containerVersion)
      ..add((ByteData(4)..setUint32(0, manifestLength)).buffer.asUint8List());
    return bytes.toBytes();
  }

  /// Packs the known entries found in [folder] into a backup file at [destination].
  static Future<BackupManifest> write({required Directory folder, required BackupManifest manifest, required File destination, required Directory work}) async {
    final scratch = Directory('${work.path}/pack-${DateTime.now().microsecondsSinceEpoch}')..createSync(recursive: true);
    try {
      final packedManifest = manifest.copy()..entries = [];
      final bodies = <File>[];
      for (final name in BackupEntry.all) {
        final source = File('${folder.path}/$name');
        final policy = BackupEntry.policy(name);
        if (!source.existsSync() || policy == null) continue;
        final packed = File('${scratch.path}/${bodies.length}');
        final digest = _Digest();
        final hash = sha256.startChunkedConversion(digest);
        final output = packed.openWrite();
        var size = 0, stored = 0;
        try {
          final input = source.openRead().map((chunk) {
            hash.add(chunk);
            size += chunk.length;
            return chunk;
          });
          await for (final chunk in input.transform(deflate.encoder)) {
            output.add(chunk);
            stored += chunk.length;
          }
        } finally {
          await output.close();
        }
        hash.close();
        // Data that does not shrink is stored as it is.
        final deflated = stored < size;
        packedManifest.entries.add(
          BackupManifestEntry(
            name: name,
            policy: policy,
            size: size,
            storedSize: deflated ? stored : size,
            compression: deflated ? 'deflate' : 'none',
            sha256: digest.value.toString(),
          ),
        );
        bodies.add(deflated ? packed : source);
      }
      final json = packedManifest.encode();
      if (json.length > manifestLimit) throw BackupError.tooLarge;
      final total = headerSize + json.length + packedManifest.entries.fold<int>(0, (sum, entry) => sum + entry.storedSize);
      if (total > fileLimit) throw BackupError.tooLarge;
      final partial = File('${scratch.path}/backup');
      final output = partial.openSync(mode: FileMode.write);
      try {
        output.writeFromSync(header(json.length));
        output.writeFromSync(json);
        for (var index = 0; index < bodies.length; index++) {
          var remaining = packedManifest.entries[index].storedSize;
          await for (final chunk in bodies[index].openRead()) {
            if (remaining <= 0) break;
            final part = chunk.length > remaining ? chunk.sublist(0, remaining) : chunk;
            output.writeFromSync(part);
            remaining -= part.length;
          }
          // The file changed while it was read; the entry would not match its checksum.
          if (remaining != 0) throw BackupError.damaged;
        }
        output.flushSync();
      } finally {
        output.closeSync();
      }
      destination.parent.createSync(recursive: true);
      if (destination.existsSync()) destination.deleteSync();
      try {
        partial.renameSync(destination.path);
      } on FileSystemException {
        // The scratch folder can sit on another volume than the vault.
        partial.copySync(destination.path);
      }
      return packedManifest;
    } finally {
      if (scratch.existsSync()) scratch.deleteSync(recursive: true);
    }
  }
}

/// A backup file whose head has been read and checked; its entries are checked as they are read.
class BackupArchive {
  BackupArchive._(this.file, this.manifest, this.bodyOffset);

  final File file;
  final BackupManifest manifest;
  final int bodyOffset;

  /// A clock a day ahead is forgiven; a backup dated beyond that is refused, as it would never age out of retention.
  static const futureSlack = Duration(days: 1);

  static BackupArchive open(File file, {DateTime? now}) {
    final size = file.lengthSync();
    if (size < BackupContainer.headerSize) throw BackupError.notBackup;
    if (size > BackupContainer.fileLimit) throw BackupError.tooLarge;
    final handle = file.openSync();
    try {
      final header = handle.readSync(BackupContainer.headerSize);
      if (header.length != BackupContainer.headerSize || !_equal(header.sublist(0, 8), BackupContainer.magic)) throw BackupError.notBackup;
      if (header[8] != BackupContainer.containerVersion) throw BackupError.notBackup;
      final length = ByteData.sublistView(header, 9, 13).getUint32(0);
      if (length <= 0 || length > BackupContainer.manifestLimit) throw BackupError.notBackup;
      if (length > size - BackupContainer.headerSize) throw BackupError.damaged;
      final json = handle.readSync(length);
      if (json.length != length) throw BackupError.damaged;
      final manifest = BackupManifest.decode(json);
      if (manifest == null) throw BackupError.notBackup;
      if (manifest.createdAt.isAfter((now ?? DateTime.now()).add(futureSlack))) throw BackupError.damaged;
      final names = <String>{};
      var storedTotal = 0, inflatedTotal = 0;
      final hex = RegExp(r'^[0-9a-fA-F]{64}$');
      for (final entry in manifest.entries) {
        final valid =
            entry.size >= 0 &&
            entry.storedSize >= 0 &&
            names.add(entry.name) &&
            hex.hasMatch(entry.sha256) &&
            (entry.compression == 'deflate' || (entry.compression == 'none' && entry.storedSize == entry.size));
        if (!valid) throw BackupError.damaged;
        // Each size is capped before any sum, so none of them can overflow or promise more than a device can hold.
        if (entry.storedSize > BackupContainer.fileLimit || entry.size > BackupContainer.inflatedLimit) throw BackupError.tooLarge;
        storedTotal += entry.storedSize;
        inflatedTotal += entry.size;
      }
      if (inflatedTotal > BackupContainer.inflatedLimit) throw BackupError.tooLarge;
      final body = BackupContainer.headerSize + length;
      // A shorter file was cut off; a longer one carries bytes the manifest does not account for.
      if (storedTotal != size - body) throw BackupError.damaged;
      return BackupArchive._(file, manifest, body);
    } finally {
      handle.closeSync();
    }
  }

  static bool _equal(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var index = 0; index < a.length; index++) {
      if (a[index] != b[index]) return false;
    }
    return true;
  }

  /// A restore replaces both databases, so a backup without either of them cannot be restored.
  void requireLibrary() {
    final names = {for (final entry in manifest.entries) entry.name};
    if (!names.containsAll(const ['db/memo.sqlite', 'db/booru.sqlite'])) throw BackupError.damaged;
  }

  /// Checks whether this app may restore the backup at all.
  void checkRestorable({required String appVersion, required String appBuild, String platform = 'android'}) {
    if (manifest.platform != platform) throw BackupError.otherPlatform;
    if (UpdateBackup.isNewer(manifest.appVersion, manifest.appBuild, than: appVersion, thanBuild: appBuild)) throw BackupError.newerApp;
  }

  /// Checks every entry's size and checksum, writing the known ones into [folder] under their names.
  /// Without a folder it only checks.
  Future<void> extract(Directory? folder) async {
    var offset = bodyOffset;
    for (final entry in manifest.entries) {
      final start = offset;
      offset += entry.storedSize;
      final target = folder == null ? null : File('${folder.path}/${entry.name}');
      final known = target != null && BackupEntry.policy(entry.name) != null;
      IOSink? output;
      final digest = _Digest();
      final hash = sha256.startChunkedConversion(digest);
      var written = 0;
      try {
        if (known) {
          target.parent.createSync(recursive: true);
          output = target.openWrite();
        }
        Stream<List<int>> stored = file.openRead(start, offset);
        if (entry.compression == 'deflate') {
          // The inflater ignores what follows the end of its stream; bytes the stream does not use belong to nothing.
          if (DeflateScanner.length(file, start, offset) != entry.storedSize) throw BackupError.damaged;
          stored = stored.transform(BackupContainer.deflate.decoder);
        }
        await for (final chunk in stored) {
          written += chunk.length;
          // Never inflate past the size the manifest declared.
          if (written > entry.size) throw BackupError.damaged;
          hash.add(chunk);
          output?.add(chunk);
        }
        await output?.close();
        output = null;
        hash.close();
        if (written != entry.size || digest.value.toString() != entry.sha256.toLowerCase()) throw BackupError.damaged;
      } on Object catch (error) {
        try {
          await output?.close();
        } on Object {
          // The entry is removed below either way.
        }
        if (known && target.existsSync()) target.deleteSync();
        throw error is BackupError ? error : BackupError.damaged;
      }
    }
  }
}

class _Digest implements Sink<Digest> {
  late Digest value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

/// Measures how many bytes a raw DEFLATE stream (RFC 1951) really uses, by walking its blocks without
/// producing output (after zlib's `puff.c`). The inflater itself ignores bytes after the stream's end.
abstract final class DeflateScanner {
  static const _lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0];
  static const _distanceExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13];
  static const _order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15];

  /// The bytes of `[start, end)` the stream occupies; throws [FormatException] for a stream that is not valid
  /// or runs past [end]. Whatever remains in the range is trailing data.
  static int length(File file, int start, int end) {
    final handle = file.openSync();
    try {
      handle.setPositionSync(start);
      final reader = _Bits(handle, end - start);
      _Huffman? fixedLiteral, fixedDistance;
      while (true) {
        final last = reader.bits(1);
        switch (reader.bits(2)) {
          case 0:
            reader.alignToByte();
            final length = reader.bits(16), inverse = reader.bits(16);
            if (length != (~inverse & 0xFFFF)) throw const FormatException('Stored block length');
            reader.skip(length);
          case 1:
            if (fixedLiteral == null) {
              fixedLiteral = _Huffman([...List.filled(144, 8), ...List.filled(112, 9), ...List.filled(24, 7), ...List.filled(8, 8)]);
              fixedDistance = _Huffman(List.filled(30, 5));
            }
            _codes(reader, fixedLiteral, fixedDistance!);
          case 2:
            final literals = reader.bits(5) + 257, distances = reader.bits(5) + 1, codes = reader.bits(4) + 4;
            if (literals > 286 || distances > 30) throw const FormatException('Too many codes');
            final lengths = List.filled(19, 0);
            for (var index = 0; index < codes; index++) {
              lengths[_order[index]] = reader.bits(3);
            }
            final lengthCode = _Huffman(lengths);
            final all = <int>[];
            while (all.length < literals + distances) {
              final symbol = lengthCode.decode(reader);
              if (symbol < 16) {
                all.add(symbol);
              } else {
                var repeat = 0, value = 0;
                if (symbol == 16) {
                  if (all.isEmpty) throw const FormatException('Repeat with nothing before');
                  value = all.last;
                  repeat = 3 + reader.bits(2);
                } else if (symbol == 17) {
                  repeat = 3 + reader.bits(3);
                } else {
                  repeat = 11 + reader.bits(7);
                }
                if (all.length + repeat > literals + distances) throw const FormatException('Too many lengths');
                all.addAll(List.filled(repeat, value));
              }
            }
            if (all[256] == 0) throw const FormatException('No end of block code');
            _codes(reader, _Huffman(all.sublist(0, literals)), _Huffman(all.sublist(literals)));
          default:
            throw const FormatException('Block type');
        }
        if (last == 1) return reader.consumed;
      }
    } finally {
      handle.closeSync();
    }
  }

  static void _codes(_Bits reader, _Huffman literal, _Huffman distance) {
    while (true) {
      final symbol = literal.decode(reader);
      if (symbol < 256) continue;
      if (symbol == 256) return;
      if (symbol > 285) throw const FormatException('Length symbol');
      reader.bits(_lengthExtra[symbol - 257]);
      final far = distance.decode(reader);
      if (far > 29) throw const FormatException('Distance symbol');
      reader.bits(_distanceExtra[far]);
    }
  }
}

/// Bits of a file range, least significant first, read a byte at a time from a buffer.
class _Bits {
  _Bits(this._file, this._left);
  final RandomAccessFile _file;
  int _left;
  Uint8List _buffer = Uint8List(0);
  int _index = 0, _current = 0, _available = 0;
  int consumed = 0;

  int bits(int count) {
    var value = 0;
    for (var shift = 0; shift < count; shift++) {
      if (_available == 0) {
        if (_index == _buffer.length) {
          if (_left <= 0) throw const FormatException('Stream ends early');
          _buffer = _file.readSync(_left < (1 << 16) ? _left : 1 << 16);
          if (_buffer.isEmpty) throw const FormatException('Stream ends early');
          _left -= _buffer.length;
          _index = 0;
        }
        _current = _buffer[_index++];
        consumed += 1;
        _available = 8;
      }
      value |= (_current & 1) << shift;
      _current >>= 1;
      _available -= 1;
    }
    return value;
  }

  void alignToByte() => _available = 0;

  void skip(int count) {
    for (var index = 0; index < count; index++) {
      bits(8);
    }
  }
}

/// A canonical Huffman code, decoded a bit at a time.
class _Huffman {
  _Huffman(List<int> lengths) : _count = List.filled(16, 0), _symbols = List.filled(lengths.length, 0) {
    for (final length in lengths) {
      _count[length] += 1;
    }
    var left = 1;
    for (var length = 1; length <= 15; length++) {
      left = (left << 1) - _count[length];
      if (left < 0) throw const FormatException('Over-subscribed code');
    }
    final offsets = List.filled(16, 0);
    for (var length = 1; length < 15; length++) {
      offsets[length + 1] = offsets[length] + _count[length];
    }
    for (var symbol = 0; symbol < lengths.length; symbol++) {
      if (lengths[symbol] != 0) _symbols[offsets[lengths[symbol]]++] = symbol;
    }
  }

  final List<int> _count;
  final List<int> _symbols;

  int decode(_Bits reader) {
    var code = 0, first = 0, index = 0;
    for (var length = 1; length <= 15; length++) {
      code |= reader.bits(1);
      final count = _count[length];
      if (code - count < first) return _symbols[index + (code - first)];
      index += count;
      first += count;
      first <<= 1;
      code <<= 1;
    }
    throw const FormatException('Invalid code');
  }
}
