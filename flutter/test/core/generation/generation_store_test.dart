import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/generation/generation_client.dart';
import 'package:tegnal/core/generation/generation_store.dart';
import 'package:tegnal/core/support/preferences.dart';
import 'package:tegnal/core/support/secure_secret_store.dart';

import 'package:tegnal/core/generation/generation_air.dart';
import 'generation_test_support.dart';

/// Preferences that remember every value written, to look for a key in.
class RecordingPreferences extends MemoryPreferences {
  final written = <String>[];
  @override
  void set(String key, Object? value) {
    written.add('$key=$value');
    super.set(key, value);
  }
}

const png = [0x89, 0x50, 0x4E, 0x47, 1, 2, 3];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  setUp(() => directory = Directory.systemTemp.createTempSync('generation-store-'));
  tearDown(() => directory.deleteSync(recursive: true));

  GenerationStore open({Preferences? defaults, MemorySecureStorage? secure, GenerationTransport? transport}) => GenerationStore(
    folder: Directory('${directory.path}/Generated'),
    defaults: defaults ?? MemoryPreferences(),
    keychain: GenerationKeychain(secure ?? MemorySecureStorage()),
    transport: transport,
  );

  group('presets', () {
    const noob = 'masterpiece, best quality, newest, absurdres, highres, safe';

    GenerationPreset preset(String name) => GenerationPreset.all.firstWhere((preset) => preset.name == name);

    test('carry the exact tags each model card recommends', () {
      expect(GenerationPreset.all.map((preset) => preset.name), ['Anima', 'NoobAI-XL', 'Illustrious XL', 'Animagine XL 4.0', 'Pony Diffusion V6 XL']);
      expect(preset('NoobAI-XL').front, noob);
      expect(preset('NoobAI-XL').steps, 28);
      expect(preset('NoobAI-XL').guidance, 5.5);
      expect(preset('Illustrious XL').front, 'masterpiece, best quality');
      expect(preset('Illustrious XL').guidance, 6);
      expect(preset('Animagine XL 4.0').back, 'masterpiece, high score, great score, absurdres');
      expect(preset('Animagine XL 4.0').front, isEmpty);
      expect(preset('Animagine XL 4.0').guidance, 5);
      expect(preset('Pony Diffusion V6 XL').front, 'score_9, score_8_up, score_7_up, score_6_up, score_5_up, score_4_up');
      expect(preset('Pony Diffusion V6 XL').steps, 25);
      expect(preset('Pony Diffusion V6 XL').guidance, 7);
      expect(preset('Pony Diffusion V6 XL').negative, isEmpty);
    });

    test('write front tags before the prompt and back tags after it', () {
      expect(preset('NoobAI-XL').applied('1girl, solo'), '$noob, 1girl, solo');
      expect(preset('Animagine XL 4.0').applied('1girl, solo'), '1girl, solo, masterpiece, high score, great score, absurdres');
      expect(preset('NoobAI-XL').applied(''), noob);
    });

    test('do not duplicate their tags when applied again', () {
      final once = preset('NoobAI-XL').applied('1girl, solo');
      expect(preset('NoobAI-XL').applied(once), once);
      final animagine = preset('Animagine XL 4.0').applied('1girl');
      expect(preset('Animagine XL 4.0').applied(animagine), animagine);
    });

    test('remove the tags of any other preset when switching', () {
      final noobai = preset('NoobAI-XL').applied('1girl, solo');
      expect(preset('Illustrious XL').applied(noobai), 'masterpiece, best quality, 1girl, solo');
      expect(preset('Pony Diffusion V6 XL').applied(noobai), 'score_9, score_8_up, score_7_up, score_6_up, score_5_up, score_4_up, 1girl, solo');
      final animagine = preset('Animagine XL 4.0').applied('1girl');
      expect(preset('NoobAI-XL').applied(animagine), '$noob, 1girl');
    });

    test('tidy spacing and empty tags', () => expect(preset('Illustrious XL').applied('  1girl ,, solo ,'), 'masterpiece, best quality, 1girl, solo'));
  });

  group('API key', () {
    test('is read from secure storage, saved and removed there, and trimmed', () async {
      final secure = MemorySecureStorage();
      final store = open(secure: secure);
      await store.load();
      expect(store.hasKey, isFalse);
      expect(await store.save('  abc123  '), isTrue);
      expect(store.hasKey, isTrue);
      expect(secure.values.values, ['abc123']);
      final again = open(secure: secure);
      await again.load();
      expect(again.hasKey, isTrue);
      expect(await again.save(''), isTrue);
      expect(again.hasKey, isFalse);
      expect(secure.values, isEmpty);
    });

    test('never reaches preferences, files or the index', () async {
      final defaults = RecordingPreferences();
      final secure = MemorySecureStorage();
      final store = open(defaults: defaults, secure: secure);
      await store.save('TOP-SECRET-KEY');
      store.settings = store.settings.copyWith(model: checkpoint, steps: 30);
      store.remember(checkpoint);
      store.rememberModelField('checkpointModel');
      store.add(Uint8List.fromList(png), prompt: 'rain', settings: store.settings);
      expect(defaults.written.where((entry) => entry.contains('TOP-SECRET-KEY')), isEmpty);
      for (final entity in directory.listSync(recursive: true).whereType<File>()) {
        expect(utf8.decode(entity.readAsBytesSync(), allowMalformed: true), isNot(contains('TOP-SECRET-KEY')), reason: entity.path);
      }
      expect(secure.values.keys.single, 'tegnal.generation.civitai');
      // And it reaches the service only as the bearer token.
      final service = FakeService((request) async => json({'username': 'a', 'status': 'active'}));
      final other = open(secure: secure, transport: service.transport);
      await other.load();
      await other.client().account();
      expect(service.requests.single.header('Authorization'), 'Bearer TOP-SECRET-KEY');
    });

    test('reports a key the device would not keep', () async {
      final store = GenerationStore(folder: Directory('${directory.path}/Generated'), defaults: MemoryPreferences(), keychain: GenerationKeychain(_FailingStorage()));
      await store.load();
      expect(await store.save('abc'), isFalse);
      expect(store.hasKey, isFalse);
    });

    test('a client for an unsaved key uses that key', () async {
      final service = FakeService((request) async => json({'username': 'a', 'status': 'active'}));
      final store = open(transport: service.transport);
      await store.clientFor(' candidate ').account();
      expect(service.requests.single.header('Authorization'), 'Bearer candidate');
      expect(store.hasKey, isFalse);
    });
  });

  group('settings and recent models', () {
    test('persist across stores', () {
      final defaults = MemoryPreferences();
      final store = open(defaults: defaults);
      expect(store.settings, GenerationSettings.starting);
      store.settings = store.settings.copyWith(model: checkpoint, steps: 33, seed: 5, loras: [const GenerationLora(model: lora, strength: 0.5)], mature: true);
      final again = open(defaults: defaults);
      expect(again.settings.model, checkpoint);
      expect(again.settings.steps, 33);
      expect(again.settings.seed, 5);
      expect(again.settings.loras.single.strength, 0.5);
      expect(again.settings.mature, isTrue);
    });

    test('are not written again when nothing changed, and notify when something did', () {
      final defaults = RecordingPreferences();
      final store = open(defaults: defaults);
      var notified = 0;
      store.addListener(() => notified++);
      store.settings = GenerationSettings.starting;
      expect(defaults.written, isEmpty);
      expect(notified, 0);
      store.settings = store.settings.copyWith(steps: 10);
      expect(defaults.written, hasLength(1));
      expect(notified, 1);
    });

    test('survive unreadable stored values', () {
      final defaults = MemoryPreferences({'generation.settings': 'not json', 'generation.recentModels': '{'});
      final store = open(defaults: defaults);
      expect(store.settings, GenerationSettings.starting);
      expect(store.recentModels, isEmpty);
    });

    test('start with the suggested model, and give it to saved settings that have none', () {
      expect(open().settings.model, GenerationModel.recommended);
      expect(open().settings.steps, 30);
      final saved = MemoryPreferences({'generation.settings': jsonEncode(const GenerationSettings(steps: 12).toJson())});
      final store = open(defaults: saved);
      expect(store.settings.model, GenerationModel.recommended);
      expect(store.settings.schedule, 'simple');
      final kept = MemoryPreferences({'generation.settings': jsonEncode(const GenerationSettings(model: checkpoint, steps: 12).toJson())});
      expect(open(defaults: kept).settings.model, checkpoint);
      expect(open(defaults: kept).settings.steps, 12);
    });

    test('keep recent models without duplicates, newest first, at most 12', () {
      final defaults = MemoryPreferences();
      final store = open(defaults: defaults);
      GenerationModel model(int number) => GenerationModel(air: 'urn:air:sdxl:checkpoint:civitai:$number@1', name: 'Model $number');
      for (var number = 1; number <= 15; number++) {
        store.remember(model(number));
      }
      expect(store.recentModels, hasLength(12));
      expect(store.recentModels.first, model(15));
      expect(store.recentModels.last, model(4));
      store.remember(model(10));
      expect(store.recentModels, hasLength(12));
      expect(store.recentModels.first, model(10));
      expect(store.recentModels.where((item) => item.air == model(10).air), hasLength(1));
      expect(open(defaults: defaults).recentModels.map((item) => item.air), store.recentModels.map((item) => item.air));
    });

    test('remember the checkpoint field that was accepted', () async {
      final defaults = MemoryPreferences();
      final service = FakeService((request) async => json(succeeded()));
      final store = open(defaults: defaults, transport: service.transport);
      await store.save('abc');
      await store.client().submit(prompt: 'x', settings: const GenerationSettings(model: checkpoint));
      expect(inputField(service, 0), 'model');
      store.rememberModelField('checkpointModel');
      final next = open(defaults: defaults, transport: service.transport);
      await next.save('abc');
      await next.client().submit(prompt: 'x', settings: const GenerationSettings(model: checkpoint));
      expect(inputField(service, service.requests.length - 1), 'checkpointModel');
    });
  });

  group('pictures', () {
    test('are written to the Generated folder with an index, newest first', () {
      final store = open();
      final first = store.add(Uint8List.fromList(png), prompt: 'one', settings: const GenerationSettings(model: checkpoint, seed: 9), size: (100, 200));
      final second = store.add(Uint8List.fromList([0x52, 0x49, 0x46, 0x46]), prompt: 'two', settings: const GenerationSettings());
      final third = store.add(Uint8List.fromList([0xFF, 0xD8]), prompt: 'three', settings: const GenerationSettings());
      expect(store.pictures.map((picture) => picture.prompt), ['three', 'two', 'one']);
      expect(first.file, endsWith('.png'));
      expect(second.file, endsWith('.webp'));
      expect(third.file, endsWith('.jpg'));
      expect(first.width, 100);
      expect(first.height, 200);
      expect(first.seed, 9);
      expect(first.model, checkpoint.air);
      expect(first.modelName, checkpoint.name);
      expect(store.file(first).readAsBytesSync(), png);
      expect(store.file(first).parent.path, endsWith('Generated'));
      final index = jsonDecode(File('${directory.path}/Generated/index.json').readAsStringSync()) as List;
      expect(index.map((item) => (item as Map)['prompt']), ['three', 'two', 'one']);
    });

    test('come back when the store is opened again, and the ones whose file is gone do not', () {
      final store = open();
      final one = store.add(Uint8List.fromList(png), prompt: 'one', settings: const GenerationSettings());
      final two = store.add(Uint8List.fromList(png), prompt: 'two', settings: const GenerationSettings(seed: 3));
      store.file(one).deleteSync();
      final again = open();
      expect(again.pictures.map((picture) => picture.prompt), ['two']);
      expect(again.pictures.single.id, two.id);
      expect(again.pictures.single.seed, 3);
      expect(again.pictures.single.date.difference(two.date).inSeconds.abs(), lessThan(2));
    });

    test('are deleted with their file and index entry', () {
      final store = open();
      final one = store.add(Uint8List.fromList(png), prompt: 'one', settings: const GenerationSettings());
      store.add(Uint8List.fromList(png), prompt: 'two', settings: const GenerationSettings());
      store.delete(one);
      expect(store.file(one).existsSync(), isFalse);
      expect(store.pictures.map((picture) => picture.prompt), ['two']);
      expect(open().pictures.map((picture) => picture.prompt), ['two']);
    });

    test('are kept to the newest 200', () {
      final store = open();
      final first = store.add(Uint8List.fromList(png), prompt: 'p0', settings: const GenerationSettings());
      for (var number = 1; number <= GenerationStore.pictureLimit; number++) {
        store.add(Uint8List.fromList(png), prompt: 'p$number', settings: const GenerationSettings());
      }
      expect(store.pictures, hasLength(GenerationStore.pictureLimit));
      expect(store.pictures.first.prompt, 'p200');
      expect(store.pictures.last.prompt, 'p1');
      expect(store.file(first).existsSync(), isFalse);
      expect(Directory('${directory.path}/Generated').listSync().whereType<File>().where((file) => !file.path.endsWith('index.json')), hasLength(GenerationStore.pictureLimit));
    });
  });

  group('a run', () {
    GenerationStore keyed(FakeService service) {
      final store = open(transport: service.transport);
      store.settings = store.settings.copyWith(model: checkpoint);
      return store;
    }

    test('submits, waits, downloads and saves each picture', () async {
      final statuses = ['processing', 'succeeded'];
      final service = FakeService((request) async {
        if (request.uri.host == 'images.example') return GenerationResponse(200, Uint8List.fromList(png));
        if (request.method == 'POST') return json({...succeeded(), 'status': 'scheduled', 'cost': {'total': 6}});
        return json({
          ...succeeded(
            cost: {'total': 6},
            images: [
              {'id': 'a.png', 'url': 'https://images.example/a.png', 'width': 832, 'height': 1216},
              {'id': 'b.png', 'url': 'https://images.example/b.png', 'width': 832, 'height': 1216},
            ],
          ),
          'status': statuses.removeAt(0),
        });
      });
      final store = keyed(service);
      await store.save('abc');
      final run = GenerationRun();
      final phases = <GenerationPhase>[];
      run.addListener(() => phases.add(run.phase));
      run.start(prompt: 'rain', settings: store.settings, store: store);
      expect(run.isRunning, isTrue);
      await run.done;
      expect(run.isRunning, isFalse);
      expect(run.error, isNull);
      expect(run.lastCost, 6);
      expect(run.made, hasLength(2));
      expect(store.pictures, hasLength(2));
      expect(phases, containsAllInOrder([GenerationPhase.sending, GenerationPhase.queued, GenerationPhase.drawing, GenerationPhase.saving, GenerationPhase.idle]));
      expect(service.requests.where((request) => request.uri.host == 'images.example').every((request) => request.header('Authorization') == null), isTrue);
      run.forget(run.made.first);
      expect(run.made, hasLength(1));
    });

    test('shows a moderation refusal and saves nothing', () async {
      final service = FakeService(
        (request) async => json({
          'id': 'wf_1',
          'status': 'failed',
          'steps': [
            {
              'jobs': [
                {'reason': 'blocked', 'blockedReason': 'No.'},
              ],
            },
          ],
        }),
      );
      final store = keyed(service);
      await store.save('abc');
      final run = GenerationRun()..start(prompt: 'x', settings: store.settings, store: store);
      await run.done;
      expect(run.error, const GenerationError.blocked('No.'));
      expect(run.made, isEmpty);
      expect(store.pictures, isEmpty);
    });

    test('shows the error the service gives, and a transport failure', () async {
      final service = FakeService((request) async => json({}, status: 402));
      final store = keyed(service);
      await store.save('abc');
      final run = GenerationRun()..start(prompt: 'x', settings: store.settings, store: store);
      await run.done;
      expect(run.error, const GenerationError.payment());
      final broken = FakeService((request) async => throw const SocketException('offline'));
      final other = keyed(broken);
      await other.save('abc');
      final again = GenerationRun()..start(prompt: 'x', settings: other.settings, store: other);
      await again.done;
      expect(again.error?.kind, GenerationErrorKind.failed);
    });

    test('is cancelled at once, and cancels the job on the service', () async {
      final service = FakeService((request) async {
        if (request.method == 'DELETE') return json({});
        if (request.method == 'POST') return json({...succeeded(), 'status': 'processing'});
        // A long poll that never answers.
        return Future<GenerationResponse>.delayed(const Duration(days: 1), () => json({}));
      });
      final store = keyed(service);
      await store.save('abc');
      final run = GenerationRun()..start(prompt: 'x', settings: store.settings, store: store);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(run.phase, GenerationPhase.drawing);
      run.cancel(store);
      await run.done;
      expect(run.isRunning, isFalse);
      expect(run.error, isNull);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(service.requests.where((request) => request.method == 'DELETE'), hasLength(1));
    }, timeout: const Timeout(Duration(seconds: 10)));

    test('does not start a second run while one is going', () async {
      final service = FakeService((request) async => json(succeeded()));
      final store = keyed(service);
      await store.save('abc');
      final run = GenerationRun();
      run.start(prompt: 'x', settings: store.settings, store: store);
      run.start(prompt: 'y', settings: store.settings, store: store);
      await run.done;
      expect(service.requests.where((request) => request.method == 'POST'), hasLength(1));
    });
  });

  group('the fixture service', () {
    test('answers account, version, search, estimate and a finished job', () async {
      final store = open(transport: GenerationFixture.transport(delay: Duration.zero));
      await store.save('abc');
      final api = store.client();
      expect((await api.account()).name, 'fixture_user');
      expect((await api.version(2514310)).air, GenerationFixture.model.air);
      expect(await api.search('', kind: GenerationKind.checkpoint, mature: false), hasLength(1));
      expect(await api.estimate(prompt: 'x', settings: const GenerationSettings(model: GenerationFixture.model)), 10);
      final job = await api.submit(prompt: 'x', settings: const GenerationSettings(model: GenerationFixture.model));
      expect(GenerationClient.failure(job), isNull);
      expect(await api.picture(job.images.single.url!), GenerationFixture.picture);
      await expectLater(store.clientFor('wrong').account(), throwsA(const GenerationError.invalidKey()));
    });
  });
}

String inputField(FakeService service, int index) {
  final input = ((service.body(index)['steps'] as List).single as Map)['input'] as Map;
  return input.containsKey('model') ? 'model' : 'checkpointModel';
}

class _FailingStorage implements SecureStorage {
  @override
  Future<Map<String, String>> readAll() async => throw StateError('locked');
  @override
  Future<void> write(String key, String value) async => throw StateError('locked');
  @override
  Future<void> delete(String key) async => throw StateError('locked');
}
