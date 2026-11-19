import 'dart:convert';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/addons/addon_models.dart';
import 'package:tegnal/core/addons/addon_store.dart';
import 'package:tegnal/core/booru/booru_store.dart';
import 'package:tegnal/core/support/l10n.dart';
import 'package:tegnal/presentation/settings/addons_view.dart';

import '../../support/addon_market_fixtures.dart';

List<int> _file(String id, String name, String mode) => utf8.encode(
  jsonEncode({
    'format': 'tegnal-addon',
    'schemaVersion': 1,
    'id': id,
    'version': '1.0',
    'mode': mode,
    'name': {'en': name},
    'author': 'TEGNAL',
    'contents': {
      'tagTranslations': {
        'language': 'ko',
        'entries': {'long_hair': '긴 머리'},
      },
    },
  }),
);

void main() {
  setUp(() => L10n.table = {'addon.grade.recommended': 'Recommended'});
  tearDown(() {
    L10n.table = const {};
    AddonRuntime.shared.apply(AddonEffects());
  });

  testWidgets("a mode's page lists its own official add-ons by grade and installs one as official", (tester) async {
    final booru = BooruStore.inMemory();
    final comics = _file('tegnal.ko-tags', 'Korean Tag Names', 'comics');
    final images = _file('tegnal.ko-image-tags', 'Korean Image Tag Names', 'images');
    final market = memoryMarket(
      TestSigningKey(),
      listings: [
        addonListing(comics, id: 'tegnal.ko-tags', name: 'Korean Tag Names', mode: 'comics', grade: 'recommended'),
        addonListing(images, id: 'tegnal.ko-image-tags', name: 'Korean Image Tag Names', mode: 'images', grade: 'recommended'),
      ],
      files: {'files/tegnal.ko-tags/1.0.tegnaladdon': comics, 'files/tegnal.ko-image-tags/1.0.tegnaladdon': images},
    );
    tester.view.physicalSize = const Size(1206, 2622);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      CupertinoApp(
        home: AddonsView(booru: booru, mode: AddonMode.comics, market: market),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Comics Mode Add-ons'), findsOneWidget);
    expect(tester.getTopLeft(find.text('Installed Add-ons')).dy, lessThan(tester.getTopLeft(find.text('Open Add-on File')).dy));
    expect(find.text('Official Add-ons'), findsOneWidget);
    expect(find.text('Recommended'), findsOneWidget);
    expect(find.text('Korean Tag Names'), findsOneWidget);
    expect(find.text('Korean Image Tag Names'), findsNothing, reason: 'Image add-ons are not listed in Comics Mode');
    expect(find.text('Get'), findsOneWidget);
    await tester.tap(find.text('Korean Tag Names'));
    await tester.pumpAndSettle();
    expect(find.textContaining('An official add-on from TEGNAL.'), findsOneWidget);
    expect(find.text('Official Add-ons'), findsWidgets, reason: 'The source is shown before installing');
    await tester.tap(find.text('Install'));
    await tester.pumpAndSettle();

    final installed = AddonStore(booru.database).installed();
    expect(installed.single.official, isTrue);
    expect(installed.single.addon.mode, AddonMode.comics);
    expect(AddonRuntime.shared.effects.enabledCount(AddonMode.comics), 1);
    expect(find.text('Get'), findsNothing);
    expect(find.byIcon(CupertinoIcons.checkmark), findsOneWidget, reason: 'An installed official add-on shows a check');
  });
}
