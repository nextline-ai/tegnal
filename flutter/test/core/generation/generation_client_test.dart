import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/generation/generation_air.dart';
import 'package:tegnal/core/generation/generation_client.dart';

import 'generation_test_support.dart';

GenerationClient client(FakeService service, {String key = ' secret-key ', String? field}) => GenerationClient(key: key, modelField: field, transport: service.transport);

Map<String, dynamic> inputOf(Map<String, dynamic> body) => ((body['steps'] as List).single as Map)['input'] as Map<String, dynamic>;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('request body', () {
    final settings = const GenerationSettings().copyWith(model: checkpoint);

    test('names the engine, ecosystem and operation, and carries every field', () {
      final body = GenerationClient.body(prompt: '1girl, rain', settings: settings.copyWith(seed: 42, quantity: 2));
      final step = (body['steps'] as List).single as Map;
      expect(step[r'$type'], 'imageGen');
      final input = step['input'] as Map;
      expect(input, {
        'engine': 'sdcpp',
        'ecosystem': 'sdxl',
        'operation': 'createImage',
        'model': 'urn:air:sdxl:checkpoint:civitai:827184@2514310',
        'prompt': '1girl, rain',
        'width': 832,
        'height': 1216,
        'steps': 25,
        'cfgScale': 5.5,
        'sampleMethod': 'euler_a',
        'schedule': 'discrete',
        'quantity': 2,
        'negativePrompt': 'worst quality, low quality, lowres, bad anatomy, bad hands, signature, watermark, username, blurry',
        'seed': 42,
      });
    });

    test('leaves out a blank negative prompt and an unset seed', () {
      final input = inputOf(GenerationClient.body(prompt: 'x', settings: settings.copyWith(negative: '  \n ')));
      expect(input.containsKey('negativePrompt'), isFalse);
      expect(input.containsKey('seed'), isFalse);
      expect(input.containsKey('loras'), isFalse);
    });

    test('sends loras as a map from identifier to strength, without duplicates or bad identifiers', () {
      final input = inputOf(
        GenerationClient.body(
          prompt: 'x',
          settings: settings.copyWith(
            loras: [
              const GenerationLora(model: lora, strength: 0.65),
              const GenerationLora(model: lora, strength: 1.2),
              const GenerationLora(model: GenerationModel(air: 'nonsense', name: 'Bad')),
            ],
          ),
        ),
      );
      expect(input['loras'], {'urn:air:sdxl:lora:civitai:123456@789012': 0.65});
    });

    test('says allowMatureContent false only when mature results are off', () {
      expect(GenerationClient.body(prompt: 'x', settings: settings)['allowMatureContent'], false);
      expect(GenerationClient.body(prompt: 'x', settings: settings.copyWith(mature: true)).containsKey('allowMatureContent'), isFalse);
    });

    test('names the checkpoint under the field it is given', () {
      final input = inputOf(GenerationClient.body(prompt: 'x', settings: settings, field: 'checkpointModel'));
      expect(input.containsKey('model'), isFalse);
      expect(input['checkpointModel'], checkpoint.air);
    });

    test('refuses a missing, unreadable or unsupported model', () {
      expect(() => GenerationClient.body(prompt: 'x', settings: const GenerationSettings()), throwsA(const GenerationError.noModel()));
      expect(
        () => GenerationClient.body(prompt: 'x', settings: const GenerationSettings(model: GenerationModel(air: 'junk', name: 'x'))),
        throwsA(const GenerationError.noModel()),
      );
      expect(
        () => GenerationClient.body(prompt: 'x', settings: const GenerationSettings(model: GenerationModel(air: 'urn:air:flux1:checkpoint:civitai:1@2', name: 'x'))),
        throwsA(const GenerationError.unsupportedModel()),
      );
      // A LoRA is not a checkpoint.
      expect(() => GenerationClient.body(prompt: 'x', settings: const GenerationSettings(model: lora)), throwsA(const GenerationError.unsupportedModel()));
    });

    test('takes a family with no type, such as a bare ecosystem and id', () {
      final input = inputOf(
        GenerationClient.body(prompt: 'x', settings: const GenerationSettings(model: GenerationModel(air: 'urn:air:pony:civitai:5@6', name: 'x'))),
      );
      expect(input['ecosystem'], 'sdxl');
    });

    test('estimates the cost by the published formula', () {
      expect(const GenerationSettings(width: 1024, height: 1024, steps: 20).roughCost, 8);
      expect(const GenerationSettings().roughCost, 10);
      expect(const GenerationSettings(width: 1024, height: 1024, steps: 20, quantity: 3).roughCost, 24);
    });
  });

  group('requests', () {
    test('sends the key as a bearer token on API calls, trimmed, and not on the picture download', () async {
      final service = FakeService((request) async {
        if (request.uri.host == 'images.example') return GenerationResponse(200, Uint8List.fromList([1, 2, 3]));
        if (request.uri.path.endsWith('/me')) return json({'username': 'someone', 'status': 'active'});
        return json(succeeded());
      });
      final api = client(service);
      await api.account();
      await api.submit(prompt: 'x', settings: const GenerationSettings(model: checkpoint));
      await api.fetchJob('wf_1');
      final bytes = await api.picture(Uri.parse('https://images.example/a.png'));
      expect(bytes, [1, 2, 3]);
      expect(service.requests, hasLength(4));
      for (final request in service.requests.take(3)) {
        expect(request.header('Authorization'), 'Bearer secret-key');
        expect(request.header('Accept'), 'application/json');
      }
      expect(service.requests.last.header('Authorization'), isNull);
      expect(service.requests.last.headers, isEmpty);
    });

    test('points at the two Civitai hosts', () async {
      final service = FakeService((request) async => request.uri.path.contains('workflows') ? json(succeeded()) : json({'username': 'a', 'status': 'active'}));
      final api = client(service);
      await api.account();
      await api.submit(prompt: 'x', settings: const GenerationSettings(model: checkpoint), wait: 12);
      await api.estimate(prompt: 'x', settings: const GenerationSettings(model: checkpoint));
      await api.fetchJob('wf_9');
      expect(service.requests[0].uri.toString(), 'https://civitai.com/api/v1/me');
      expect(service.requests[1].method, 'POST');
      expect(service.requests[1].uri.toString(), 'https://orchestration.civitai.com/v2/consumer/workflows?wait=12');
      expect(service.requests[1].header('Content-Type'), 'application/json');
      expect(service.requests[2].uri.query, 'whatif=true');
      expect(service.requests[3].uri.toString(), 'https://orchestration.civitai.com/v2/consumer/workflows/wf_9?wait=30');
    });

    test('will not call an authorized endpoint without a key', () async {
      final service = FakeService((request) async => json({}));
      await expectLater(client(service, key: '  ').account(), throwsA(const GenerationError.noKey()));
      expect(service.requests, isEmpty);
    });

    test('looks models up without a key', () async {
      final service = FakeService((request) async => json({'air': checkpoint.air, 'name': 'v1', 'baseModel': 'Illustrious', 'model': {'name': 'Fixture Model'}}));
      final model = await client(service, key: '').version(2514310);
      expect(model.air, checkpoint.air);
      expect(model.name, 'Fixture Model · v1');
      expect(model.base, 'Illustrious');
      expect(model.versionID, 2514310);
      expect(service.requests.single.header('Authorization'), isNull);
      expect(service.requests.single.uri.path, '/api/v1/model-versions/2514310');
    });

    test('answers notFound for a version without a usable identifier', () async {
      for (final answer in [<String, Object?>{'name': 'v1'}, {'air': 'junk'}]) {
        final service = FakeService((request) async => json(answer));
        await expectLater(client(service).version(1), throwsA(const GenerationError.notFound()));
      }
    });

    test('searches checkpoints and LoRAs that support generation', () async {
      final service = FakeService(
        (request) async => json({
          'items': [
            {
              'name': 'Model A',
              'modelVersions': [
                {'id': 11, 'name': 'v2', 'baseModel': 'Pony', 'supportsGeneration': false},
                {'id': 12, 'name': 'v1', 'baseModel': 'Pony', 'supportsGeneration': true},
              ],
            },
            {'name': 'No versions', 'modelVersions': []},
            {'modelVersions': []},
          ],
        }),
      );
      final found = await client(service).search(' rain ', kind: GenerationKind.lora, mature: true);
      expect(found, [const GenerationModel(air: '', name: 'Model A · v1', base: 'Pony', versionID: 12)]);
      expect(found.single.id, 'version:12');
      final query = service.requests.single.uri.queryParameters;
      expect(query, {'limit': '30', 'types': 'LORA', 'supportsGeneration': 'true', 'nsfw': 'true', 'query': 'rain'});
      await client(service).search('', kind: GenerationKind.checkpoint, mature: false);
      expect(service.requests.last.uri.queryParameters, {'limit': '30', 'types': 'Checkpoint', 'supportsGeneration': 'true', 'nsfw': 'false', 'sort': 'Most Downloaded'});
      expect(service.requests.last.uri.query, contains('Most%20Downloaded'));
    });

    test('estimates by the dry run, and reads a cost given as a plain number or string', () async {
      var cost = <String, Object?>{'cost': {'total': 12.5}};
      final service = FakeService((request) async => json(cost));
      expect(await client(service).estimate(prompt: 'x', settings: const GenerationSettings(model: checkpoint)), 12.5);
      cost = {'cost': 7};
      expect(await client(service).estimate(prompt: 'x', settings: const GenerationSettings(model: checkpoint)), 7);
      cost = {'cost': '9'};
      expect(await client(service).estimate(prompt: 'x', settings: const GenerationSettings(model: checkpoint)), 9);
    });
  });

  group('checkpoint field fallback', () {
    test('retries a refused request once under the other name and remembers the one accepted', () async {
      final service = FakeService((request) async {
        final input = inputOf(jsonDecode(request.body!) as Map<String, dynamic>);
        return input.containsKey('checkpointModel') ? json(succeeded()) : json({'detail': 'unknown field'}, status: 400);
      });
      final api = client(service);
      final job = await api.submit(prompt: 'x', settings: const GenerationSettings(model: checkpoint));
      expect(job.status, 'succeeded');
      expect(service.requests, hasLength(2));
      expect(inputOf(service.body(0)).containsKey('model'), isTrue);
      expect(inputOf(service.body(1)).containsKey('checkpointModel'), isTrue);
      expect(api.acceptedModelField, 'checkpointModel');
      // The next request starts with the field that worked.
      await api.submit(prompt: 'x', settings: const GenerationSettings(model: checkpoint));
      expect(service.requests, hasLength(3));
      expect(inputOf(service.body(2)).containsKey('checkpointModel'), isTrue);
    });

    test('goes the other way too', () async {
      final service = FakeService((request) async {
        final input = inputOf(jsonDecode(request.body!) as Map<String, dynamic>);
        return input.containsKey('model') ? json(succeeded()) : json({'detail': 'unknown field'}, status: 422);
      });
      final api = client(service, field: 'checkpointModel');
      await api.estimate(prompt: 'x', settings: const GenerationSettings(model: checkpoint));
      expect(api.acceptedModelField, 'model');
    });

    test('gives the first refusal when both are refused, and keeps the field', () async {
      var count = 0;
      final service = FakeService((request) async => json({'detail': 'refusal ${++count}'}, status: 400));
      final api = client(service);
      await expectLater(api.submit(prompt: 'x', settings: const GenerationSettings(model: checkpoint)), throwsA(const GenerationError.invalid('refusal 1')));
      expect(service.requests, hasLength(2));
      expect(api.acceptedModelField, 'model');
    });

    test('does not retry what is not an invalid request', () async {
      for (final status in [401, 402, 429, 500]) {
        final service = FakeService((request) async => json({}, status: status));
        await expectLater(client(service).submit(prompt: 'x', settings: const GenerationSettings(model: checkpoint)), throwsA(isA<GenerationError>()));
        expect(service.requests, hasLength(1), reason: '$status');
      }
    });

    test('sends no request for a model it cannot run', () async {
      final service = FakeService((request) async => json({}));
      await expectLater(client(service).submit(prompt: 'x', settings: const GenerationSettings()), throwsA(const GenerationError.noModel()));
      expect(service.requests, isEmpty);
    });
  });

  group('errors', () {
    GenerationError map(int status, [Object? body, String? retryAfter]) => GenerationClient.error(status: status, body: body as Map<String, dynamic>?, retryAfter: retryAfter);

    test('maps each status', () {
      expect(map(401), const GenerationError.invalidKey());
      expect(map(402), const GenerationError.payment());
      expect(map(403, {'detail': 'No access to this'}), const GenerationError.forbidden('No access to this'));
      expect(map(404), const GenerationError.notFound());
      expect(map(500, {'detail': 'boom'}), const GenerationError.failed('boom'));
      expect(map(502), const GenerationError.failed());
    });

    test('reads how long to wait from Retry-After', () {
      expect(map(429, null, '12'), const GenerationError.busy(12));
      expect(map(429), const GenerationError.busy());
      expect(map(429, null, 'tomorrow'), const GenerationError.busy());
    });

    test('lists the fields of a validation failure, in order', () {
      final error = map(400, {
        'title': 'One or more validation errors occurred.',
        'detail': 'Bad request',
        'errors': {
          'steps': ['must be at least 8', 'and at most 50'],
          'prompt': ['is required'],
        },
      });
      expect(error, const GenerationError.invalid('Bad request\nprompt: is required\nsteps: must be at least 8 and at most 50'));
    });

    test('falls back to the title or error text', () {
      expect(map(400, {'title': 'Bad things'}), const GenerationError.invalid('Bad things'));
      expect(map(409, {'error': 'Conflict'}), const GenerationError.invalid('Conflict'));
      expect(map(422), const GenerationError.invalid());
    });

    test('reads a refusal that mentions Buzz as a payment problem', () {
      expect(map(400, {'detail': 'You do not have enough Buzz'}), const GenerationError.payment());
      expect(map(403, {'message': 'Insufficient funds'}), const GenerationError.payment());
      expect(map(422, {'detail': 'Payment required'}), const GenerationError.payment());
    });

    test('throws them from a request, with an unreadable body treated as no detail', () async {
      final service = FakeService((request) async => GenerationResponse(401, Uint8List.fromList(utf8.encode('<html>nope</html>'))));
      await expectLater(client(service).account(), throwsA(const GenerationError.invalidKey()));
      final empty = FakeService((request) async => GenerationResponse(200, Uint8List(0)));
      await expectLater(client(empty).account(), throwsA(const GenerationError.unreadable()));
      final busy = FakeService((request) async => json({}, status: 429, headers: {'Retry-After': '7'}));
      await expectLater(client(busy).account(), throwsA(const GenerationError.busy(7)));
    });

    test('has a message for each', () {
      for (final error in [
        const GenerationError.noKey(),
        const GenerationError.invalidKey(),
        const GenerationError.forbidden(),
        const GenerationError.invalid(),
        const GenerationError.payment(),
        const GenerationError.busy(),
        const GenerationError.blocked(),
        const GenerationError.failed(),
        const GenerationError.unsupportedModel(),
        const GenerationError.noModel(),
        const GenerationError.notFound(),
        const GenerationError.unreadable(),
      ]) {
        expect(error.message, isNotEmpty);
      }
      expect(const GenerationError.noKey().message, 'Add your Civitai API key to generate pictures.');
      expect(const GenerationError.forbidden('Muted').message, 'Muted');
      expect(const GenerationError.blocked('why').message, endsWith('\nwhy'));
      expect(const GenerationError.blocked().message, isNot(contains('\n')));
    });
  });

  group('jobs', () {
    test('reads a finished job with its pictures and cost', () {
      final job = GenerationClient.job(
        succeeded(
          images: [
            {'id': 'a.png', 'url': 'https://images.example/a.png', 'width': 832, 'height': 1216},
            {'id': 'b.png', 'available': false, 'blockedReason': 'mature'},
          ],
        ),
      );
      expect(job.id, 'wf_1');
      expect(job.status, 'succeeded');
      expect(job.cost, 10);
      expect(job.isFinished, isTrue);
      expect(job.images, hasLength(2));
      expect(job.images[0].available, isTrue);
      expect(job.images[0].width, 832);
      expect(job.images[0].url, Uri.parse('https://images.example/a.png'));
      expect(job.images[1].available, isFalse);
      expect(job.images[1].url, isNull);
      expect(job.images[1].blockedReason, 'mature');
    });

    test('takes an image with an address as available, and one without as not', () {
      final job = GenerationClient.job({
        'id': 'x',
        'steps': [
          {
            'output': {
              'images': [
                {'id': '1', 'url': 'https://images.example/1.png'},
                {'id': '2'},
                {'url': 'https://images.example/no-id.png'},
              ],
            },
          },
        ],
      });
      expect(job.status, 'unassigned');
      expect(job.isQueued, isTrue);
      expect(job.images.map((image) => image.available), [true, false]);
    });

    test('keeps the first reasons the jobs give', () {
      final job = GenerationClient.job({
        'id': 'x',
        'status': 'failed',
        'steps': [
          {
            'jobs': [
              {'reason': 'blocked', 'blockedReason': 'first'},
              {'reason': 'other', 'blockedReason': 'second'},
            ],
          },
        ],
      });
      expect(job.reason, 'blocked');
      expect(job.blockedReason, 'first');
    });

    test('accepts a dry run that has only a cost, and rejects what has neither', () {
      expect(GenerationClient.job({'cost': {'total': 3}}).id, '');
      expect(() => GenerationClient.job({'status': 'x'}), throwsA(const GenerationError.unreadable()));
      expect(() => GenerationClient.job([1]), throwsA(const GenerationError.unreadable()));
    });

    test('sorts statuses into finished and queued', () {
      for (final status in ['succeeded', 'failed', 'expired', 'canceled']) {
        expect(GenerationJob(id: 'x', status: status).isFinished, isTrue);
      }
      for (final status in ['unassigned', 'preparing', 'scheduled']) {
        expect(GenerationJob(id: 'x', status: status).isQueued, isTrue);
        expect(GenerationJob(id: 'x', status: status).isFinished, isFalse);
      }
      expect(GenerationJob(id: 'x', status: 'processing').isQueued, isFalse);
    });
  });

  group('failure of a job', () {
    GenerationImage image({bool available = true, bool hasUrl = true}) => GenerationImage(id: 'a', url: hasUrl ? Uri.parse('https://images.example/a.png') : null, available: available);

    test('is none when a picture can be shown', () {
      expect(GenerationClient.failure(GenerationJob(id: 'x', status: 'succeeded', images: [image()])), isNull);
      expect(GenerationClient.failure(GenerationJob(id: 'x', status: 'succeeded', images: [image(available: false), image()])), isNull);
    });

    test('is a moderation refusal when the reason says blocked, or nothing came and a block was reported', () {
      expect(GenerationClient.failure(GenerationJob(id: 'x', status: 'failed', reason: 'blocked', blockedReason: 'why')), const GenerationError.blocked('why'));
      expect(GenerationClient.failure(GenerationJob(id: 'x', status: 'succeeded', reason: 'blocked', images: [image()])), const GenerationError.blocked());
      expect(GenerationClient.failure(GenerationJob(id: 'x', status: 'succeeded', blockedReason: 'minor')), const GenerationError.blocked('minor'));
    });

    test('says a withheld result was withheld, and an empty success failed', () {
      final withheld = GenerationClient.failure(GenerationJob(id: 'x', status: 'succeeded', images: [image(available: false, hasUrl: false)]))!;
      expect(withheld.kind, GenerationErrorKind.failed);
      expect(withheld.detail, 'The result was withheld. Results rated as mature are only returned when that is allowed.');
      expect(GenerationClient.failure(GenerationJob(id: 'x', status: 'succeeded')), const GenerationError.failed());
    });

    test('explains cancelled, expired and failed jobs', () {
      expect(GenerationClient.failure(GenerationJob(id: 'x', status: 'canceled'))!.detail, 'The request was cancelled.');
      expect(GenerationClient.failure(GenerationJob(id: 'x', status: 'expired'))!.detail, 'The request ran out of time. It is safe to try again.');
      expect(GenerationClient.failure(GenerationJob(id: 'x', status: 'failed', reason: 'no_provider_available'))!.detail, 'No worker can run this request right now. Try other settings or try later.');
      expect(GenerationClient.failure(GenerationJob(id: 'x', status: 'failed')), const GenerationError.failed());
    });
  });

  group('waiting for a job', () {
    test('asks again until the job has finished, reporting progress', () async {
      final statuses = ['scheduled', 'processing', 'succeeded'];
      final service = FakeService((request) async => json({...succeeded(), 'status': statuses.removeAt(0)}));
      final seen = <String>[];
      final job = await client(service).finish(
        GenerationJob(id: 'wf_1', status: 'unassigned'),
        progress: (current) async => seen.add(current.status),
      );
      expect(job.status, 'succeeded');
      expect(seen, ['unassigned', 'scheduled', 'processing']);
      expect(service.requests, hasLength(3));
      expect(service.requests.every((request) => request.uri.path.endsWith('/workflows/wf_1')), isTrue);
    });

    test('returns a job that has already finished without asking', () async {
      final service = FakeService((request) async => json({}));
      final job = await client(service).finish(GenerationJob(id: 'x', status: 'succeeded'));
      expect(job.status, 'succeeded');
      expect(service.requests, isEmpty);
    });

    test('stops when it is cancelled, and gives up after the limit', () async {
      final service = FakeService((request) async => json({...succeeded(), 'status': 'processing'}));
      var asked = 0;
      await expectLater(
        client(service).finish(GenerationJob(id: 'x', status: 'processing'), isCancelled: () => ++asked > 2),
        throwsA(isA<GenerationCancelled>()),
      );
      expect(service.requests, hasLength(2));
      await expectLater(client(service).finish(GenerationJob(id: 'x', status: 'processing'), limit: 0), throwsA(const GenerationError.failed('The picture is taking too long. It may still finish on Civitai.')));
    });

    test('cancels a job with DELETE and ignores a failure', () async {
      final service = FakeService((request) async => throw StateError('offline'));
      await client(service).cancel('wf_3');
      expect(service.requests.single.method, 'DELETE');
      expect(service.requests.single.uri.path, endsWith('/workflows/wf_3'));
    });
  });

  group('pictures', () {
    test('fail on an error status or an empty body', () async {
      final missing = FakeService((request) async => GenerationResponse(404, Uint8List.fromList([1])));
      await expectLater(client(missing).picture(Uri.parse('https://images.example/a.png')), throwsA(const GenerationError.failed()));
      final empty = FakeService((request) async => GenerationResponse(200, Uint8List(0)));
      await expectLater(client(empty).picture(Uri.parse('https://images.example/a.png')), throwsA(const GenerationError.failed()));
    });
  });

  group('settings', () {
    test('round trip through JSON', () {
      final settings = const GenerationSettings().copyWith(
        model: checkpoint,
        loras: [const GenerationLora(model: lora, strength: 0.45)],
        seed: 4294967295,
        quantity: 3,
        mature: true,
        sampler: 'lcm',
        guidance: 7.5,
      );
      expect(GenerationSettings.fromJson(jsonDecode(jsonEncode(settings.toJson()))), settings);
      expect(GenerationSettings.fromJson(null), const GenerationSettings());
    });
  });
}
