import 'dart:convert';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/addons/addon_models.dart';
import 'package:tegnal/core/addons/addon_store.dart';
import 'package:tegnal/core/booru/booru_store.dart';
import 'package:tegnal/presentation/settings/addons_view.dart';

import '../../support/addon_market_fixtures.dart';

void main() {
  tearDown(() => AddonRuntime.shared.apply(AddonEffects()));

  testWidgets('an official add-on is checked, shown in full and installed as official', (tester) async {
    final booru = BooruStore.inMemory();
    final file = utf8.encode(
      jsonEncode({
        'format': 'tegnal-addon',
        'schemaVersion': 1,
        'id': 'tegnal.ko-tags',
        'version': '1.0',
        'name': {'en': 'Korean Tag Names'},
        'author': 'TEGNAL',
        'contents': {
          'tagTranslations': {
            'language': 'ko',
            'entries': {'long_hair': '긴 머리'},
          },
        },
      }),
    );
    final market = memoryMarket(
      TestSigningKey(),
      listings: [
        {
          'id': 'tegnal.ko-tags',
          'version': '1.0',
          'name': {'en': 'Korean Tag Names'},
          'author': 'TEGNAL',
          'kinds': ['translations'],
          'size': file.length,
          'sha256': Addon.digest(file),
        },
      ],
      files: {'files/tegnal.ko-tags/1.0.tegnaladdon': file},
    );
    tester.view.physicalSize = const Size(1206, 2622);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    var changed = 0;
    await tester.pumpWidget(CupertinoApp(home: AddonMarketView(booru: booru, changed: () => changed += 1, market: market)));
    await tester.pumpAndSettle();

    expect(find.text('Korean Tag Names'), findsOneWidget);
    expect(find.text('Get'), findsOneWidget);
    await tester.tap(find.text('Korean Tag Names'));
    await tester.pumpAndSettle();
    expect(find.textContaining('An official add-on from TEGNAL.'), findsOneWidget);
    expect(find.text('Official Add-ons'), findsWidgets, reason: 'The source is shown before installing');
    await tester.tap(find.text('Install'));
    await tester.pumpAndSettle();

    final installed = AddonStore(booru.database).installed();
    expect(installed.single.official, isTrue);
    expect(changed, 1);
    expect(find.text('Get'), findsNothing);
    expect(find.byIcon(CupertinoIcons.checkmark), findsOneWidget, reason: 'An installed official add-on shows a check');
  });
}
