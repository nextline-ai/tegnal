import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/app_controller.dart';
import 'package:tegnal/core/content.dart';
import 'package:tegnal/data/download_manager.dart';
import 'package:tegnal/data/library_store.dart';
import 'package:tegnal/features/settings_screen.dart';
import 'package:tegnal/ui/design_system.dart';
import 'package:tegnal/ui/l10n.dart';

void main() {
  late Directory directory;
  late LibraryStore store;
  late AppController controller;
  late DownloadManager downloads;
  final opened = <String>[];
  const launcher = MethodChannel('plugins.flutter.io/url_launcher');

  setUp(() async {
    await L10n.load();
    directory = await Directory.systemTemp.createTemp('tegnal-community-');
    store = LibraryStore.memory();
    controller = AppController(store);
    downloads = DownloadManager(store, directory);
    opened.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(launcher, (call) async {
          expect(call.method, 'launch');
          opened.add((call.arguments as Map)['url'] as String);
          return true;
        });
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(launcher, null);
    downloads.dispose();
    controller.dispose();
    store.close();
    await directory.delete(recursive: true);
  });

  Future<void> mount(
    WidgetTester tester, {
    String language = 'en',
    AppMode mode = AppMode.booru,
    bool offstage = false,
  }) async {
    tester.view.physicalSize = const Size(480, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        locale: Locale(language),
        supportedLocales: const [Locale('en'), Locale('ko'), Locale('ja')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        theme: tegnalTheme(Brightness.dark),
        home: Offstage(
          offstage: offstage,
          child: Scaffold(
            body: SettingsScreen(
              controller: controller,
              downloads: downloads,
              mode: mode,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('invitation records actual painting and closes for seven days', (
    tester,
  ) async {
    store.setSetting('discord.invitation.dismissed', true);
    await mount(tester, offstage: true);
    expect(controller.discordInvitationVisible, isTrue);
    expect(store.setting('discord.invitation.nextPresentation', 0), 0);
    final before = DateTime.now().millisecondsSinceEpoch / 1000;
    await mount(tester);
    expect(find.byKey(const ValueKey('discord.invitation')), findsOneWidget);
    final next = store.setting('discord.invitation.nextPresentation') as num;
    expect(next, inInclusiveRange(before + 3 * 86400, before + 3 * 86400 + 10));
    final join = find.byKey(const ValueKey('discord.invitation.join'));
    final close = find.byKey(const ValueKey('discord.invitation.close'));
    expect(tester.getSize(join).height, greaterThanOrEqualTo(44));
    expect(tester.getSize(close).height, greaterThanOrEqualTo(44));
    await tester.tap(join);
    await tester.pumpAndSettle();
    expect(opened, ['https://discord.gg/DFT9Hm66Gz']);
    await tester.tap(close);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('discord.invitation')), findsNothing);
    expect(controller.discordInvitationVisible, isFalse);
    expect(
      store.setting('discord.invitation.nextPresentation') as num,
      inInclusiveRange(before + 7 * 86400, before + 7 * 86400 + 10),
    );
  });

  for (final language in ['ko', 'en', 'ja']) {
    for (final mode in AppMode.values) {
      testWidgets(
        'native developer badges stay accessible in $language ${mode.name}',
        (tester) async {
          final semantics = tester.ensureSemantics();
          try {
            await mount(tester, language: language, mode: mode);
            final scroll = find
                .descendant(
                  of: find.byType(SettingsScreen),
                  matching: find.byType(Scrollable),
                )
                .first;
            for (final service in ['community', 'github']) {
              final badge = find.byKey(ValueKey('developer.$service'));
              await tester.scrollUntilVisible(badge, 500, scrollable: scroll);
              await Scrollable.ensureVisible(
                tester.element(badge),
                alignment: .5,
              );
              await tester.pumpAndSettle();
              final image = tester.widget<Image>(
                find.descendant(of: badge, matching: find.byType(Image)),
              );
              expect(
                (image.image as AssetImage).assetName,
                'assets/branding/developer-${service == 'community' ? 'discord' : 'github'}-${language == 'ko' ? 'ko' : 'en'}.png',
              );
              expect(
                tester
                    .getSize(
                      find.descendant(of: badge, matching: find.byType(Image)),
                    )
                    .width,
                lessThanOrEqualTo(400),
              );
              final semanticBadge = find
                  .descendant(of: badge, matching: find.byType(Semantics))
                  .first;
              final data = tester
                  .getSemantics(semanticBadge)
                  .getSemanticsData();
              expect(data.flagsCollection.isButton, isTrue);
              expect(data.flagsCollection.isLink, isTrue);
              expect(
                data.label,
                service == 'community'
                    ? '${L10n.tr(tester.element(badge), 'Community & Bug Reports')} · Discord'
                    : L10n.tr(tester.element(badge), 'View on GitHub'),
              );
              await tester.tap(badge);
              await tester.pumpAndSettle();
              expect(
                opened.last,
                service == 'community'
                    ? 'https://discord.gg/DFT9Hm66Gz'
                    : 'https://github.com/nextline-ai/tegnal',
              );
            }
            expect(tester.takeException(), isNull);
          } finally {
            semantics.dispose();
          }
        },
      );
    }
  }
}
