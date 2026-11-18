import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../storage/app_storage.dart';
import '../support/preferences.dart';
import '../support/secure_secret_store.dart';
import 'generation_client.dart';

/// The API key lives only in the Android Keystore (`GenerationKeychain`): never in preferences, backups,
/// sync, exports, files or logs.
class GenerationKeychain {
  GenerationKeychain([SecureStorage? storage]) : _storage = storage ?? KeystoreStorage();
  final SecureStorage _storage;

  static const _name = 'tegnal.generation.civitai';

  Future<String> read() async {
    try {
      return (await _storage.readAll())[_name] ?? '';
    } on Object {
      // An unreadable store behaves as no key.
      return '';
    }
  }

  Future<bool> save(String key) async {
    final trimmed = key.trim();
    try {
      if (trimmed.isEmpty) {
        await _storage.delete(_name);
      } else {
        await _storage.write(_name, trimmed);
      }
      return true;
    } on Object {
      return false;
    }
  }
}

/// Quality tags, things to avoid and settings as a model's own card recommends them (`GenerationPreset`).
class GenerationPreset {
  const GenerationPreset({required this.name, this.front = '', this.back = '', this.negative = '', required this.steps, required this.guidance});
  final String name;

  /// Written before the prompt.
  final String front;

  /// Written after the prompt.
  final String back;
  final String negative;
  final int steps;
  final double guidance;

  String get id => name;

  static const all = [
    GenerationPreset(name: 'Anima', front: 'masterpiece, best quality', negative: 'worst quality, low quality, blurry, bad anatomy, deformed hands', steps: 30, guidance: 4),
    GenerationPreset(
      name: 'NoobAI-XL',
      front: 'masterpiece, best quality, newest, absurdres, highres, safe',
      negative:
          'nsfw, worst quality, old, early, low quality, lowres, signature, username, logo, bad hands, mutated hands, mammal, anthro, furry, ambiguous form, feral, semi-anthro',
      steps: 28,
      guidance: 5.5,
    ),
    GenerationPreset(
      name: 'Illustrious XL',
      front: 'masterpiece, best quality',
      negative:
          'worst quality, comic, multiple views, bad quality, low quality, lowres, displeasing, very displeasing, bad anatomy, bad hands, scan artifacts, monochrome, greyscale, signature, twitter username, jpeg artifacts, 2koma, 4koma, guro, extra digits, fewer digits',
      steps: 28,
      guidance: 6,
    ),
    GenerationPreset(
      name: 'Animagine XL 4.0',
      back: 'masterpiece, high score, great score, absurdres',
      negative:
          'lowres, bad anatomy, bad hands, text, error, missing finger, extra digits, fewer digits, cropped, worst quality, low quality, low score, bad score, average score, signature, watermark, username, blurry',
      steps: 28,
      guidance: 5,
    ),
    GenerationPreset(name: 'Pony Diffusion V6 XL', front: 'score_9, score_8_up, score_7_up, score_6_up, score_5_up, score_4_up', steps: 25, guidance: 7),
  ];

  static List<String> _tags(String text) => [for (final part in text.split(',')) if (part.trim().isNotEmpty) part.trim()];

  /// The prompt with this preset's quality tags around it, and without any other preset's.
  String applied(String prompt) {
    final tags = _tags(prompt);
    final known = <String>{for (final preset in all) ...[..._tags(preset.front), ..._tags(preset.back)]};
    tags.removeWhere(known.contains);
    return [..._tags(front), ...tags, ..._tags(back)].join(', ');
  }
}

/// A picture made here, kept on this device with what it was made from (`GeneratedPicture`).
class GeneratedPicture {
  GeneratedPicture({
    String? id,
    required this.file,
    required this.prompt,
    required this.negative,
    required this.model,
    required this.modelName,
    required this.width,
    required this.height,
    required this.steps,
    required this.guidance,
    this.seed,
    DateTime? date,
  }) : id = id ?? _uuid(),
       date = date ?? DateTime.now();

  final String id;
  String file;
  final String prompt;
  final String negative;
  final String model;
  final String modelName;
  final int width;
  final int height;
  final int steps;
  final double guidance;
  final int? seed;
  final DateTime date;

  static String _uuid() {
    final random = math.Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0F) | 0x40;
    bytes[8] = (bytes[8] & 0x3F) | 0x80;
    final hex = bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}'.toUpperCase();
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'file': file,
    'prompt': prompt,
    'negative': negative,
    'model': model,
    'modelName': modelName,
    'width': width,
    'height': height,
    'steps': steps,
    'guidance': guidance,
    if (seed != null) 'seed': seed,
    'date': date.toUtc().toIso8601String(),
  };

  static GeneratedPicture? fromJson(Object? json) {
    if (json is! Map) return null;
    try {
      return GeneratedPicture(
        id: json['id'] as String,
        file: json['file'] as String,
        prompt: json['prompt'] as String,
        negative: json['negative'] as String,
        model: json['model'] as String,
        modelName: json['modelName'] as String,
        width: json['width'] as int,
        height: json['height'] as int,
        steps: json['steps'] as int,
        guidance: (json['guidance'] as num).toDouble(),
        seed: json['seed'] as int?,
        date: DateTime.tryParse(json['date'] as String? ?? '') ?? DateTime.now(),
      );
    } on Object {
      return null;
    }
  }
}

/// The generator's settings, recent models, saved pictures and API key (`GenerationStore`).
class GenerationStore extends ChangeNotifier {
  GenerationStore({required this.folder, required this.defaults, required this._keychain, this._transport}) {
    _settings = _loadSettings();
    // A generator set up before there was a suggested model, and never given one, starts with it too.
    if (_settings.model == null) _settings = _settings.use(GenerationModel.recommended);
    _recent = _loadRecent();
    _readIndex();
  }

  static const pictureLimit = 200;
  static const _settingsKey = 'generation.settings', _recentKey = 'generation.recentModels', _fieldKey = 'generation.modelField';

  static GenerationStore? _shared;

  /// The app's own store, over the app support folder and the Keystore. Created on first use.
  static GenerationStore shared(Preferences defaults) => _shared ??= _fixtureStore() ?? GenerationStore(
    folder: Directory('${AppStorage.container.path}/Generated'),
    defaults: defaults,
    keychain: GenerationKeychain(),
  );

  /// `TEGNAL_FIXTURE=generationUITest` (or `generationNoKey` for no key): the stand-in service, a temporary
  /// folder, preferences in memory and a key that never touches secure storage. Without the define this is null.
  static GenerationStore? _fixtureStore() {
    if (kReleaseMode) return null;
    final names = const String.fromEnvironment('TEGNAL_FIXTURE').split(',').map((name) => name.trim()).toSet();
    if (!names.contains('generationUITest') && !names.contains('generationNoKey')) return null;
    final storage = MemorySecureStorage();
    if (!names.contains('generationNoKey')) storage.values['tegnal.generation.civitai'] = 'fixture';
    return GenerationStore(
      folder: Directory.systemTemp.createTempSync('generation-fixture-'),
      defaults: MemoryPreferences(),
      keychain: GenerationKeychain(storage),
      transport: GenerationFixture.transport(),
    );
  }

  /// Forgets the shared store, for tests.
  @visibleForTesting
  static void resetShared() => _shared = null;

  final Directory folder;
  final Preferences defaults;
  final GenerationKeychain _keychain;
  final GenerationTransport? _transport;

  String _key = '';
  Future<void>? _loading;
  late GenerationSettings _settings;
  late List<GenerationModel> _recent;
  List<GeneratedPicture> _pictures = [];

  /// Reads the key from the Keystore. Safe to call again; the key is read once.
  Future<void> load() => _loading ??= () async {
    _key = await _keychain.read();
    notifyListeners();
  }();

  bool get hasKey => _key.isNotEmpty;
  List<GenerationModel> get recentModels => List.unmodifiable(_recent);
  List<GeneratedPicture> get pictures => List.unmodifiable(_pictures);
  GenerationSettings get settings => _settings;

  set settings(GenerationSettings value) {
    if (value == _settings) return;
    _settings = value;
    defaults.set(_settingsKey, jsonEncode(value.toJson()));
    notifyListeners();
  }

  GenerationSettings _loadSettings() {
    final text = defaults.string(_settingsKey);
    if (text == null) return GenerationSettings.starting;
    try {
      return GenerationSettings.fromJson(jsonDecode(text));
    } on FormatException {
      return GenerationSettings.starting;
    }
  }

  List<GenerationModel> _loadRecent() {
    final text = defaults.string(_recentKey);
    if (text == null) return [];
    try {
      final json = jsonDecode(text);
      return json is List ? [for (final item in json) ?GenerationModel.fromJson(item)] : [];
    } on FormatException {
      return [];
    }
  }

  File get _index => File('${folder.path}/index.json');

  void _readIndex() {
    try {
      folder.createSync(recursive: true);
      if (!_index.existsSync()) return;
      final json = jsonDecode(_index.readAsStringSync());
      if (json is! List) return;
      _pictures = [
        for (final item in json)
          if (GeneratedPicture.fromJson(item) case final picture? when File('${folder.path}/${picture.file}').existsSync()) picture,
      ];
    } on Object {
      _pictures = [];
    }
  }

  GenerationClient client() => GenerationClient(key: _key, modelField: defaults.string(_fieldKey) ?? GenerationClient.modelFields[0], transport: _transport);

  /// A client for a key that has not been saved yet, to check it with.
  GenerationClient clientFor(String key) => GenerationClient(key: key, transport: _transport);

  void rememberModelField(String field) => defaults.set(_fieldKey, field);

  /// Saves the key in the Keystore; an empty key removes it. False when the device would not keep it.
  Future<bool> save(String key) async {
    final trimmed = key.trim();
    if (!await _keychain.save(trimmed)) return false;
    _key = trimmed;
    _loading ??= Future.value();
    notifyListeners();
    return true;
  }

  void remember(GenerationModel model) {
    _recent = [model, ..._recent.where((item) => item.air != model.air)].take(12).toList();
    defaults.set(_recentKey, jsonEncode([for (final item in _recent) item.toJson()]));
    notifyListeners();
  }

  File file(GeneratedPicture picture) => File('${folder.path}/${picture.file}');

  GeneratedPicture add(Uint8List data, {required String prompt, required GenerationSettings settings, (int, int)? size}) {
    final type = data.length > 1 && data[0] == 0x89 && data[1] == 0x50
        ? 'png'
        : data.length > 1 && data[0] == 0x52 && data[1] == 0x49
        ? 'webp'
        : 'jpg';
    final picture = GeneratedPicture(
      file: '',
      prompt: prompt,
      negative: settings.negative,
      model: settings.model?.air ?? '',
      modelName: settings.model?.name ?? '',
      width: size?.$1 ?? settings.width,
      height: size?.$2 ?? settings.height,
      steps: settings.steps,
      guidance: settings.guidance,
      seed: settings.seed,
    );
    picture.file = '${picture.id}.$type';
    folder.createSync(recursive: true);
    file(picture).writeAsBytesSync(data, flush: true);
    _pictures = [picture, ..._pictures];
    for (final old in _pictures.skip(pictureLimit)) {
      try {
        file(old).deleteSync();
      } on Object {
        // A file already gone needs no removing.
      }
    }
    _pictures = _pictures.take(pictureLimit).toList();
    _persist();
    notifyListeners();
    return picture;
  }

  void delete(GeneratedPicture picture) {
    try {
      file(picture).deleteSync();
    } on Object {
      // A file already gone needs no removing.
    }
    _pictures = [for (final item in _pictures) if (item.id != picture.id) item];
    _persist();
    notifyListeners();
  }

  void _persist() {
    try {
      _index.writeAsStringSync(jsonEncode([for (final picture in _pictures) picture.toJson()]), flush: true);
    } on Object {
      // The pictures stay on disk; the next change writes the index again.
    }
  }
}

/// One run of the generator: what it is doing now and what it has made (`GenerationRun`).
class GenerationRun extends ChangeNotifier {
  GenerationPhase _phase = GenerationPhase.idle;
  GenerationError? _error;
  List<GeneratedPicture> _made = [];
  double? _lastCost;
  String? _jobID;
  bool _cancelled = false;
  Completer<void>? _cancelSignal;
  Future<void>? _task;

  GenerationPhase get phase => _phase;
  GenerationError? get error => _error;
  List<GeneratedPicture> get made => List.unmodifiable(_made);
  double? get lastCost => _lastCost;
  bool get isRunning => _phase != GenerationPhase.idle;

  /// Completes when the current run has ended; for tests.
  Future<void> get done => _task ?? Future.value();

  void _set(GenerationPhase phase) {
    _phase = phase;
    notifyListeners();
  }

  /// Races [work] against the Cancel button, so a long wait ends at once.
  Future<T> _guard<T>(Future<T> work) => Future.any([work, _cancelSignal!.future.then<T>((_) => throw const GenerationCancelled())]);

  void start({required String prompt, required GenerationSettings settings, required GenerationStore store}) {
    if (isRunning) return;
    _error = null;
    _cancelled = false;
    _cancelSignal = Completer<void>();
    _set(GenerationPhase.sending);
    _task = _run(prompt, settings, store);
  }

  Future<void> _run(String prompt, GenerationSettings settings, GenerationStore store) async {
    final client = store.client();
    try {
      final submitting = client.submit(prompt: prompt, settings: settings);
      GenerationJob job;
      try {
        job = await _guard(submitting);
      } on GenerationCancelled {
        // The request may still have been accepted; it is cancelled on the service too.
        unawaited(submitting.then((accepted) => client.cancel(accepted.id), onError: (Object _) {}));
        rethrow;
      }
      store.rememberModelField(client.acceptedModelField);
      _jobID = job.id;
      _set(job.isQueued ? GenerationPhase.queued : GenerationPhase.drawing);
      job = await _guard(
        client.finish(
          job,
          isCancelled: () => _cancelled,
          progress: (current) async => _set(current.isQueued ? GenerationPhase.queued : GenerationPhase.drawing),
        ),
      );
      _lastCost = job.cost;
      final failure = GenerationClient.failure(job);
      if (failure != null) throw failure;
      _set(GenerationPhase.saving);
      for (final image in job.images.where((image) => image.available)) {
        final url = image.url;
        if (url == null) continue;
        final data = await _guard(client.picture(url));
        final size = image.width != null && image.height != null ? (image.width!, image.height!) : null;
        _made = [store.add(data, prompt: prompt, settings: settings, size: size), ..._made];
        notifyListeners();
      }
    } on GenerationCancelled {
      // Cancelling is not an error to show.
    } on GenerationError catch (failure) {
      _error = failure;
    } on Object catch (error) {
      _error = GenerationError.failed('$error');
    }
    _jobID = null;
    _set(GenerationPhase.idle);
  }

  void cancel(GenerationStore store) {
    _cancelled = true;
    if (_cancelSignal case final signal? when !signal.isCompleted) signal.complete();
    if (_jobID case final id?) unawaited(store.client().cancel(id));
  }

  void forget(GeneratedPicture picture) {
    _made = [for (final item in _made) if (item.id != picture.id) item];
    notifyListeners();
  }
}

enum GenerationPhase { idle, sending, queued, drawing, saving }

/// A stand-in for the service, so that tests and fixture runs neither need a key nor spend anything
/// (`GenerationUITestSupport`).
abstract final class GenerationFixture {
  static const model = GenerationModel(air: 'urn:air:sdxl:checkpoint:civitai:827184@2514310', name: 'Fixture Model · v1', base: 'Illustrious', versionID: 2514310);

  /// A one-by-one PNG.
  static final picture = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==');

  static GenerationTransport transport({Duration delay = const Duration(milliseconds: 300)}) => (request) async {
    final url = request.uri, path = url.path;
    GenerationResponse answer(Object? object, [int status = 200]) => GenerationResponse(status, Uint8List.fromList(utf8.encode(jsonEncode(object))));
    if (url.host == 'fixture.invalid') return GenerationResponse(200, Uint8List.fromList(picture));
    if (path.endsWith('/me')) {
      return request.header('Authorization') == 'Bearer wrong' ? answer({'error': 'Unauthorized'}, 401) : answer({'username': 'fixture_user', 'status': 'active'});
    }
    if (path.contains('/model-versions/')) {
      return answer({
        'id': 2514310,
        'name': 'v1',
        'baseModel': 'Illustrious',
        'air': model.air,
        'model': {'name': 'Fixture Model'},
      });
    }
    if (path.endsWith('/models')) {
      return answer({
        'items': [
          {
            'name': 'Fixture Model',
            'modelVersions': [
              {'id': 2514310, 'name': 'v1', 'baseModel': 'Illustrious', 'supportsGeneration': true},
            ],
          },
        ],
      });
    }
    if (url.query.contains('whatif=true')) return answer({'cost': {'total': 10}});
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    return answer({
      'id': 'wf_fixture',
      'status': 'succeeded',
      'cost': {'total': 10},
      'steps': [
        {
          'output': {
            'images': [
              {'id': 'fixture.png', 'url': 'https://fixture.invalid/fixture.png', 'available': true, 'width': 832, 'height': 1216},
            ],
          },
        },
      ],
    });
  };
}
