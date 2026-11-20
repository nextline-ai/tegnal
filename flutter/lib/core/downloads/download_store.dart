import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

import '../booru/booru_models.dart';
import '../content/content_errors.dart';
import '../content/gallery_content.dart';
import '../content/manga_urls.dart';
import '../storage/app_storage.dart';
import '../support/l10n.dart';
import '../support/swift_json.dart';

enum WorkDownloadMode {
  manga,
  booru;

  static WorkDownloadMode fromRawValue(String value) =>
      values.firstWhere((mode) => mode.name == value, orElse: () => throw SwiftJsonError('Unknown mode "$value"'));
}

enum WorkDownloadStatus {
  queued,
  downloading,
  paused,
  failed,
  completed;

  static WorkDownloadStatus fromRawValue(String value) =>
      values.firstWhere((status) => status.name == value, orElse: () => throw SwiftJsonError('Unknown status "$value"'));

  /// The English key for `L10n.text`, as the downloads list labels each item.
  String get title => switch (this) {
    queued => 'Queued',
    downloading => 'Downloading',
    paused => 'Paused',
    failed => 'Failed',
    completed => 'Completed',
  };

  /// The download actions menu offers Pause while running, and Retry or Resume when stopped.
  bool get canPause => this == queued || this == downloading;
  bool get canResume => this == paused || this == failed;
  String get resumeTitle => this == failed ? 'Retry' : 'Resume';
}

/// `ByteCountFormatter` with the `.file` style: decimal units, whole kilobytes,
/// one decimal for megabytes and two above, in the app language's spelling.
abstract final class FileByteCount {
  static String format(int bytes, {required String language}) {
    final spaced = language != 'ko';
    String unit(String value, String name) => spaced ? '$value $name' : '$value$name';
    if (bytes <= 0) {
      return switch (language) {
        'ko' => '0KB',
        'ja' => '0 KB',
        _ => 'Zero KB',
      };
    }
    if (bytes < 1000) {
      return switch (language) {
        'ko' => '$bytes바이트',
        'ja' => '$bytes バイト',
        _ => bytes == 1 ? '1 byte' : '$bytes bytes',
      };
    }
    const units = ['KB', 'MB', 'GB', 'TB', 'PB'];
    var value = bytes / 1000;
    var index = 0;
    while (value >= 999.5 && index < units.length - 1) {
      value /= 1000;
      index++;
    }
    final digits = index == 0 ? 0 : (index == 1 ? 1 : 2);
    var text = value.toStringAsFixed(digits);
    if (text.contains('.')) text = text.replaceFirst(RegExp(r'\.?0+$'), '');
    return unit(_grouped(text), units[index]);
  }

  static String _grouped(String number) {
    final parts = number.split('.');
    final whole = parts[0].replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+$)'), (match) => '${match[1]},');
    return parts.length > 1 ? '$whole.${parts[1]}' : whole;
  }
}

/// `WorkDownload`: one downloaded work and its files, as `downloads.json` stores it.
class WorkDownload {
  WorkDownload({
    String? id,
    required this.key,
    required this.mode,
    required this.title,
    required this.origin,
    this.gallery,
    this.server,
    this.post,
    this.status = WorkDownloadStatus.queued,
    List<String>? files,
    this.bytes = 0,
    this.error,
    this.location,
    this.path,
  }) : id = id ?? uuidString(),
       files = files ?? [];

  final String id;
  final String key;
  final WorkDownloadMode mode;
  final String title;
  final String origin;
  final NativeGallery? gallery;
  final BooruServer? server;
  BooruPost? post;
  WorkDownloadStatus status;
  List<String> files;
  int bytes;
  String? error;

  /// Where the files are: null for the app's own storage (every download before 1.6.0), else a
  /// `DownloadLocation` id. `path` is the folder inside it; null means the download's id.
  String? location;
  String? path;

  int get total => gallery?.pages.length ?? 1;
  List<String> get tags => gallery?.tags ?? post?.tags ?? const [];
  List<String> get artists => gallery?.artists ?? post?.artists ?? const [];

  /// Match every word across local metadata. Underscores and spaces are
  /// equivalent, so tags copied from a booru work with ordinary typing too.
  bool matches(String query) {
    final metadata = _normalized(
      [
        title,
        origin,
        gallery?.language ?? '',
        gallery?.type ?? '',
        gallery != null ? '${gallery!.id}' : (post != null ? '${post!.postID}' : ''),
        ...tags,
        ...artists,
      ].join(' '),
    );
    return splitWhitespace(_normalized(query)).every(metadata.contains);
  }

  static String _normalized(String text) => foldDiacritics(text.replaceAll('_', ' ').toLowerCase());

  factory WorkDownload.fromJson(JsonObject json) => WorkDownload(
    id: json.string('id'),
    key: json.string('key'),
    mode: WorkDownloadMode.fromRawValue(json.string('mode')),
    title: json.string('title'),
    origin: json.string('origin'),
    gallery: switch (json.objectOrNull('gallery')) {
      final value? => NativeGallery.fromJson(value),
      null => null,
    },
    server: switch (json.objectOrNull('server')) {
      final value? => BooruServer.fromJson(value),
      null => null,
    },
    post: switch (json.objectOrNull('post')) {
      final value? => BooruPost.fromJson(value),
      null => null,
    },
    status: WorkDownloadStatus.fromRawValue(json.string('status')),
    files: json.strings('files'),
    bytes: json.integer('bytes'),
    error: json.stringOrNull('error'),
    location: json.stringOrNull('location'),
    path: json.stringOrNull('path'),
  );

  JsonObject toJson() => <String, Object?>{'id': id, 'key': key, 'mode': mode.name, 'title': title, 'origin': origin}
    ..putIfPresent('gallery', gallery?.toJson())
    ..putIfPresent('server', server?.toJson())
    ..putIfPresent('post', post?.toJson())
    ..addAll({'status': status.name, 'files': files, 'bytes': bytes})
    ..putIfPresent('error', error)
    ..putIfPresent('location', location)
    ..putIfPresent('path', path);
}

/// `DownloadLocation`: a place downloads can be saved, the device's TEGNAL folder that the Files
/// app shows, or a folder the person chose.
class DownloadLocation {
  const DownloadLocation({required this.id, required this.name, this.path});
  static const files = 'files';
  static const onDevice = DownloadLocation(id: files, name: '');

  final String id;
  final String name;

  /// A chosen folder's place on this device.
  final String? path;

  bool get isFiles => id == files;

  factory DownloadLocation.fromJson(Map<String, Object?> json) =>
      DownloadLocation(id: json['id'] as String, name: json['name'] as String, path: json['path'] as String?);
  Map<String, Object?> toJson() => {'id': id, 'name': name, if (path != null) 'path': path};
}

/// Moves a folder, copying it when the destination is on other storage, as a rename can't cross it.
void moveDownloadFolder(String from, String to) {
  final source = Directory(from);
  try {
    source.renameSync(to);
    return;
  } on FileSystemException {
    // Another file system: copy, then remove the original once every file is there.
  }
  final target = Directory(to)..createSync(recursive: true);
  try {
    for (final entity in source.listSync(recursive: true, followLinks: false)) {
      final destination = '${target.path}${entity.path.substring(source.path.length)}';
      if (entity is Directory) {
        Directory(destination).createSync(recursive: true);
      } else if (entity is File) {
        File(destination).parent.createSync(recursive: true);
        entity.copySync(destination);
      }
    }
  } on Object {
    if (target.existsSync()) target.deleteSync(recursive: true);
    rethrow;
  }
  source.deleteSync(recursive: true);
}

/// `String.folding(options: [.caseInsensitive, .diacriticInsensitive])` for the Latin
/// letters people type in titles and tags; other scripts have no marks to fold here.
String foldDiacritics(String text) {
  final buffer = StringBuffer();
  for (final rune in text.runes) {
    buffer.write(_folded[rune] ?? String.fromCharCode(rune));
  }
  return buffer.toString();
}

final Map<int, String> _folded = () {
  const groups = {
    'a': 'àáâãäåāăą',
    'c': 'çćĉċč',
    'd': 'ďđ',
    'e': 'èéêëēĕėęě',
    'g': 'ĝğġģ',
    'h': 'ĥħ',
    'i': 'ìíîïĩīĭįı',
    'j': 'ĵ',
    'k': 'ķ',
    'l': 'ĺļľŀł',
    'n': 'ñńņňŉ',
    'o': 'òóôõöøōŏő',
    'r': 'ŕŗř',
    's': 'śŝşš',
    't': 'ţťŧ',
    'u': 'ùúûüũūŭůűų',
    'w': 'ŵ',
    'y': 'ýÿŷ',
    'z': 'źżž',
  };
  return {
    for (final MapEntry(:key, :value) in groups.entries)
      for (final rune in value.runes) rune: key,
  };
}();

/// What a booru download needs from image mode, which arrives with its own rebuild step.
abstract class BooruMediaDownloading {
  /// The post with its full file address, when a listing left it out.
  Future<BooruPost> details(BooruServer server, BooruPost post);

  /// Saves the post's media into [folder] and returns the file name, reporting progress
  /// from 0 to 1. Falls back to the signed-in browser session for images, as natively.
  Future<String> download(Uri url, {required BooruServer server, required BooruPost post, required Directory folder, void Function(double fraction)? progress});
}

class _Run {
  bool cancelled = false;
}

/// `DownloadStore`: durable downloads live outside the evictable viewer cache. One worker
/// per mode keeps large galleries from blocking image downloads or exhausting memory.
/// The record of downloads stays in the app's own storage; the files go to the chosen location,
/// in a folder named after the work, so the Files app and other apps can open them.
class DownloadStore extends ChangeNotifier {
  /// `filesRoot` is the device folder the Files app shows (Download/TEGNAL); tests and runs
  /// without one use a folder beside `directory`.
  DownloadStore({
    required this.directory,
    Directory? filesRoot,
    required this.manga,
    this.booru,
    String Function()? configuredHost,
    this.pageDelay = const Duration(seconds: 1),
  }) : filesRoot = filesRoot ?? Directory('${directory.path}-files'),
       _configuredHost = configuredHost ?? (() => MangaUrls.configuredHost) {
    try {
      final saved = settingsFile(directory);
      if (saved.existsSync()) {
        final json = jsonDecode(saved.readAsStringSync()) as Map<String, Object?>;
        _current = json['current'] as String? ?? DownloadLocation.files;
        hidesFromGallery = json['hidesFromGallery'] == true;
        _folders = [for (final value in json['folders'] as List<Object?>? ?? const []) DownloadLocation.fromJson(value! as Map<String, Object?>)];
      }
    } on Object {
      // Unreadable settings fall back to the device folder.
    }
    try {
      directory.createSync(recursive: true);
      // The native store excludes this folder from device backups; the Android backup
      // rules leave the app's support directory out instead.
      final manifest = manifestFile(directory);
      if (manifest.existsSync()) {
        final values = decodeJsonValue(manifest.readAsBytesSync());
        if (values is! List) throw SwiftJsonError('Expected a list of downloads');
        items = [for (final value in values) WorkDownload.fromJson(jsonObject(value))];
        for (final item in items) {
          final files = urls(item);
          if (item.status == WorkDownloadStatus.queued ||
              item.status == WorkDownloadStatus.downloading ||
              (item.status == WorkDownloadStatus.completed && (item.files.length != item.total || files.any((file) => !file.existsSync())))) {
            item.status = WorkDownloadStatus.paused;
          }
        }
      }
    } on Object catch (error) {
      storageError = '$error';
    }
  }

  /// `Application Support/Downloads`, beside both libraries.
  static Directory get defaultDirectory => directoryIn(AppStorage.container);
  static Directory directoryIn(Directory container) => Directory('${container.path}/Downloads');
  static File manifestFile(Directory directory) => File('${directory.path}/downloads.json');
  static File settingsFile(Directory directory) => File('${directory.path}/settings.json');

  final Directory directory;
  final Directory filesRoot;
  final ContentProviding manga;
  final BooruMediaDownloading? booru;
  final Duration pageDelay;
  final String Function() _configuredHost;

  List<WorkDownload> items = [];
  String? storageError;
  final Map<String, double> transferProgress = {};

  /// The move to the current location in progress: how many are done of how many.
  ({int done, int total})? moving;
  String? locationError;
  String _current = DownloadLocation.files;

  /// "Hide from Gallery Apps": a `.nomedia` file in each download folder keeps the images out of
  /// the photo gallery and other media apps; file managers still show them.
  bool hidesFromGallery = false;

  void setHidesFromGallery(bool hides) {
    hidesFromGallery = hides;
    _saveSettings();
    for (final location in locations) {
      _markGalleryHidden(root(location.id));
    }
    notifyListeners();
  }

  void _markGalleryHidden(Directory? folder) {
    if (folder == null) return;
    final marker = File('${folder.path}/.nomedia');
    try {
      if (hidesFromGallery) {
        if (!marker.existsSync()) {
          folder.createSync(recursive: true);
          marker.writeAsBytesSync(const [], flush: true);
        }
      } else if (marker.existsSync()) {
        marker.deleteSync();
      }
    } on FileSystemException {
      // A folder that can't be written keeps its images visible; nothing else depends on it.
    }
  }
  List<DownloadLocation> _folders = [];

  final _workers = <WorkDownloadMode, Future<void>>{};
  final _active = <WorkDownloadMode, (String, _Run)>{};
  bool _suspended = false;

  /// The run in progress for a mode, for tests.
  Future<void>? worker(WorkDownloadMode mode) => _workers[mode];

  String enqueue(NativeGallery gallery) {
    final host = _configuredHost();
    return _add(WorkDownload(key: '$host:${gallery.id}', mode: WorkDownloadMode.manga, title: gallery.title, origin: host, gallery: gallery));
  }

  String enqueuePost(BooruPost post, BooruServer server) => _add(
    WorkDownload(
      key: '${server.canonicalAddress}:${post.postID}',
      mode: WorkDownloadMode.booru,
      title: '${server.displayName} #${post.postID}',
      origin: server.canonicalAddress,
      server: server,
      post: post,
    ),
  );

  String _add(WorkDownload item) {
    final existing = items.where((other) => other.mode == item.mode && other.key == item.key).firstOrNull;
    if (existing != null) return existing.id;
    if (storageError != null) return item.id;
    _place(item);
    items.insert(0, item);
    if (_persist()) _schedule(item.mode);
    notifyListeners();
    return item.id;
  }

  Directory folder(WorkDownload item) => Directory('${(root(item.location) ?? directory).path}/${item.path ?? item.id}');
  List<File> urls(WorkDownload item) => [for (final name in item.files) File('${folder(item).path}/$name')];

  WorkDownload? _item(String id) => items.where((item) => item.id == id).firstOrNull;

  void pause(String id) {
    final item = _item(id);
    if (item == null || (item.status != WorkDownloadStatus.queued && item.status != WorkDownloadStatus.downloading)) return;
    item.status = WorkDownloadStatus.paused;
    final active = _active[item.mode];
    if (active != null && active.$1 == id) active.$2.cancelled = true;
    _persist();
    notifyListeners();
  }

  void resume(String id) {
    final item = _item(id);
    if (item == null || (item.status != WorkDownloadStatus.failed && item.status != WorkDownloadStatus.paused)) return;
    item.status = WorkDownloadStatus.queued;
    item.error = null;
    if (_persist()) _schedule(item.mode);
    notifyListeners();
  }

  void remove(String id) {
    final item = _item(id);
    if (item == null) return;
    pause(id);
    try {
      final location = folder(item);
      if (location.existsSync()) location.deleteSync(recursive: true);
      items.removeWhere((other) => other.id == id);
      _persist();
    } on Object catch (error) {
      storageError = '$error';
    }
    notifyListeners();
  }

  /// Leaving the app pauses every running download; nothing starts until it returns.
  void setBackground(bool background) {
    _suspended = background;
    if (background) {
      for (final item in items.toList()) {
        if (item.status == WorkDownloadStatus.queued || item.status == WorkDownloadStatus.downloading) pause(item.id);
      }
    }
  }

  bool _persist() {
    try {
      final manifest = manifestFile(directory);
      final temporary = File('${manifest.path}.tmp');
      temporary.writeAsBytesSync(encodeSwiftJson([for (final item in items) item.toJson()]), flush: true);
      temporary.renameSync(manifest.path);
      storageError = null;
      return true;
    } on Object catch (error) {
      storageError = '$error';
      return false;
    }
  }

  // MARK: - Location

  List<DownloadLocation> get locations => [DownloadLocation.onDevice, ..._folders];
  DownloadLocation get currentLocation => locations.firstWhere((location) => location.id == _current, orElse: () => DownloadLocation.onDevice);

  /// Downloads saved somewhere other than the current location, which a move can bring over.
  List<WorkDownload> get elsewhere => [
    for (final item in items)
      if (item.location != _current) item,
  ];

  /// The ones a move takes now: everything elsewhere except running downloads.
  List<WorkDownload> get movable => [
    for (final item in elsewhere)
      if (!item.status.canPause) item,
  ];

  Directory? root(String? location) {
    if (location == null) return directory;
    if (location == DownloadLocation.files) return filesRoot;
    final path = _folders.where((folder) => folder.id == location).firstOrNull?.path;
    return path == null ? null : Directory(path);
  }

  void setLocation(String id) {
    if (!locations.any((location) => location.id == id)) return;
    _current = id;
    locationError = null;
    _saveSettings();
    notifyListeners();
  }

  /// Adds a folder the person picked and saves new downloads there, once a file can be written in it.
  void addFolder(String path, String name) {
    try {
      final probe = File('$path/.tegnal-${uuidString()}');
      probe.writeAsBytesSync(const [], flush: true);
      probe.deleteSync();
      final known = _folders.where((folder) => folder.path == path).firstOrNull;
      if (known != null) {
        _current = known.id;
      } else {
        final location = DownloadLocation(id: 'folder:${uuidString()}', name: name, path: path);
        _folders = [..._folders, location];
        _current = location.id;
      }
      locationError = null;
      _saveSettings();
    } on Object {
      refuseFolder();
    }
    notifyListeners();
  }

  /// Says a picked folder can't take downloads.
  void refuseFolder() {
    locationError = L10n.text("TEGNAL can't save files in this folder. Choose a folder in Download, Documents or Pictures on this device.");
    notifyListeners();
  }

  /// Forgets a chosen folder that no download is saved in.
  void removeFolder(String id) {
    if (id == DownloadLocation.files || items.any((item) => item.location == id)) return;
    _folders = [
      for (final folder in _folders)
        if (folder.id != id) folder,
    ];
    if (_current == id) _current = DownloadLocation.files;
    _saveSettings();
    notifyListeners();
  }

  void _saveSettings() {
    try {
      settingsFile(directory).writeAsStringSync(
        jsonEncode({
          'current': _current,
          'folders': [for (final folder in _folders) folder.toJson()],
          'hidesFromGallery': hidesFromGallery,
        }),
        flush: true,
      );
    } on Object catch (error) {
      locationError = '$error';
    }
  }

  /// Gives a download a folder named after the work in the current location.
  void _place(WorkDownload item) {
    final root = this.root(_current);
    if (root == null) {
      item.location = null;
      item.path = null;
      return;
    }
    final group = L10n.text(item.mode == WorkDownloadMode.manga ? 'Comics' : 'Images');
    final gallery = item.gallery;
    final name = gallery != null ? '${fileName(gallery.title, 60)} [${gallery.id}]' : fileName(item.title, 80);
    final taken = {
      for (final other in items)
        if (other.location == _current && other.path != null) other.path!,
    };
    var candidate = name;
    for (
      var number = 2;
      taken.contains('$group/$candidate') || FileSystemEntity.typeSync('${root.path}/$group/$candidate') != FileSystemEntityType.notFound;
      number++
    ) {
      candidate = '$name ($number)';
    }
    item.location = _current;
    item.path = '$group/$candidate';
  }

  /// A name the file system and file managers accept: no slashes or colons, no leading dot.
  static String fileName(String text, int limit) {
    final cleaned = text.replaceAll(RegExp(r'[/\\:*?"<>|\x00-\x1F\x7F]'), ' ');
    var name = splitWhitespace(cleaned).join(' ');
    while (name.startsWith('.')) {
      name = name.substring(1);
    }
    final characters = name.runes.toList();
    if (characters.length > limit) name = String.fromCharCodes(characters.take(limit)).trim();
    return name.isEmpty ? 'Download' : name;
  }

  /// Moves downloads saved elsewhere, including the app's own storage, into the current location
  /// without downloading them again. Running downloads are left where they are.
  Future<void> moveElsewhereHere() async {
    final targets = [for (final item in movable) item.id];
    if (moving != null || targets.isEmpty) return;
    locationError = null;
    for (final (done, id) in targets.indexed) {
      moving = (done: done, total: targets.length);
      notifyListeners();
      final item = _item(id);
      if (item == null) continue;
      final source = folder(item);
      final placed = WorkDownload(id: item.id, key: item.key, mode: item.mode, title: item.title, origin: item.origin, gallery: item.gallery);
      _place(placed);
      final destination = folder(placed);
      try {
        if (source.existsSync()) {
          destination.parent.createSync(recursive: true);
          final from = source.path, to = destination.path;
          await Isolate.run(() => moveDownloadFolder(from, to));
        }
        item.location = placed.location;
        item.path = placed.path;
        _persist();
      } on Object catch (error) {
        locationError = '$error';
        break;
      }
    }
    moving = null;
    notifyListeners();
  }

  void _schedule(WorkDownloadMode mode) {
    if (_suspended || _workers.containsKey(mode)) return;
    final item = items.lastWhere((item) => item.mode == mode && item.status == WorkDownloadStatus.queued, orElse: () => _none);
    if (identical(item, _none)) return;
    final run = _Run();
    _active[mode] = (item.id, run);
    _workers[mode] = () async {
      await Future<void>.value();
      await _run(item, run);
      transferProgress.remove(item.id);
      _workers.remove(mode);
      _active.remove(mode);
      notifyListeners();
      _schedule(mode);
    }();
  }

  static final _none = WorkDownload(key: '', mode: WorkDownloadMode.manga, title: '', origin: '');

  void _update(String id, _Run run, void Function(WorkDownload item) change) {
    if (run.cancelled) throw const CancellationError();
    final item = _item(id);
    if (item == null) throw const CancellationError();
    change(item);
    notifyListeners();
    if (!_persist()) throw const FileSystemException('Unable to save downloads');
  }

  Future<void> _run(WorkDownload item, _Run run) async {
    try {
      // Not started yet: it goes wherever downloads are saved now.
      if (item.files.isEmpty && item.location != _current && !folder(item).existsSync()) {
        final placed = WorkDownload(id: item.id, key: item.key, mode: item.mode, title: item.title, origin: item.origin, gallery: item.gallery);
        _place(placed);
        _update(item.id, run, (item) {
          item.location = placed.location;
          item.path = placed.path;
        });
      }
      _update(item.id, run, (item) {
        item.status = WorkDownloadStatus.downloading;
        item.error = null;
      });
      folder(item).createSync(recursive: true);
      if (hidesFromGallery) _markGalleryHidden(root(item.location));
      final gallery = item.gallery;
      final server = item.server, post = item.post;
      if (gallery != null) {
        // Do not silently resume a gallery against a different configured site.
        if (item.origin != _configuredHost()) throw ContentError.invalidResponse;
        for (final (index, page) in gallery.pages.indexed) {
          if (run.cancelled) throw const CancellationError();
          if (index < item.files.length && urls(item)[index].existsSync()) continue;
          final data = await manga.image(_indexed(page, index), galleryID: gallery.id, thumbnail: false);
          if (run.cancelled) throw const CancellationError();
          final ext = imageExtension(data);
          _save(data, '${'${index + 1}'.padLeft(5, '0')}.$ext', item, index, run);
          // Match the site's download pacing instead of flooding its servers.
          if (index + 1 < gallery.pages.length && pageDelay > Duration.zero) await Future<void>.delayed(pageDelay);
        }
      } else if (server != null && post != null) {
        final booru = this.booru;
        if (booru == null) throw ContentError.invalidResponse;
        final resolved = post.fileURL == null ? await booru.details(server, post) : post;
        _update(item.id, run, (item) => item.post = resolved);
        final url = resolved.fileURL == null ? null : Uri.tryParse(resolved.fileURL!);
        if (url == null || url.scheme != 'https') throw ContentError.invalidResponse;
        final name = await booru.download(
          url,
          server: server,
          post: resolved,
          folder: folder(item),
          progress: (fraction) {
            if (_active[item.mode]?.$1 != item.id) return;
            transferProgress[item.id] = fraction;
            notifyListeners();
          },
        );
        _update(item.id, run, (item) {
          item.files = [name];
          item.bytes = _fileBytes(folder(item), [name]);
        });
      } else {
        throw ContentError.invalidResponse;
      }
      _update(item.id, run, (item) => item.status = WorkDownloadStatus.completed);
    } on Object catch (error) {
      final current = _item(item.id);
      if (!run.cancelled && current != null) {
        current.status = WorkDownloadStatus.failed;
        current.error = error is ContentError ? error.errorDescription : ContentError.message(error);
        _persist();
        notifyListeners();
      }
    }
  }

  static GalleryPage _indexed(GalleryPage page, int index) => GalleryPage(
    hash: page.hash,
    name: page.name,
    width: page.width,
    height: page.height,
    hasAVIF: page.hasAVIF,
    imageURL: page.imageURL,
    thumbnailURL: page.thumbnailURL,
    index: index,
    sourceSite: page.sourceSite,
  );

  void _save(Uint8List data, String name, WorkDownload item, int index, _Run run) {
    if (run.cancelled) throw const CancellationError();
    final file = File('${folder(item).path}/$name');
    final temporary = File('${file.path}.tmp');
    temporary.writeAsBytesSync(data, flush: true);
    temporary.renameSync(file.path);
    _update(item.id, run, (item) {
      if (index < item.files.length) {
        item.files[index] = name;
      } else {
        item.files.add(name);
      }
      item.bytes = _fileBytes(folder(item), item.files);
    });
  }

  static int _fileBytes(Directory folder, List<String> names) => names.fold(0, (sum, name) {
    final file = File('${folder.path}/$name');
    return sum + (file.existsSync() ? file.lengthSync() : 0);
  });

  /// The file extension the image format prefers, read from the bytes themselves,
  /// as ImageIO names the type. Anything that is not an image is refused.
  static String imageExtension(Uint8List data) {
    bool starts(List<int> prefix, [int offset = 0]) {
      if (data.length < offset + prefix.length) return false;
      for (var index = 0; index < prefix.length; index++) {
        if (data[offset + index] != prefix[index]) return false;
      }
      return true;
    }

    if (starts([0xFF, 0xD8, 0xFF])) return 'jpeg';
    if (starts([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) return 'png';
    if (starts([0x47, 0x49, 0x46, 0x38])) return 'gif';
    if (starts([0x52, 0x49, 0x46, 0x46]) && starts([0x57, 0x45, 0x42, 0x50], 8)) return 'webp';
    if (starts([0x42, 0x4D])) return 'bmp';
    if (starts([0x49, 0x49, 0x2A, 0x00]) || starts([0x4D, 0x4D, 0x00, 0x2A])) return 'tiff';
    if (starts([0x66, 0x74, 0x79, 0x70], 4) && data.length >= 12) {
      final brand = String.fromCharCodes(data.sublist(8, 12));
      if (brand == 'avif' || brand == 'avis') return 'avif';
      if (const {'heic', 'heix', 'hevc', 'hevx', 'mif1', 'msf1'}.contains(brand)) return 'heic';
    }
    throw ContentError.unsupportedFormat;
  }
}

/// `DownloadedContentSource`: reads only durable local files; never falls back to the
/// network or the viewer cache.
class DownloadedContentSource extends ContentProviding {
  DownloadedContentSource({required this.item, required this.folder});
  final WorkDownload item;
  final Directory folder;

  @override
  NativeGallery? cachedGallery(int id) => item.gallery?.id == id ? item.gallery : null;

  @override
  Future<NativeGallery> gallery(int id) async => cachedGallery(id) ?? (throw ContentError.galleryNotFound);

  @override
  Future<Uint8List> image(GalleryPage page, {required int galleryID, required bool thumbnail}) async {
    final gallery = cachedGallery(galleryID);
    final index = gallery?.pages.indexOf(page) ?? -1;
    if (gallery == null || index < 0 || index >= item.files.length) throw ContentError.invalidResponse;
    return File('${folder.path}/${item.files[index]}').readAsBytes();
  }

  @override
  Future<GalleryBatch> list(GalleryQuery query, {required int offset, required int count}) async => const GalleryBatch(ids: [], hasMore: false);
}
