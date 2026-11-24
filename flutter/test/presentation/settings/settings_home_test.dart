import 'dart:convert';
import 'dart:io';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/support/l10n.dart';
import 'package:tegnal/presentation/settings/settings_home.dart';

void main() {
  tearDown(() {
    L10n.table = const {};
    L10n.language = 'en';
  });

  void useLanguage(String language) {
    L10n.language = language;
    L10n.table = Map<String, String>.from(jsonDecode(File('assets/l10n/$language.json').readAsStringSync()) as Map);
  }

  test('each mode lists every setting once and every page has something to find', () {
    for (final booru in [false, true]) {
      final items = SettingsCatalog.items(booru: booru);
      expect(items.map((item) => item.id).toSet().length, items.length);
      for (final category in SettingsCategory.values) {
        expect(items.any((item) => item.category == category), isTrue, reason: '$category, booru: $booru');
      }
    }
    expect(
      {...SettingsCategory.groups.expand((group) => group), SettingsCategory.addons},
      SettingsCategory.values.toSet(),
      reason: 'Add-ons sits with the website',
    );
    expect(SettingsCategory.groups.first.first, SettingsCategory.browsing, reason: 'what changes the most comes first');
  });

  test('search matches titles, pages and keywords in the app language', () {
    useLanguage('en');
    final comics = SettingsCatalog.items(booru: false);
    expect(SettingsCatalog.search('right to left', comics).first.id, 'reader.rtl');
    expect(SettingsCatalog.search('dark', comics).map((item) => item.id), contains('appearance.theme'));
    expect(SettingsCatalog.search('block', comics).map((item) => item.id), contains('search.hideTags'));
    expect(SettingsCatalog.search('   ', comics), isEmpty);
    expect(SettingsCatalog.search('blacklist', SettingsCatalog.items(booru: true)).map((item) => item.id), contains('browse.blacklist'));

    useLanguage('ko');
    final korean = SettingsCatalog.items(booru: false);
    expect(SettingsCatalog.search('오른쪽', korean).map((item) => item.id), contains('reader.rtl'));
    expect(SettingsCatalog.search('화면테마', korean).map((item) => item.id), contains('appearance.theme'), reason: 'typed without the spaces a title has');
    expect(SettingsCatalog.search('right to left', korean).map((item) => item.id), contains('reader.rtl'), reason: 'English titles match in every language');
  });

  testWidgets('the top level lists pages in groups, and typing shows matching settings', (tester) async {
    useLanguage('en');
    final opened = <SettingsCategory>[];
    tester.view.physicalSize = const Size(1206, 2622);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      CupertinoApp(
        home: CupertinoPageScaffold(
          child: ListView(
            children: [
              SettingsHome(
                booru: false,
                open: opened.add,
                addonsCount: 2,
                top: const [SizedBox(key: Key('top'), height: 52)],
              ),
            ],
          ),
        ),
      ),
    );
    expect(find.byKey(const Key('top')), findsOneWidget);
    final browsing = tester.getTopLeft(find.byKey(const Key('settings.category.browsing')));
    final viewer = tester.getTopLeft(find.byKey(const Key('settings.category.viewer')));
    expect(browsing.dy, lessThan(viewer.dy));
    expect(find.text('2'), findsOneWidget, reason: 'the add-ons turned on show beside Add-ons');
    expect(
      tester.getTopLeft(find.byKey(const Key('settings.category.addons'))).dy,
      closeTo(tester.getBottomLeft(find.byKey(const Key('top'))).dy, 1),
      reason: 'Add-ons sits right under the website',
    );
    await tester.tap(find.byKey(const Key('settings.category.viewer')));
    expect(opened, [SettingsCategory.viewer]);

    await tester.enterText(find.byKey(const Key('settings.search')), 'right to left');
    await tester.pump();
    expect(find.byKey(const Key('settings.category.browsing')), findsNothing, reason: 'results take the pages’ place');
    expect(find.byKey(const Key('settings.result.reader.rtl')), findsOneWidget);
    await tester.tap(find.byKey(const Key('settings.result.reader.rtl')));
    expect(opened.last, SettingsCategory.viewer);

    await tester.enterText(find.byKey(const Key('settings.search')), 'zzzz');
    await tester.pump();
    expect(find.text('No Matching Settings'), findsOneWidget);
  });
}
