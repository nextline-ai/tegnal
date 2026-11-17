import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/app/localization.dart';

void main() {
  const expected = {
    'en': (search: 'Search', paste: 'Paste', back: 'Back', sheet: 'Alert'),
    'ko': (search: '검색', paste: '붙여넣기', back: '뒤로', sheet: '알림'),
    'ja': (search: '検索', paste: '貼り付け', back: '戻る', sheet: '通知'),
  };

  for (final MapEntry(key: language, value: words) in expected.entries) {
    testWidgets('Cupertino wording follows the app language ($language)', (tester) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        CupertinoApp(
          locale: Locale(language),
          supportedLocales: appLocales,
          localizationsDelegates: appLocalizationsDelegates,
          home: Builder(
            builder: (context) => CupertinoPageScaffold(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CupertinoSearchTextField(),
                    CupertinoButton(
                      child: const Text('Open'),
                      onPressed: () => showCupertinoModalPopup<void>(
                        context: context,
                        builder: (context) => CupertinoActionSheet(
                          actions: [CupertinoActionSheetAction(onPressed: () {}, child: const Text('Action'))],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );

      final context = tester.element(find.byType(CupertinoSearchTextField));
      expect(Localizations.localeOf(context), Locale(language));
      final cupertino = CupertinoLocalizations.of(context);
      expect(cupertino.pasteButtonLabel, words.paste);
      expect(cupertino.backButtonLabel, words.back);
      expect(find.text(words.search), findsOneWidget);

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel(words.sheet), findsOneWidget);
      semantics.dispose();
    });
  }
}
