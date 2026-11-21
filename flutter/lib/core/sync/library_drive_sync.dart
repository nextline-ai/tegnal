import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:google_sign_in_platform_interface/google_sign_in_platform_interface.dart';
import 'package:http/http.dart' as http;

import '../booru/booru_store.dart';
import '../storage/app_database.dart';
import '../storage/folder_rules.dart';
import '../support/l10n.dart';
import '../support/preferences.dart';
import '../support/swift_json.dart';
import 'library_sync_adapter.dart';
import 'library_sync_record.dart';

/// The Google account Drive sync uses. Only its identity: tokens stay in the SDK.
class DriveAccount {
  const DriveAccount({required this.id, required this.email});
  final String id;
  final String email;
}

/// One sync document in the `TEGNAL` folder.
class DriveFile {
  const DriveFile({required this.id, required this.name, required this.size, required this.modified});
  final String id;
  final String name;
  final int size;
  final String modified;
}

/// The account is signed out, or no longer grants Drive file access.
class DriveAuthorizationError implements Exception {
  const DriveAuthorizationError();
}

/// The account was chosen but Drive file access was not granted. Carries the SDK's code.
class DriveConsentError implements Exception {
  const DriveConsentError(this.reason);
  final String reason;
  @override
  String toString() => 'DriveConsentError($reason)';
}

/// A Drive request failed. Carries only the HTTP status, never a body or header.
class DriveRequestError implements Exception {
  const DriveRequestError(this.status);
  final int status;
  @override
  String toString() => 'DriveRequestError($status)';
}

/// Account and file access for library sync, so tests never contact Google.
abstract interface class DriveBackend {
  /// False when this build carries no OAuth client ID.
  bool get isConfigured;

  /// Restores a previously connected account without showing any UI. [known] is the account
  /// the app remembered when it connected; without it the backend finds the account itself.
  Future<DriveAccount?> restore({DriveAccount? known});

  /// Lets a person choose an account and grant Drive file access.
  Future<DriveAccount> connect();

  /// Signs out and revokes this app's access where the SDK can.
  Future<void> disconnect();

  /// The app-created, visible `TEGNAL` folder, made on first use.
  Future<String> folder();
  Future<List<DriveFile>> documents(String folder);
  Future<Uint8List> download(String fileID);

  /// Writes [name] in [folder], replacing [fileID] when given. Returns the file's ID.
  Future<String> upload(String folder, String name, Uint8List data, {String? fileID});
}

/// What the backup vault needs from the same Drive folder beyond library sync: other file names,
/// any content type, and removal. [GoogleDriveBackend] has it; the sync fakes do not need it.
abstract interface class DriveBackupFiles {
  /// The `.tegnalbackup` files in [folder].
  Future<List<DriveFile>> backupFiles(String folder);

  /// Writes [data] as [name] in [folder], replacing [fileID] when given. Returns the file's ID.
  Future<String> uploadBackup(String folder, String name, Uint8List data, {String? fileID});
  Future<void> deleteFile(String fileID);
}

/// Google Sign-In (Android's Credential Manager and authorization APIs) plus the Drive
/// REST API with the non-sensitive `drive.file` scope.
class GoogleDriveBackend implements DriveBackend, DriveBackupFiles {
  GoogleDriveBackend({String? serverClientID, http.Client? client})
    : _serverClientID = serverClientID ?? const String.fromEnvironment('GOOGLE_WEB_CLIENT_ID'),
      _client = client ?? http.Client();

  static const scopes = ['https://www.googleapis.com/auth/drive.file'];
  static const _folderType = 'application/vnd.google-apps.folder';
  static const _api = 'https://www.googleapis.com/drive/v3/files';
  static const _upload = 'https://www.googleapis.com/upload/drive/v3/files';

  final String _serverClientID;
  final http.Client _client;
  Future<void>? _initialized;
  DriveAccount? _account;
  String? _folder;

  @override
  bool get isConfigured => _serverClientID.isNotEmpty;

  Future<void> _initialize() => _initialized ??= GoogleSignIn.instance.initialize(serverClientId: _serverClientID);

  DriveAccount _identity(GoogleSignInAccount account) => DriveAccount(id: account.id, email: account.email);

  /// A Drive token for [account] through Android's authorization API alone, never Credential
  /// Manager, so it shows no sign-in sheet. Null when access was not granted (or was removed).
  Future<String?> _token(DriveAccount account) async {
    final data = await GoogleSignInPlatform.instance.clientAuthorizationTokensForScopes(
      ClientAuthorizationTokensForScopesParameters(
        request: AuthorizationRequestDetails(scopes: scopes, userId: account.id, email: account.email, promptIfUnauthorized: false),
      ),
    );
    return data?.accessToken;
  }

  @override
  Future<DriveAccount?> restore({DriveAccount? known}) async {
    if (!isConfigured) return null;
    await _initialize();
    if (known != null) {
      // The account connected before: its Drive access is checked quietly, with no sign-in.
      if (await _token(known) == null) return null;
      _account = known;
      return known;
    }
    // Connected before the app remembered the account: one lightweight sign-in finds it.
    final account = await GoogleSignIn.instance.attemptLightweightAuthentication();
    if (account == null) return null;
    // Restoring never asks for permission; an account without Drive access is not connected.
    if (await account.authorizationClient.authorizationForScopes(scopes) == null) return null;
    return _account = _identity(account);
  }

  @override
  Future<DriveAccount> connect() async {
    if (!isConfigured) throw const DriveAuthorizationError();
    await _initialize();
    final account = await GoogleSignIn.instance.authenticate(scopeHint: scopes);
    try {
      await account.authorizationClient.authorizeScopes(scopes);
    } on GoogleSignInException catch (error) {
      // The account was chosen; a failure granting Drive access is never a silent cancel.
      throw DriveConsentError('${error.code.name}${error.description == null ? '' : ' (${error.description})'}');
    }
    _folder = null;
    return _account = _identity(account);
  }

  @override
  Future<void> disconnect() async {
    _account = null;
    _folder = null;
    if (!isConfigured) return;
    await _initialize();
    try {
      await GoogleSignIn.instance.disconnect();
    } on Object {
      // An offline device signs out locally; access can also be removed from the account.
      await GoogleSignIn.instance.signOut();
    }
  }

  Future<String> _bearer() async {
    final account = _account;
    if (account == null) throw const DriveAuthorizationError();
    final token = await _token(account);
    if (token == null) throw const DriveAuthorizationError();
    return token;
  }

  Future<http.Response> _send(Future<http.Response> Function(Map<String, String> headers) request) async {
    Map<String, String> headers(String token) => {'Authorization': 'Bearer $token'};
    var token = await _bearer();
    var response = await request(headers(token));
    if (response.statusCode == 401) {
      // A cached token can be stale; drop it once and ask again without prompting.
      await GoogleSignInPlatform.instance.clearAuthorizationToken(ClearAuthorizationTokenParams(accessToken: token));
      token = await _bearer();
      response = await request(headers(token));
    }
    if (response.statusCode == 401 || response.statusCode == 403) throw const DriveAuthorizationError();
    if (response.statusCode >= 300) throw DriveRequestError(response.statusCode);
    return response;
  }

  static String _quoted(String value) => "'${value.replaceAll(r'\', r'\\').replaceAll("'", r"\'")}'";

  @override
  Future<String> folder() async {
    final cached = _folder;
    if (cached != null) return cached;
    final query = Uri.parse(_api)
        .replace(queryParameters: {'q': "name = 'TEGNAL' and mimeType = '$_folderType' and trashed = false", 'fields': 'files(id)', 'spaces': 'drive'});
    final found = jsonObject(jsonDecode((await _send((headers) => _client.get(query, headers: headers))).body)).list('files', jsonObject);
    if (found.isNotEmpty) return _folder = found.first.string('id');
    final created = await _send(
      (headers) => _client.post(
        Uri.parse(_api).replace(queryParameters: {'fields': 'id'}),
        headers: {...headers, 'Content-Type': 'application/json'},
        body: jsonEncode({'name': 'TEGNAL', 'mimeType': _folderType}),
      ),
    );
    return _folder = jsonObject(jsonDecode(created.body)).string('id');
  }

  @override
  Future<List<DriveFile>> documents(String folder) => _list(folder, (name) => name.startsWith('library-') && name.endsWith('.json'));

  @override
  Future<List<DriveFile>> backupFiles(String folder) => _list(folder, (name) => name.startsWith('tegnal_') && name.endsWith('.tegnalbackup'));

  @override
  Future<void> deleteFile(String fileID) async {
    final uri = Uri.parse('$_api/${Uri.encodeComponent(fileID)}');
    await _send((headers) => _client.delete(uri, headers: headers));
  }

  Future<List<DriveFile>> _list(String folder, bool Function(String name) wanted) async {
    final result = <DriveFile>[];
    String? page;
    do {
      final uri = Uri.parse(_api).replace(
        queryParameters: {
          'q': '${_quoted(folder)} in parents and trashed = false',
          'fields': 'nextPageToken,files(id,name,size,modifiedTime)',
          'pageSize': '100',
          'pageToken': ?page,
        },
      );
      final body = jsonObject(jsonDecode((await _send((headers) => _client.get(uri, headers: headers))).body));
      for (final file in body.list('files', jsonObject)) {
        final name = file.string('name');
        if (!wanted(name)) continue;
        result.add(
          DriveFile(
            id: file.string('id'),
            name: name,
            size: int.tryParse(file.stringOrNull('size') ?? '') ?? 0,
            modified: file.stringOrNull('modifiedTime') ?? '',
          ),
        );
      }
      page = body.stringOrNull('nextPageToken');
    } while (page != null);
    return result;
  }

  @override
  Future<Uint8List> download(String fileID) async {
    final uri = Uri.parse('$_api/${Uri.encodeComponent(fileID)}').replace(queryParameters: {'alt': 'media'});
    return (await _send((headers) => _client.get(uri, headers: headers))).bodyBytes;
  }

  @override
  Future<String> upload(String folder, String name, Uint8List data, {String? fileID}) => _write(folder, name, data, 'application/json', fileID);

  @override
  Future<String> uploadBackup(String folder, String name, Uint8List data, {String? fileID}) => _write(folder, name, data, 'application/octet-stream', fileID);

  Future<String> _write(String folder, String name, Uint8List data, String mimeType, String? fileID) async {
    if (fileID != null) {
      final uri = Uri.parse('$_upload/${Uri.encodeComponent(fileID)}').replace(queryParameters: {'uploadType': 'media', 'fields': 'id'});
      final response = await _send((headers) => _client.patch(uri, headers: {...headers, 'Content-Type': mimeType}, body: data));
      return jsonObject(jsonDecode(response.body)).string('id');
    }
    const boundary = 'tegnal-library-sync';
    final metadata = jsonEncode({
      'name': name,
      'parents': [folder],
      'mimeType': mimeType,
    });
    final body = BytesBuilder()
      ..add(utf8.encode('--$boundary\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n$metadata\r\n--$boundary\r\nContent-Type: $mimeType\r\n\r\n'))
      ..add(data)
      ..add(utf8.encode('\r\n--$boundary--'));
    final uri = Uri.parse(_upload).replace(queryParameters: {'uploadType': 'multipart', 'fields': 'id'});
    final response = await _send(
      (headers) => _client.post(uri, headers: {...headers, 'Content-Type': 'multipart/related; boundary=$boundary'}, body: body.toBytes()),
    );
    return jsonObject(jsonDecode(response.body)).string('id');
  }
}

/// What a pass read from Drive (`CloudLibraryFiles.ReadState`).
class DriveReadState {
  final documents = <LibrarySyncDocument>[];
  int unreadableFiles = 0;
  int storedBytes = 0;
  int documentCount = 0;
}

/// `LibraryCloudSync` on Google Drive. Each device writes its own coordinated document
/// into the `TEGNAL` folder; independent additions merge, and timestamped removals
/// persist so an offline device cannot resurrect deleted items. Off until a person
/// connects an account.
class LibraryDriveSync extends ChangeNotifier {
  LibraryDriveSync({
    required this.backend,
    required this.database,
    required this.booru,
    required this.defaults,
    required this.booruDefaults,
    required this.directory,
    this.onApplied,
    this.interval = const Duration(seconds: 60),
  }) : _enabled = defaults.boolean(enabledKey) ?? false {
    // The installation ID lives beside the ledger, which device backups leave out, so a
    // restored or transferred device writes its own document instead of another's.
    final file = File('${directory.path}/installation');
    var installation = file.existsSync() ? file.readAsStringSync().trim() : '';
    if (installation.isEmpty) {
      installation = uuidString();
      directory.createSync(recursive: true);
      file.writeAsStringSync(installation);
    }
    _device = _digest(utf8.encode(installation));
    _status = !backend.isConfigured
        ? L10n.text('Google Drive backup is coming soon. For now, back up manually to a local file in Library Management.')
        : _enabled
        ? L10n.text('Waiting for Google Drive')
        : L10n.text('Sync Off');
  }

  static const enabledKey = 'drive.librarySyncEnabled';

  /// Set once a person connects a Google account and cleared when they disconnect. Without it
  /// the app never contacts Google Sign-In, so a fresh install shows no account prompt.
  static const connectedKey = 'drive.accountConnected';

  /// The connected account's ID and email, so a launch restores it without a sign-in sheet.
  static const accountKey = 'drive.account';

  DriveAccount? get _remembered {
    final Object? value;
    try {
      value = jsonDecode(defaults.string(accountKey) ?? '');
    } on FormatException {
      return null;
    }
    if (value is! Map || value['id'] is! String || value['email'] is! String) return null;
    return DriveAccount(id: value['id'] as String, email: value['email'] as String);
  }

  void _remember(DriveAccount? account) =>
      account == null ? defaults.remove(accountKey) : defaults.set(accountKey, jsonEncode({'id': account.id, 'email': account.email}));

  /// Set by a restore (`UpdateBackup.libraryReplacedKey`); the next sync sends the restored library as the newest state.
  static const replacedKey = 'backup.libraryReplacedAt';

  /// How long the signal is honored; after it, a normal capture handles the restored library.
  static const replacedLifetime = Duration(days: 1);

  final DriveBackend backend;
  final AppDatabase database;
  final BooruStore booru;
  final Preferences defaults;
  final Preferences booruDefaults;

  /// Holds the installation ID and each account's ledger, the comparison point it syncs
  /// from. The app passes `<files>/drive-sync`, which device backups exclude.
  final Directory directory;

  /// Runs after remote changes were written: reload synced preferences and screens.
  final void Function()? onApplied;
  final Duration interval;

  late final String _device;
  String _status = '';
  bool _syncing = false;
  bool _enabled;
  DateTime? _lastSynced;
  int? _documentBytes;
  int? _cloudBytes;
  int _cloudDocumentCount = 0;
  DriveAccount? _account;
  String? _accountID;
  String? _ownFileID;
  LibrarySyncLedger _ledger = LibrarySyncLedger();
  bool _needsUpload = false;
  int _accessGeneration = 0;
  final _cache = LibrarySyncSnapshotCache();
  final _downloads = <String, (String, LibrarySyncDocument)>{};
  Timer? _timer;
  bool _active = false;

  String get status => _status;
  bool get syncing => _syncing;
  bool get isConfigured => backend.isConfigured;
  DateTime? get lastSynced => _lastSynced;
  int? get documentBytes => _documentBytes;
  int? get cloudBytes => _cloudBytes;
  int get cloudDocumentCount => _cloudDocumentCount;
  DriveAccount? get account => _account;
  bool get enabled => _enabled;

  set enabled(bool value) {
    _enabled = value;
    defaults.set(enabledKey, value);
    if (!value) {
      _invalidateAccess();
      _status = L10n.text('Sync Off');
    } else if (!_syncing) {
      _status = L10n.text('Waiting for Google Drive');
    }
    _schedule();
    notifyListeners();
  }

  /// Restoring a backup changes both databases; the next pass captures a fresh snapshot.
  void libraryRestored() {
    _cache.invalidate();
    _needsUpload = true;
  }

  // Installs from before the flag kept sync on only after connecting.
  bool get _connected => (defaults.boolean(connectedKey) ?? false) || _enabled;

  /// Finds a previously connected account without asking anything.
  Future<void> restore() async {
    if (!isConfigured || !_connected) return;
    try {
      _account = await backend.restore(known: _remembered);
      if (_account != null) _remember(_account);
    } on Object {
      _account = null;
    }
    if (_account == null && _enabled) _status = L10n.text('Sign in to Google to sync.');
    notifyListeners();
  }

  /// Asks for an account and Drive access, then turns sync on and runs a first pass.
  /// Returns an error to show, or null; a cancelled choice changes nothing.
  Future<String?> connect() async {
    if (!isConfigured) return L10n.text('Google Drive backup is coming soon. For now, back up manually to a local file in Library Management.');
    try {
      _account = await backend.connect();
      defaults.set(connectedKey, true);
      _remember(_account);
    } on DriveConsentError catch (error) {
      debugPrint('Google Drive access: ${error.reason}');
      return L10n.text('Unable to connect Google Account: %@', [error.reason]);
    } on GoogleSignInException catch (error) {
      if (error.code == GoogleSignInExceptionCode.canceled) return null;
      debugPrint('Google sign-in: ${error.code.name} ${error.description ?? ''}');
      return L10n.text('Unable to connect Google Account: %@', [error.code.name]);
    } on Object catch (error) {
      debugPrint('Google Drive connect: $error');
      return L10n.text('Unable to connect Google Account: %@', [L10n.text('Unable to sync now. Your data is saved on this device.')]);
    }
    _invalidateAccess();
    enabled = true;
    await synchronize();
    return null;
  }

  /// Stops syncing and signs out. Data here and in Drive stays.
  Future<void> disconnect() async {
    enabled = false;
    _account = null;
    defaults.remove(connectedKey);
    _remember(null);
    notifyListeners();
    try {
      await backend.disconnect();
    } on Object {
      // The account can also be removed from the app's connected access later.
    }
  }

  /// Syncs every [interval] while the app is in front and sync is on.
  void setActive(bool active) {
    _active = active;
    _schedule();
    if (active && _enabled) unawaited(synchronize());
  }

  void _schedule() {
    _timer?.cancel();
    _timer = _active && _enabled ? Timer.periodic(interval, (_) => synchronize()) : null;
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _invalidateAccess() {
    _accessGeneration += 1;
    _accountID = null;
    _ownFileID = null;
    _ledger = LibrarySyncLedger();
    _cache.invalidate();
    _downloads.clear();
    _needsUpload = false;
    _cloudBytes = null;
    _cloudDocumentCount = 0;
  }

  File _ledgerFile(String accountID) => File('${directory.path}/drive-sync-$accountID.json');

  Future<void> synchronize() async {
    if (!_enabled || _syncing || !isConfigured) return;
    _syncing = true;
    notifyListeners();
    try {
      await _synchronize();
    } on DriveAuthorizationError {
      if (_enabled) {
        _account = null;
        _invalidateAccess();
        _status = L10n.text('Sign in to Google to sync.');
      }
    } on Object {
      if (_enabled) _status = L10n.text('Unable to sync now. Your data is saved on this device.');
    } finally {
      _syncing = false;
      notifyListeners();
    }
  }

  Future<void> _synchronize() async {
    if (_account == null && _connected) {
      _account = await backend.restore(known: _remembered);
      if (_account != null) _remember(_account);
    }
    final account = _account;
    if (account == null) {
      _invalidateAccess();
      _status = L10n.text('Sign in to Google to sync.');
      return;
    }
    final accountID = _digest(utf8.encode(account.id));
    if (_accountID != accountID) {
      final local = _ledgerFile(accountID);
      if (local.existsSync()) {
        _ledger = LibrarySyncLedger.fromJson(decodeJsonValue(local.readAsBytesSync()));
        if (_ledger.version != 1) throw const LibrarySyncError();
      } else {
        _ledger = LibrarySyncLedger();
      }
      _accountID = accountID;
      _ownFileID = null;
      _downloads.clear();
      _needsUpload = true;
    }
    final generation = _accessGeneration;
    bool current() => generation == _accessGeneration && _enabled && _accountID == accountID;

    final folder = await backend.folder();
    final incoming = await _read(folder);
    if (!current()) return;

    final adapter = LibrarySyncAdapter(manga: database, booru: booru, mangaDefaults: defaults, booruDefaults: booruDefaults);
    // Take a fresh snapshot after the downloads so edits made meanwhile win.
    _cloudBytes = incoming.storedBytes;
    _cloudDocumentCount = incoming.documentCount;
    final before = _ledger.changes;
    // The first sync after a restore sends the restored library as the newest state.
    var replacedAt = (defaults.object(replacedKey) as num?)?.toDouble();
    // A signal that waited for days (sync was off or signed out) would stamp today's rows with the restore's old
    // time, and edits made since would lose to other devices. Dropped, the normal capture stamps what differs now.
    if (replacedAt != null && unixSeconds() - replacedAt > replacedLifetime.inSeconds) {
      defaults.remove(replacedKey);
      replacedAt = null;
    }
    final next = _ledger.copy();
    if (replacedAt != null) {
      next.captureReplacement(_cache.snapshot(adapter), device: _device, at: replacedAt);
    } else {
      next.capture(_cache.snapshot(adapter), device: _device);
    }
    final captured = Map.of(next.changes);
    for (final document in incoming.documents) {
      next.merge(document.changes);
    }
    // Local snapshots are already sanitized; only incoming edits need normalizing.
    if (!changesEquality.equals(next.changes, captured)) next.changes = LibrarySyncAdapter.mediaFreeChanges(next.changes);
    if (!changesEquality.equals(next.changes, captured)) {
      adapter.apply(next.changes);
      // Older documents may still carry the shared import destination; publish the repair too.
      next.baseline = _cache.snapshot(adapter);
      booru.organizeLegacyImports();
      database.adoptLegacyRules();
      next.capture(_cache.snapshot(adapter), device: _device);
      booru.refresh();
      onApplied?.call();
    }
    final saveLedger = _needsUpload || !changesEquality.equals(before, next.changes) || !rowsEquality.equals(_ledger.baseline, next.baseline);
    _ledger = next;
    _needsUpload = _needsUpload || !changesEquality.equals(before, _ledger.changes);
    if (saveLedger) {
      final local = _ledgerFile(accountID);
      await local.parent.create(recursive: true);
      final staging = File('${local.path}.tmp');
      await staging.writeAsBytes(encodeJson(next.toJson(), escapingSlashes: false), flush: true);
      await staging.rename(local.path);
      if (!current()) return;
    }
    if (replacedAt != null) defaults.remove(replacedKey);
    if (_needsUpload) {
      final data = LibrarySyncDocument(changes: _ledger.changes).encode();
      _documentBytes = data.length;
      if (!current()) return;
      _ownFileID = await backend.upload(folder, 'library-$_device.json', data, fileID: _ownFileID);
      if (!current()) return;
      _needsUpload = false;
    }
    if (incoming.unreadableFiles > 0) {
      _status = L10n.text('Some Google Drive files could not be read. Other changes were merged. Try syncing again.');
    } else {
      _lastSynced = DateTime.now();
      _status = L10n.text('Google Drive Sync On');
    }
  }

  /// Reads every device's document; a file unchanged since the last pass is not downloaded again.
  Future<DriveReadState> _read(String folder) async {
    final state = DriveReadState();
    for (final file in await backend.documents(folder)) {
      state.storedBytes += file.size;
      state.documentCount += 1;
      if (file.name == 'library-$_device.json') _ownFileID ??= file.id;
      try {
        final cached = _downloads[file.id];
        if (cached != null && cached.$1 == file.modified && file.modified.isNotEmpty) {
          state.documents.add(cached.$2);
          continue;
        }
        if (file.size > LibrarySyncDocument.maximumBytes) throw const LibrarySyncError();
        final document = LibrarySyncDocument.decode(await backend.download(file.id));
        _downloads[file.id] = (file.modified, document);
        state.documents.add(document);
      } on DriveAuthorizationError {
        rethrow;
      } on Object {
        // One interrupted peer file must not block every healthy device.
        state.unreadableFiles += 1;
      }
    }
    return state;
  }

  static String _digest(List<int> data) => sha256.convert(data).toString();
}
