import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/generation/generation_air.dart';
import 'package:tegnal/core/generation/generation_client.dart';
import 'package:tegnal/core/generation/generation_store.dart';
import 'package:tegnal/core/support/preferences.dart';
import 'package:tegnal/core/support/secure_secret_store.dart';
import 'package:tegnal/presentation/design/ios_controls.dart';
import 'package:tegnal/presentation/design/tegnal_theme.dart';
import 'package:tegnal/presentation/generation/generator_account_view.dart';
import 'package:tegnal/presentation/generation/generator_model_picker.dart';
import 'package:tegnal/presentation/generation/generator_sheet.dart';
import 'package:tegnal/presentation/generation/generator_view.dart';

Finder key(String name) => find.byKey(Key(name));

GenerationResponse json(Object? object, {int status = 200}) => GenerationResponse(status, Uint8List.fromList(utf8.encode(jsonEncode(object))));

class Harness {
  Harness({this.safeMode = false, GenerationTransport? transport, bool keyed = false, bool model = false}) {
    directory = Directory.systemTemp.createTempSync('generator-view-');
    addTearDown(() => directory.deleteSync(recursive: true));
    secure = MemorySecureStorage();
    if (keyed) secure.values['tegnal.generation.civitai'] = 'test-key';
    store = GenerationStore(
      folder: Directory('${directory.path}/Generated'),
      defaults: MemoryPreferences(),
      keychain: GenerationKeychain(secure),
      transport: (request) {
        requests.add(request);
        return (transport ?? GenerationFixture.transport(delay: Duration.zero))(request);
      },
    );
    if (model) store.settings = store.settings.copyWith(model: GenerationFixture.model);
  }

  bool safeMode;
  late final Directory directory;
  late final MemorySecureStorage secure;
  late final GenerationStore store;
  final requests = <GenerationRequest>[];

  Future<void> pump(WidgetTester tester, {String prompt = '', double height = 9000}) async {
    tester.view.physicalSize = Size(1206, height);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await store.load();
    await tester.pumpWidget(CupertinoApp(theme: tegnalTheme(Brightness.light), home: GeneratorView(store: store, safeMode: () => safeMode, prompt: prompt)));
    await tester.pump();
  }
}

/// Lets zero-delay futures and short timers run until [finder] matches.
Future<void> pumpUntil(WidgetTester tester, Finder finder) async {
  for (var step = 0; step < 100 && finder.evaluate().isEmpty; step++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(finder, findsWidgets);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('without a key', () {
    testWidgets('offers to add one, and Generate opens the key screen', (tester) async {
      final harness = Harness(model: true);
      await harness.pump(tester);
      expect(find.text('Add Your Civitai API Key'), findsOneWidget);
      expect(find.text("Pictures are drawn by Civitai on your own account and paid for with your Buzz. The key stays in this device's keychain."), findsOneWidget);
      // With no prompt, Generate does nothing.
      await tester.tap(key('generator.generate'));
      await tester.pump();
      expect(key('generator.key'), findsNothing);

      await tester.enterText(key('generator.prompt'), '1girl, rain');
      await tester.pump();
      expect(find.textContaining('About'), findsNothing);
      await tester.tap(key('generator.generate'));
      await tester.pumpAndSettle();
      expect(key('generator.key'), findsOneWidget);
      expect(find.text('Check and Save'), findsOneWidget);
      expect(harness.requests, isEmpty);
    });

    testWidgets('the row opens the key screen too, and a key that Civitai accepts is saved and the row goes away', (tester) async {
      final harness = Harness();
      await harness.pump(tester);
      await tester.tap(key('generator.addKey'));
      await tester.pumpAndSettle();
      expect(key('generator.key'), findsOneWidget);
      expect(key('generator.removeKey'), findsNothing);
      await tester.enterText(key('generator.key'), '  my-key ');
      await tester.pump();
      await tester.tap(key('generator.saveKey'));
      await pumpUntil(tester, key('generator.signedIn'));
      expect(find.text('Signed in as fixture_user'), findsOneWidget);
      expect(harness.store.hasKey, isTrue);
      expect(harness.secure.values['tegnal.generation.civitai'], 'my-key');
      expect(harness.requests.single.header('Authorization'), 'Bearer my-key');
      expect(key('generator.removeKey'), findsOneWidget);
      await tester.tap(key('generator.done'));
      await tester.pumpAndSettle();
      expect(key('generator.addKey'), findsNothing);
    });

    testWidgets('a key that Civitai refuses is not saved', (tester) async {
      final harness = Harness();
      await harness.pump(tester);
      await tester.tap(key('generator.account'));
      await tester.pumpAndSettle();
      await tester.enterText(key('generator.key'), 'wrong');
      await tester.pump();
      await tester.tap(key('generator.saveKey'));
      await pumpUntil(tester, key('generator.keyMessage'));
      expect(find.text('Civitai did not accept this API key.'), findsOneWidget);
      expect(harness.store.hasKey, isFalse);
      expect(harness.secure.values, isEmpty);
    });

    testWidgets('removing a saved key clears it', (tester) async {
      final harness = Harness(keyed: true);
      await harness.pump(tester);
      expect(key('generator.addKey'), findsNothing);
      await tester.tap(key('generator.account'));
      await tester.pumpAndSettle();
      await pumpUntil(tester, key('generator.signedIn'));
      await tester.tap(key('generator.removeKey'));
      await tester.pumpAndSettle();
      expect(harness.store.hasKey, isFalse);
      expect(harness.secure.values, isEmpty);
      expect(key('generator.signedIn'), findsNothing);
      expect(key('generator.removeKey'), findsNothing);
    });
  });

  group('with a key and a model', () {
    testWidgets('Generate shows the estimate, sends the request and shows a result tile', (tester) async {
      final harness = Harness(keyed: true, model: true);
      await harness.pump(tester);
      expect(find.text('Fixture Model · v1'), findsOneWidget);
      await tester.enterText(key('generator.prompt'), '1girl, rain');
      await tester.pump();
      // The rough figure first, then the service's own estimate.
      expect(find.text('· About 10 Buzz'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 1000));
      expect(harness.requests.where((request) => request.uri.query.contains('whatif=true')), hasLength(1));

      await tester.tap(key('generator.generate'));
      await pumpUntil(tester, key('generator.result.0'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(key('generator.cancel'), findsNothing);
      expect(find.text('Results'), findsOneWidget);
      expect(find.text('The last request cost 10 Buzz.'), findsOneWidget);
      expect(key('generator.gallery'), findsOneWidget);
      expect(harness.store.pictures, hasLength(1));
      final submit = harness.requests.firstWhere((request) => request.method == 'POST' && request.uri.query.contains('wait='));
      final input = ((jsonDecode(submit.body!) as Map)['steps'] as List).single['input'] as Map;
      expect(input['prompt'], '1girl, rain');
      expect(input['model'], GenerationFixture.model.air);
      expect(submit.header('Authorization'), 'Bearer test-key');
      expect(harness.requests.last.header('Authorization'), isNull);
    });

    testWidgets('shows what it is doing and a Cancel button while it runs, and Cancel ends it', (tester) async {
      final harness = Harness(keyed: true, model: true, transport: GenerationFixture.transport(delay: const Duration(milliseconds: 300)));
      await harness.pump(tester, prompt: 'x');
      await tester.tap(key('generator.generate'));
      await tester.pump();
      expect(find.text('Sending…'), findsOneWidget);
      expect(key('generator.cancel'), findsOneWidget);
      await tester.tap(key('generator.cancel'));
      await tester.pump();
      await tester.pump();
      expect(key('generator.cancel'), findsNothing);
      expect(find.text('Generate'), findsOneWidget);
      expect(key('generator.error'), findsNothing);
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('scrolls the new result and an error into view on a short screen', (tester) async {
      final harness = Harness(keyed: true, model: true);
      await harness.pump(tester, prompt: 'cat', height: 1500);
      final screen = tester.view.physicalSize.height / tester.view.devicePixelRatio;
      await tester.scrollUntilVisible(key('generator.generate'), 300, scrollable: find.byType(Scrollable).first);
      await tester.tap(key('generator.generate'));
      await tester.pump();
      await pumpUntil(tester, find.byKey(const Key('generator.result.0'), skipOffstage: false));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
      final tile = tester.getRect(key('generator.result.0'));
      expect(tile.top, greaterThanOrEqualTo(0));
      expect(tile.bottom, lessThanOrEqualTo(screen));

      final failing = Harness(keyed: true, model: true, transport: (request) async => json({}, status: 402));
      await failing.pump(tester, prompt: 'cat', height: 1500);
      await tester.scrollUntilVisible(key('generator.generate'), 300, scrollable: find.byType(Scrollable).first);
      await tester.tap(key('generator.generate'));
      await pumpUntil(tester, find.byKey(const Key('generator.error'), skipOffstage: false));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
      final error = tester.getRect(key('generator.error'));
      expect(error.top, greaterThanOrEqualTo(0));
      expect(error.bottom, lessThanOrEqualTo(screen));
    });

    testWidgets('opens a result, and deletes it after asking', (tester) async {
      final harness = Harness(keyed: true, model: true);
      await harness.pump(tester, prompt: 'cat');
      await tester.tap(key('generator.generate'));
      await pumpUntil(tester, key('generator.result.0'));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(key('generator.result.0'));
      await tester.pumpAndSettle();
      expect(find.text('Share or Save'), findsOneWidget);
      expect(find.text('Copy Prompt'), findsOneWidget);
      expect(find.text('Use These Settings'), findsOneWidget);
      expect(find.text('832 × 1216'), findsWidgets);
      await tester.tap(key('generator.delete'));
      await tester.pumpAndSettle();
      expect(find.text('Delete this picture?'), findsOneWidget);
      await tester.tap(key('generator.confirmDelete'));
      await tester.pumpAndSettle();
      expect(harness.store.pictures, isEmpty);
      expect(key('generator.result.0'), findsNothing);
      expect(key('generator.gallery'), findsNothing);
    });

    testWidgets('a blocked job shows the moderation message', (tester) async {
      final harness = Harness(
        keyed: true,
        model: true,
        transport: (request) async => json({
          'id': 'wf_1',
          'status': 'failed',
          'steps': [
            {
              'jobs': [
                {'reason': 'blocked', 'blockedReason': 'Not allowed here.'},
              ],
            },
          ],
        }),
      );
      await harness.pump(tester, prompt: 'x');
      await tester.tap(key('generator.generate'));
      await pumpUntil(tester, key('generator.error'));
      final shown = tester.widget<Text>(key('generator.error')).data!;
      expect(shown, startsWith("Civitai's moderation refused this prompt."));
      expect(shown, endsWith('Not allowed here.'));
      expect(key('generator.result.0'), findsNothing);
      expect(harness.store.pictures, isEmpty);
      // The button works again.
      expect(find.text('Generate'), findsOneWidget);
    });

    testWidgets('a refusal from the service shows its message', (tester) async {
      final harness = Harness(keyed: true, model: true, transport: (request) async => json({}, status: 402));
      await harness.pump(tester, prompt: 'x');
      await tester.tap(key('generator.generate'));
      await pumpUntil(tester, key('generator.error'));
      expect(find.text('Not enough Buzz on this account.'), findsOneWidget);
    });

    testWidgets('settings change the store, and Apply a Model\'s Recommended Tags writes the preset', (tester) async {
      final harness = Harness(keyed: true, model: true);
      await harness.pump(tester, prompt: '1girl');
      await tester.tap(find.descendant(of: key('generator.steps'), matching: key('increment')));
      await tester.pump();
      expect(harness.store.settings.steps, 26);
      await tester.tap(find.descendant(of: key('generator.quantity'), matching: key('increment')));
      await tester.pump();
      expect(harness.store.settings.quantity, 2);
      expect(find.text('· About 21 Buzz'), findsOneWidget);
      await tester.tap(find.descendant(of: key('generator.randomSeed'), matching: find.byType(TegnalSwitch)));
      await tester.pump();
      expect(harness.store.settings.seed, isNotNull);
      expect(key('generator.seed'), findsOneWidget);
      await tester.enterText(key('generator.seed'), '1234');
      await tester.pump();
      expect(harness.store.settings.seed, 1234);

      await tester.tap(key('generator.preset'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Illustrious XL'));
      await tester.pumpAndSettle();
      expect(tester.widget<CupertinoTextField>(key('generator.prompt')).controller!.text, 'masterpiece, best quality, 1girl');
      expect(harness.store.settings.steps, 28);
      expect(harness.store.settings.guidance, 6);
      expect(harness.store.settings.negative, startsWith('worst quality, comic'));
      expect(tester.widget<CupertinoTextField>(key('generator.negative')).controller!.text, startsWith('worst quality, comic'));
    });

    testWidgets('LoRAs are added from the picker, shown with a strength and removed by swiping', (tester) async {
      final harness = Harness(keyed: true, model: true);
      harness.store.settings = harness.store.settings.copyWith(loras: [const GenerationLora(model: GenerationModel(air: 'urn:air:sdxl:lora:civitai:1@2', name: 'Style LoRA'))]);
      await harness.pump(tester);
      expect(find.text('Style LoRA'), findsOneWidget);
      expect(find.text('0.80'), findsOneWidget);
      await tester.drag(find.text('Style LoRA'), const Offset(-600, 0));
      await tester.pumpAndSettle();
      expect(harness.store.settings.loras, isEmpty);
      expect(find.text('Style LoRA'), findsNothing);
    });
  });

  group('Safe Mode', () {
    testWidgets('hides Allow Mature Results, and never asks for mature results', (tester) async {
      final harness = Harness(keyed: true, model: true, safeMode: true);
      harness.store.settings = harness.store.settings.copyWith(mature: true);
      await harness.pump(tester, prompt: 'x');
      expect(find.text('Allow Mature Results'), findsNothing);
      await tester.tap(key('generator.generate'));
      await pumpUntil(tester, key('generator.result.0'));
      await tester.pump(const Duration(milliseconds: 100));
      final submit = harness.requests.firstWhere((request) => request.method == 'POST' && request.uri.query.contains('wait='));
      expect((jsonDecode(submit.body!) as Map)['allowMatureContent'], false);
      // The stored switch is left as it was for when Safe Mode is turned off.
      expect(harness.store.settings.mature, isTrue);
    });

    testWidgets('shows the switch otherwise, and leaves allowMatureContent out when it is on', (tester) async {
      final harness = Harness(keyed: true, model: true);
      await harness.pump(tester, prompt: 'x');
      expect(find.text('Allow Mature Results'), findsOneWidget);
      await tester.tap(find.descendant(of: key('generator.mature'), matching: find.byType(TegnalSwitch)));
      await tester.pump();
      expect(harness.store.settings.mature, isTrue);
      await tester.tap(key('generator.generate'));
      await pumpUntil(tester, key('generator.result.0'));
      await tester.pump(const Duration(milliseconds: 100));
      final submit = harness.requests.firstWhere((request) => request.method == 'POST' && request.uri.query.contains('wait='));
      expect((jsonDecode(submit.body!) as Map).containsKey('allowMatureContent'), isFalse);
    });
  });

  group('model picker', () {
    GeneratorModelPicker picker(Harness harness, void Function(GenerationModel) choose, {GenerationKind kind = GenerationKind.checkpoint}) =>
        GeneratorModelPicker(key: UniqueKey(), environment: GeneratorEnvironment(store: harness.store, safeMode: () => harness.safeMode), kind: kind, choose: choose);

    Future<void> open(WidgetTester tester, Harness harness, Widget page) async {
      tester.view.physicalSize = const Size(1206, 9000);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await harness.store.load();
      await tester.pumpWidget(CupertinoApp(theme: tegnalTheme(Brightness.light), home: page));
      await tester.pump();
    }

    testWidgets('lists models that support generation, and looks the chosen one up for its AIR', (tester) async {
      final harness = Harness(keyed: true);
      GenerationModel? chosen;
      await open(tester, harness, picker(harness, (model) => chosen = model));
      await pumpUntil(tester, key('generator.modelRow.0'));
      expect(find.text('Fixture Model · v1'), findsOneWidget);
      expect(find.text('Most Downloaded on Civitai'), findsOneWidget);
      final search = harness.requests.firstWhere((request) => request.uri.path.endsWith('/models'));
      expect(search.uri.queryParameters['supportsGeneration'], 'true');
      expect(search.uri.queryParameters['nsfw'], 'false');
      expect(search.uri.queryParameters['types'], 'Checkpoint');
      await tester.tap(key('generator.modelRow.0'));
      await tester.pump();
      await tester.pump();
      expect(chosen?.air, GenerationFixture.model.air);
      expect(harness.store.recentModels.single.air, GenerationFixture.model.air);
    });

    testWidgets('asks for mature results only when they are allowed and Safe Mode is off', (tester) async {
      final harness = Harness(keyed: true);
      harness.store.settings = harness.store.settings.copyWith(mature: true);
      await open(tester, harness, picker(harness, (model) {}));
      await pumpUntil(tester, key('generator.modelRow.0'));
      expect(harness.requests.firstWhere((request) => request.uri.path.endsWith('/models')).uri.queryParameters['nsfw'], 'true');

      final safe = Harness(keyed: true, safeMode: true);
      safe.store.settings = safe.store.settings.copyWith(mature: true);
      await open(tester, safe, picker(safe, (model) {}));
      await pumpUntil(tester, key('generator.modelRow.0'));
      expect(safe.requests.firstWhere((request) => request.uri.path.endsWith('/models')).uri.queryParameters['nsfw'], 'false');
    });

    testWidgets('takes a pasted AIR as it is', (tester) async {
      final harness = Harness();
      GenerationModel? chosen;
      await open(tester, harness, picker(harness, (model) => chosen = model));
      await tester.enterText(key('generator.air'), ' sdxl:checkpoint:huggingface:org/name@main ');
      await tester.pump();
      await tester.tap(key('generator.useAIR'));
      await tester.pump();
      await tester.pump();
      expect(chosen?.air, 'urn:air:sdxl:checkpoint:huggingface:org/name@main');
    });

    testWidgets('looks up a pasted version number or page address', (tester) async {
      final harness = Harness();
      GenerationModel? chosen;
      await open(tester, harness, picker(harness, (model) => chosen = model));
      await tester.enterText(key('generator.air'), 'https://civitai.com/models/827184?modelVersionId=2514310');
      await tester.pump();
      await tester.tap(key('generator.useAIR'));
      await tester.pump();
      await tester.pump();
      expect(chosen?.name, 'Fixture Model · v1');
      expect(harness.requests.any((request) => request.uri.path == '/api/v1/model-versions/2514310'), isTrue);
    });

    testWidgets('says why a paste cannot be used', (tester) async {
      final harness = Harness();
      var chosen = false;
      await open(tester, harness, picker(harness, (model) => chosen = true));
      for (final (text, message) in [
        ('hello there', 'This is not an AIR, a model page address or a version number.'),
        ('urn:air:flux1:checkpoint:civitai:1@2', 'This generator runs Stable Diffusion 1.5 and SDXL-family checkpoints, such as Illustrious, NoobAI, Pony and Animagine.'),
        ('urn:air:sdxl:lora:civitai:1@2', 'This is not a checkpoint.'),
      ]) {
        await tester.enterText(key('generator.air'), text);
        await tester.pump();
        await tester.tap(key('generator.useAIR'));
        await tester.pump();
        await tester.pump();
        expect(find.text(message), findsOneWidget, reason: text);
      }
      expect(chosen, isFalse);
    });

    testWidgets('lists recent models of the same kind', (tester) async {
      final harness = Harness();
      harness.store.remember(GenerationFixture.model);
      harness.store.remember(const GenerationModel(air: 'urn:air:sdxl:lora:civitai:1@2', name: 'A LoRA'));
      GenerationModel? chosen;
      await open(tester, harness, picker(harness, (model) => chosen = model));
      expect(find.text('Recent'), findsOneWidget);
      expect(find.text('A LoRA'), findsNothing);
      await tester.tap(key('generator.recentRow.0'));
      await tester.pump();
      expect(chosen, GenerationFixture.model);
    });
  });

  testWidgets('the key screen stands alone with a store', (tester) async {
    final harness = Harness();
    tester.view.physicalSize = const Size(1206, 9000);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(CupertinoApp(theme: tegnalTheme(Brightness.light), home: GeneratorAccountView(store: harness.store)));
    await tester.pump();
    expect(find.text('Civitai API Key'), findsOneWidget);
    expect(find.text('Open Civitai Account Settings'), findsOneWidget);
    expect(find.text("Create a key on civitai.com under Account Settings, API Keys. It is kept in this device's keychain and sent only to Civitai."), findsOneWidget);
  });
}
