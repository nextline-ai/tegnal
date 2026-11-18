import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../support/l10n.dart';
import 'generation_air.dart';

/// A model or add-on that can be generated with (`GenerationModel`).
class GenerationModel {
  const GenerationModel({required this.air, required this.name, this.base, this.versionID});

  /// The full AIR identifier; empty until a search result has been looked up.
  final String air;
  final String name;

  /// What the model was built on, as its page says ("Illustrious", "Pony", "SDXL 1.0").
  final String? base;
  final int? versionID;

  String get id => air.isEmpty ? 'version:${versionID ?? 0}' : air;

  /// The model a new generator starts with and suggests: Anima, base v1.0.
  static const recommended = GenerationModel(air: 'urn:air:anima:checkpoint:civitai:2458426@2945208+2824391', name: 'Anima · base-v1.0', base: 'Anima', versionID: 2945208);

  /// True for the suggested model, however the identifier's optional parts are written.
  bool get isRecommended {
    final mine = GenerationAIR.parse(air), ours = GenerationAIR.parse(recommended.air);
    if (mine == null || ours == null) return false;
    return mine.source == ours.source && mine.id == ours.id && mine.version == ours.version;
  }

  Map<String, Object?> toJson() => {'air': air, 'name': name, if (base != null) 'base': base, if (versionID != null) 'versionID': versionID};

  static GenerationModel? fromJson(Object? json) {
    if (json is! Map) return null;
    final air = json['air'], name = json['name'];
    if (air is! String || name is! String) return null;
    final base = json['base'], version = json['versionID'];
    return GenerationModel(air: air, name: name, base: base is String ? base : null, versionID: version is int ? version : null);
  }

  @override
  bool operator ==(Object other) => other is GenerationModel && other.air == air && other.name == name && other.base == base && other.versionID == versionID;

  @override
  int get hashCode => Object.hash(air, name, base, versionID);
}

class GenerationLora {
  const GenerationLora({required this.model, this.strength = 0.8});
  final GenerationModel model;
  final double strength;

  String get id => model.id;

  GenerationLora copyWith({double? strength}) => GenerationLora(model: model, strength: strength ?? this.strength);

  Map<String, Object?> toJson() => {'model': model.toJson(), 'strength': strength};

  static GenerationLora? fromJson(Object? json) {
    if (json is! Map) return null;
    final model = GenerationModel.fromJson(json['model']);
    if (model == null) return null;
    final strength = json['strength'];
    return GenerationLora(model: model, strength: strength is num ? strength.toDouble() : 0.8);
  }

  @override
  bool operator ==(Object other) => other is GenerationLora && other.model == model && other.strength == strength;

  @override
  int get hashCode => Object.hash(model, strength);
}

/// Everything about a picture except its prompt (`GenerationSettings`).
class GenerationSettings {
  const GenerationSettings({
    this.model,
    this.loras = const [],
    this.negative = 'worst quality, low quality, lowres, bad anatomy, bad hands, signature, watermark, username, blurry',
    this.width = 832,
    this.height = 1216,
    this.steps = 25,
    this.guidance = 5.5,
    this.sampler = 'euler_a',
    this.schedule = 'discrete',
    this.seed,
    this.quantity = 1,
    this.mature = false,
  });

  final GenerationModel? model;
  final List<GenerationLora> loras;
  final String negative;
  final int width;
  final int height;
  final int steps;
  final double guidance;
  final String sampler;
  final String schedule;

  /// Null draws a new seed each time.
  final int? seed;
  final int quantity;

  /// Whether results the service rates as mature may be returned.
  final bool mature;

  static const sizes = [(832, 1216), (896, 1152), (1024, 1024), (1152, 896), (1216, 832)];
  static const samplers = ['euler_a', 'euler', 'dpm++2m', 'dpm++2s_a', 'lcm'];
  static const schedules = ['simple', 'discrete', 'karras', 'sgm_uniform'];
  static const stepRange = (8, 50);
  static const quantityRange = (1, 4);

  /// The service's own estimate comes from a dry run; this is the published formula, for when there is none yet.
  int get roughCost {
    // Anima is priced per 25 steps, the Stable Diffusion families per 20.
    final unit = _family(model) == GenerationFamily.anima ? 25.0 : 20.0;
    return (8.0 * (width * height) / (1024 * 1024) * steps / unit * quantity).ceil();
  }

  static GenerationFamily? _family(GenerationModel? model) => model == null ? null : GenerationAIR.parse(model.air)?.family;

  /// The settings a new generator starts with: the suggested model and what it runs best at.
  static GenerationSettings get starting => const GenerationSettings().use(GenerationModel.recommended);

  /// Chooses a model. Moving between Anima and the Stable Diffusion families also moves the steps, the guidance,
  /// the sampler and the schedule to what the new family runs best at, since one family's values spoil the other's pictures.
  GenerationSettings use(GenerationModel chosen) {
    final before = _family(model), after = _family(chosen);
    final next = copyWith(model: chosen);
    if (before == after) return next;
    if (after == GenerationFamily.anima) return next.copyWith(steps: 30, guidance: 4, sampler: 'euler', schedule: 'simple');
    if (before == GenerationFamily.anima || (before == null && schedule == 'simple')) {
      return next.copyWith(steps: 25, guidance: 5.5, sampler: 'euler_a', schedule: 'discrete');
    }
    return next;
  }

  /// [clearModel] and [clearSeed] set those two to null, which a plain argument cannot say.
  GenerationSettings copyWith({
    GenerationModel? model,
    bool clearModel = false,
    List<GenerationLora>? loras,
    String? negative,
    int? width,
    int? height,
    int? steps,
    double? guidance,
    String? sampler,
    String? schedule,
    int? seed,
    bool clearSeed = false,
    int? quantity,
    bool? mature,
  }) => GenerationSettings(
    model: clearModel ? null : model ?? this.model,
    loras: loras ?? this.loras,
    negative: negative ?? this.negative,
    width: width ?? this.width,
    height: height ?? this.height,
    steps: steps ?? this.steps,
    guidance: guidance ?? this.guidance,
    sampler: sampler ?? this.sampler,
    schedule: schedule ?? this.schedule,
    seed: clearSeed ? null : seed ?? this.seed,
    quantity: quantity ?? this.quantity,
    mature: mature ?? this.mature,
  );

  Map<String, Object?> toJson() => {
    if (model != null) 'model': model!.toJson(),
    'loras': [for (final lora in loras) lora.toJson()],
    'negative': negative,
    'width': width,
    'height': height,
    'steps': steps,
    'guidance': guidance,
    'sampler': sampler,
    'schedule': schedule,
    if (seed != null) 'seed': seed,
    'quantity': quantity,
    'mature': mature,
  };

  static GenerationSettings fromJson(Object? json) {
    if (json is! Map) return const GenerationSettings();
    const base = GenerationSettings();
    int integer(String key, int fallback) => json[key] is int ? json[key] as int : fallback;
    String text(String key, String fallback) => json[key] is String ? json[key] as String : fallback;
    return GenerationSettings(
      model: GenerationModel.fromJson(json['model']),
      loras: [if (json['loras'] is List) for (final item in json['loras'] as List) ?GenerationLora.fromJson(item)],
      negative: text('negative', base.negative),
      width: integer('width', base.width),
      height: integer('height', base.height),
      steps: integer('steps', base.steps),
      guidance: json['guidance'] is num ? (json['guidance'] as num).toDouble() : base.guidance,
      sampler: text('sampler', base.sampler),
      schedule: text('schedule', base.schedule),
      seed: json['seed'] is int ? json['seed'] as int : null,
      quantity: integer('quantity', base.quantity),
      mature: json['mature'] is bool ? json['mature'] as bool : false,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is GenerationSettings &&
      other.model == model &&
      _sameLoras(other.loras, loras) &&
      other.negative == negative &&
      other.width == width &&
      other.height == height &&
      other.steps == steps &&
      other.guidance == guidance &&
      other.sampler == sampler &&
      other.schedule == schedule &&
      other.seed == seed &&
      other.quantity == quantity &&
      other.mature == mature;

  static bool _sameLoras(List<GenerationLora> a, List<GenerationLora> b) {
    if (a.length != b.length) return false;
    for (var index = 0; index < a.length; index++) {
      if (a[index] != b[index]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(model, Object.hashAll(loras), negative, width, height, steps, guidance, sampler, schedule, seed, quantity, mature);
}

class GenerationImage {
  const GenerationImage({required this.id, this.url, this.width, this.height, this.available = true, this.blockedReason});
  final String id;
  final Uri? url;
  final int? width;
  final int? height;

  /// False while the picture is withheld, for instance for being rated mature when that was not allowed.
  final bool available;
  final String? blockedReason;
}

/// A request as the service reports it.
class GenerationJob {
  GenerationJob({required this.id, required this.status, this.cost, List<GenerationImage>? images, this.reason, this.blockedReason}) : images = images ?? [];
  final String id;
  final String status;
  double? cost;
  final List<GenerationImage> images;
  String? reason;
  String? blockedReason;

  bool get isFinished => const ['succeeded', 'failed', 'expired', 'canceled'].contains(status);
  bool get isQueued => const ['unassigned', 'preparing', 'scheduled'].contains(status);
}

class GenerationAccount {
  const GenerationAccount({required this.name, required this.status});
  final String name;
  final String status;
}

enum GenerationErrorKind {
  /// No API key has been saved.
  noKey,

  /// The key was refused.
  invalidKey,

  /// The key is good but the account may not do this.
  forbidden,

  /// The request was not accepted as written.
  invalid,

  /// Not enough Buzz to pay for the request.
  payment,

  /// Too many requests; [GenerationError.retryAfter] is how many seconds to wait, when the service says.
  busy,

  /// Refused by the service's content moderation. The same prompt must not be sent again.
  blocked,
  failed,

  /// The model is not one this generator can run.
  unsupportedModel,
  noModel,
  notFound,
  unreadable,
}

class GenerationError implements Exception {
  const GenerationError(this.kind, [this.detail = '', this.retryAfter]);
  const GenerationError.noKey() : this(GenerationErrorKind.noKey);
  const GenerationError.invalidKey() : this(GenerationErrorKind.invalidKey);
  const GenerationError.forbidden([String detail = '']) : this(GenerationErrorKind.forbidden, detail);
  const GenerationError.invalid([String detail = '']) : this(GenerationErrorKind.invalid, detail);
  const GenerationError.payment() : this(GenerationErrorKind.payment);
  const GenerationError.busy([int? seconds]) : this(GenerationErrorKind.busy, '', seconds);
  const GenerationError.blocked([String detail = '']) : this(GenerationErrorKind.blocked, detail);
  const GenerationError.failed([String detail = '']) : this(GenerationErrorKind.failed, detail);
  const GenerationError.unsupportedModel() : this(GenerationErrorKind.unsupportedModel);
  const GenerationError.noModel() : this(GenerationErrorKind.noModel);
  const GenerationError.notFound() : this(GenerationErrorKind.notFound);
  const GenerationError.unreadable() : this(GenerationErrorKind.unreadable);

  final GenerationErrorKind kind;
  final String detail;
  final int? retryAfter;

  String get message => switch (kind) {
    GenerationErrorKind.noKey => L10n.text('Add your Civitai API key to generate pictures.'),
    GenerationErrorKind.invalidKey => L10n.text('Civitai did not accept this API key.'),
    GenerationErrorKind.forbidden => detail.isEmpty ? L10n.text('This account is not allowed to make this request.') : detail,
    GenerationErrorKind.invalid => detail.isEmpty ? L10n.text('The request was not accepted.') : detail,
    GenerationErrorKind.payment => L10n.text('Not enough Buzz on this account.'),
    GenerationErrorKind.busy => L10n.text('Too many requests. Wait a moment and try again.'),
    GenerationErrorKind.blocked =>
      L10n.text("Civitai's moderation refused this prompt. Change it before trying again; repeated refusals can get an account muted.") + (detail.isEmpty ? '' : '\n$detail'),
    GenerationErrorKind.failed => detail.isEmpty ? L10n.text('The picture could not be generated.') : detail,
    GenerationErrorKind.unsupportedModel => L10n.text(
      'This generator runs Anima, Stable Diffusion 1.5 and SDXL-family checkpoints, such as Illustrious, NoobAI, Pony and Animagine.',
    ),
    GenerationErrorKind.noModel => L10n.text('Choose a model first.'),
    GenerationErrorKind.notFound => L10n.text('Nothing was found for this.'),
    GenerationErrorKind.unreadable => L10n.text('The answer could not be read.'),
  };

  @override
  bool operator ==(Object other) => other is GenerationError && other.kind == kind && other.detail == detail && other.retryAfter == retryAfter;

  @override
  int get hashCode => Object.hash(kind, detail, retryAfter);

  @override
  String toString() => 'GenerationError($kind${detail.isEmpty ? '' : ', $detail'})';
}

/// One request the client makes, as the transport receives it (`URLRequest`).
class GenerationRequest {
  const GenerationRequest({required this.method, required this.uri, this.headers = const {}, this.body});
  final String method;
  final Uri uri;
  final Map<String, String> headers;
  final String? body;

  /// A header by name, whatever its case.
  String? header(String name) {
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == name.toLowerCase()) return entry.value;
    }
    return null;
  }
}

class GenerationResponse {
  GenerationResponse(this.status, this.body, [Map<String, String> headers = const {}]) : headers = {for (final entry in headers.entries) entry.key.toLowerCase(): entry.value};
  final int status;
  final Uint8List body;
  final Map<String, String> headers;
}

/// The HTTP layer, replaceable in tests (`GenerationClient.Transport`).
typedef GenerationTransport = Future<GenerationResponse> Function(GenerationRequest request);

/// Talks to Civitai's generation service with the user's own API key. The key travels only in the `Authorization`
/// header of calls to Civitai's two API hosts; pictures are fetched from their signed addresses without it.
class GenerationClient {
  GenerationClient({required String key, String? modelField, GenerationTransport? transport})
    : _key = key.trim(),
      _modelField = modelField ?? modelFields[0],
      _transport = transport ?? network;

  static final site = Uri.parse('https://civitai.com/api/v1');
  static final service = Uri.parse('https://orchestration.civitai.com/v2/consumer');

  /// The two names the service's documents give the checkpoint field; the one that is accepted is remembered.
  static const modelFields = ['model', 'checkpointModel'];

  final String _key;
  final GenerationTransport _transport;
  String _modelField;

  String get acceptedModelField => _modelField;

  /// The real network: no cookies are kept, and a request gives up after 75 seconds.
  static Future<GenerationResponse> network(GenerationRequest request) async {
    final client = http.Client();
    try {
      final outgoing = http.Request(request.method, request.uri)..headers.addAll(request.headers);
      if (request.body != null) outgoing.body = request.body!;
      final streamed = await client.send(outgoing).timeout(const Duration(seconds: 75));
      final response = await http.Response.fromStream(streamed).timeout(const Duration(seconds: 75));
      return GenerationResponse(response.statusCode, response.bodyBytes, response.headers);
    } on TimeoutException {
      throw const GenerationError.failed();
    } finally {
      client.close();
    }
  }

  // MARK: Requests

  /// The body of a text-to-image request. [field] names the checkpoint.
  static Map<String, Object?> body({required String prompt, required GenerationSettings settings, String field = 'model'}) {
    final model = settings.model;
    final air = model == null ? null : GenerationAIR.parse(model.air);
    if (model == null || air == null) throw const GenerationError.noModel();
    final family = air.family;
    if (family == null || !(air.kind == GenerationKind.checkpoint || air.type == null)) throw const GenerationError.unsupportedModel();
    final input = <String, Object?>{
      'engine': 'sdcpp',
      'ecosystem': family.rawValue,
      'operation': 'createImage',
      'prompt': prompt,
      'width': settings.width,
      'height': settings.height,
      'steps': settings.steps,
      'cfgScale': settings.guidance,
      'sampleMethod': settings.sampler,
      'schedule': settings.schedule,
      'quantity': settings.quantity,
    };
    if (family == GenerationFamily.anima) {
      // Anima ships with the service and takes no checkpoint field: sending one is refused. Its base model is the
      // one built in, so nothing names it; any other Anima checkpoint is named as an override of the built-in one.
      if (!model.isRecommended) input['diffuserModel'] = air.text;
    } else {
      input[field] = air.text;
    }
    final negative = settings.negative.trim();
    if (negative.isNotEmpty) input['negativePrompt'] = negative;
    if (settings.seed != null) input['seed'] = settings.seed;
    final loras = settings.loras.where((lora) => GenerationAIR.parse(lora.model.air) != null);
    if (loras.isNotEmpty) {
      final map = <String, Object?>{};
      for (final lora in loras) {
        map.putIfAbsent(lora.model.air, () => lora.strength);
      }
      input['loras'] = map;
    }
    final result = <String, Object?>{
      'steps': [
        {r'$type': 'imageGen', 'input': input},
      ],
    };
    // Left unset, the service decides by which Buzz paid; false keeps mature results from being returned.
    if (!settings.mature) result['allowMatureContent'] = false;
    return result;
  }

  static Object? _sorted(Object? value) {
    if (value is Map) return {for (final key in (value.keys.toList()..sort())) key: _sorted(value[key])};
    if (value is List) return [for (final item in value) _sorted(item)];
    return value;
  }

  GenerationRequest _request(Uri url, {String method = 'GET', List<(String, String)> query = const [], Map<String, Object?>? body, bool authorized = true}) {
    var address = url;
    if (query.isNotEmpty) address = url.replace(query: query.map((item) => '${Uri.encodeComponent(item.$1)}=${Uri.encodeComponent(item.$2)}').join('&'));
    final headers = {'Accept': 'application/json'};
    if (authorized) {
      if (_key.isEmpty) throw const GenerationError.noKey();
      headers['Authorization'] = 'Bearer $_key';
    }
    String? payload;
    if (body != null) {
      headers['Content-Type'] = 'application/json';
      payload = jsonEncode(_sorted(body));
    }
    return GenerationRequest(method: method, uri: address, headers: headers, body: payload);
  }

  Future<Object> _send(GenerationRequest request) async {
    final response = await _transport(request);
    Object? object;
    try {
      object = jsonDecode(utf8.decode(response.body, allowMalformed: true));
    } on FormatException {
      object = null;
    }
    if (response.status < 200 || response.status >= 300) {
      throw error(status: response.status, body: object is Map<String, dynamic> ? object : null, retryAfter: response.headers['retry-after']);
    }
    if (object == null) throw const GenerationError.unreadable();
    return object;
  }

  /// What a refusal means. Problem bodies carry a `title`, a `detail` and, for a request that failed validation, `errors` by field.
  static GenerationError error({required int status, Map<String, dynamic>? body, String? retryAfter}) {
    final lines = <String>[
      if (body?['detail'] is String) body!['detail'] as String,
      if (body?['message'] is String) body!['message'] as String,
    ];
    final errors = body?['errors'];
    if (errors is Map) {
      for (final field in (errors.keys.map((key) => '$key').toList()..sort())) {
        final value = errors[field];
        lines.add('$field: ${value is List && value.every((item) => item is String) ? value.join(' ') : value}');
      }
    }
    if (lines.isEmpty) {
      final title = body?['title'] is String ? body!['title'] as String : (body?['error'] is String ? body!['error'] as String : null);
      if (title != null) lines.add(title);
    }
    final detail = lines.join('\n');
    final lowered = detail.toLowerCase();
    final money = const ['buzz', 'funds', 'payment', 'balance'].any(lowered.contains);
    return switch (status) {
      401 => const GenerationError.invalidKey(),
      402 => const GenerationError.payment(),
      403 => money ? const GenerationError.payment() : GenerationError.forbidden(detail),
      404 => const GenerationError.notFound(),
      429 => GenerationError.busy(retryAfter == null ? null : int.tryParse(retryAfter)),
      400 || 409 || 422 => money ? const GenerationError.payment() : GenerationError.invalid(detail),
      _ => GenerationError.failed(detail),
    };
  }

  // MARK: Account and models

  /// Asks who the key belongs to, which is also how a key is checked.
  Future<GenerationAccount> account() async {
    final object = await _send(_request(Uri.parse('$site/me')));
    if (object is! Map) throw const GenerationError.unreadable();
    return GenerationAccount(name: object['username'] is String ? object['username'] as String : '', status: object['status'] is String ? object['status'] as String : '');
  }

  /// The model version with this id, with its AIR identifier.
  Future<GenerationModel> version(int id) async {
    final object = await _send(_request(Uri.parse('$site/model-versions/$id'), authorized: _key.isNotEmpty));
    final air = object is Map ? object['air'] : null;
    if (object is! Map || air is! String || GenerationAIR.parse(air) == null) throw const GenerationError.notFound();
    final model = object['model'] is Map ? (object['model'] as Map)['name'] : null;
    final name = [if (model is String) model, if (object['name'] is String) object['name'] as String].join(' · ');
    return GenerationModel(air: air, name: name.isEmpty ? air : name, base: object['baseModel'] is String ? object['baseModel'] as String : null, versionID: id);
  }

  /// Models that can be generated with on the service, by name. Each result still needs [version] for its identifier.
  Future<List<GenerationModel>> search(String text, {required GenerationKind kind, required bool mature}) async {
    final trimmed = text.trim();
    final query = [
      ('limit', '30'),
      ('types', kind == GenerationKind.lora ? 'LORA' : 'Checkpoint'),
      ('supportsGeneration', 'true'),
      ('nsfw', mature ? 'true' : 'false'),
      if (trimmed.isEmpty) ('sort', 'Most Downloaded') else ('query', trimmed),
    ];
    final object = await _send(_request(Uri.parse('$site/models'), query: query, authorized: _key.isNotEmpty));
    final items = object is Map ? object['items'] : null;
    if (items is! List) throw const GenerationError.unreadable();
    final results = <GenerationModel>[];
    for (final item in items) {
      if (item is! Map) continue;
      final versions = item['modelVersions'] is List ? [for (final value in item['modelVersions'] as List) if (value is Map) value] : <Map>[];
      final name = item['name'];
      final version = versions.where((value) => value['supportsGeneration'] != false).firstOrNull;
      final id = version?['id'];
      if (name is! String || version == null || id is! int) continue;
      results.add(
        GenerationModel(
          air: '',
          name: [name, if (version['name'] is String) version['name'] as String].join(' · '),
          base: version['baseModel'] is String ? version['baseModel'] as String : null,
          versionID: id,
        ),
      );
    }
    return results;
  }

  // MARK: Generating

  Future<GenerationJob> _workflows(String prompt, GenerationSettings settings, {required List<(String, String)> query}) async {
    final url = Uri.parse('$service/workflows');
    try {
      return job(await _send(_request(url, method: 'POST', query: query, body: body(prompt: prompt, settings: settings, field: _modelField))));
    } on GenerationError catch (refusal) {
      if (refusal.kind != GenerationErrorKind.invalid) rethrow;
      // Anima's request has no checkpoint field to rename, so its refusal stands.
      if (GenerationSettings._family(settings.model) == GenerationFamily.anima) rethrow;
      // The service's guide and its schema name the checkpoint field differently; a refusal is retried once under the other name.
      final other = modelFields.firstWhere((name) => name != _modelField, orElse: () => _modelField);
      try {
        final result = job(await _send(_request(url, method: 'POST', query: query, body: body(prompt: prompt, settings: settings, field: other))));
        _modelField = other;
        return result;
      } on GenerationError catch (second) {
        if (second.kind == GenerationErrorKind.invalid) throw refusal;
        rethrow;
      }
    }
  }

  /// What the request would cost in Buzz, without running it.
  Future<double?> estimate({required String prompt, required GenerationSettings settings}) async => (await _workflows(prompt, settings, query: [('whatif', 'true')])).cost;

  /// Starts a request and waits a little for it; the job may come back still running.
  Future<GenerationJob> submit({required String prompt, required GenerationSettings settings, int wait = 30}) =>
      _workflows(prompt, settings, query: [('wait', '$wait')]);

  Future<GenerationJob> fetchJob(String id, {int wait = 30}) async => job(await _send(_request(Uri.parse('$service/workflows/$id'), query: [('wait', '$wait')])));

  Future<void> cancel(String id) async {
    try {
      await _transport(_request(Uri.parse('$service/workflows/$id'), method: 'DELETE'));
    } on Object {
      // Nothing more can be done about a request that did not go through.
    }
  }

  /// Waits for a job to end, asking again each time the wait runs out, for up to [limit] seconds.
  /// [isCancelled] is looked at before each ask; a cancelled wait ends with [GenerationCancelled].
  Future<GenerationJob> finish(
    GenerationJob start, {
    double limit = 300,
    Future<void> Function(GenerationJob job)? progress,
    bool Function()? isCancelled,
    int wait = 30,
  }) async {
    var current = start;
    final began = DateTime.now();
    while (!current.isFinished) {
      if (isCancelled?.call() ?? false) throw const GenerationCancelled();
      if (DateTime.now().difference(began).inMicroseconds / 1e6 >= limit) {
        throw GenerationError.failed(L10n.text('The picture is taking too long. It may still finish on Civitai.'));
      }
      await progress?.call(current);
      current = await fetchJob(current.id, wait: wait);
    }
    return current;
  }

  /// The bytes of a finished picture. Its address is already signed, so the key is not sent.
  Future<Uint8List> picture(Uri url) async {
    final response = await _transport(GenerationRequest(method: 'GET', uri: url));
    if (response.status < 200 || response.status >= 300 || response.body.isEmpty) throw const GenerationError.failed();
    return response.body;
  }

  // MARK: Reading answers

  static double? _number(Object? value) => value is num ? value.toDouble() : (value is String ? double.tryParse(value) : null);
  static int? _integer(Object? value) => value is int ? value : (value is double && value == value.roundToDouble() ? value.toInt() : null);

  static GenerationJob job(Object? object) {
    if (object is! Map) throw const GenerationError.unreadable();
    final id = object['id'] is String ? object['id'] as String : (object['cost'] != null ? '' : null);
    if (id == null) throw const GenerationError.unreadable();
    final job = GenerationJob(id: id, status: object['status'] is String ? object['status'] as String : 'unassigned');
    final cost = object['cost'];
    job.cost = _number(cost is Map ? cost['total'] : null) ?? _number(cost);
    final steps = object['steps'] is List ? object['steps'] as List : const [];
    for (final step in steps) {
      if (step is! Map) continue;
      final output = step['output'];
      final entries = output is Map && output['images'] is List ? output['images'] as List : const [];
      for (final entry in entries) {
        if (entry is! Map || entry['id'] is! String) continue;
        final url = entry['url'] is String ? Uri.tryParse(entry['url'] as String) : null;
        job.images.add(
          GenerationImage(
            id: entry['id'] as String,
            url: url,
            width: _integer(entry['width']),
            height: _integer(entry['height']),
            available: entry['available'] is bool ? entry['available'] as bool : url != null,
            blockedReason: entry['blockedReason'] is String ? entry['blockedReason'] as String : null,
          ),
        );
      }
      final runs = step['jobs'] is List ? step['jobs'] as List : const [];
      for (final run in runs) {
        if (run is! Map) continue;
        if (run['reason'] is String && job.reason == null) job.reason = run['reason'] as String;
        if (run['blockedReason'] is String && job.blockedReason == null) job.blockedReason = run['blockedReason'] as String;
      }
    }
    return job;
  }

  /// Why a finished job has no picture to show, if it has none.
  static GenerationError? failure(GenerationJob job) {
    if (job.reason == 'blocked' || (job.images.isEmpty && job.blockedReason != null)) return GenerationError.blocked(job.blockedReason ?? '');
    if (job.status == 'succeeded') {
      if (job.images.any((image) => image.available && image.url != null)) return null;
      return job.images.isEmpty ? const GenerationError.failed() : GenerationError.failed(L10n.text('The result was withheld. Results rated as mature are only returned when that is allowed.'));
    }
    return switch (job.status) {
      'canceled' => GenerationError.failed(L10n.text('The request was cancelled.')),
      'expired' => GenerationError.failed(L10n.text('The request ran out of time. It is safe to try again.')),
      _ => GenerationError.failed(job.reason == 'no_provider_available' ? L10n.text('No worker can run this request right now. Try other settings or try later.') : ''),
    };
  }
}

/// A wait that was ended on purpose (`CancellationError`).
class GenerationCancelled implements Exception {
  const GenerationCancelled();
}
