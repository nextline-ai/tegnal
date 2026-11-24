// Holding a tag in Work Information opens its menu instead of saving it at once,
// as `ArtworkTagMenu` does in native-ios/TEGNAL/Presentation/Content/ReaderSurfaces.swift.

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/content/content_environment.dart';
import 'package:tegnal/presentation/content/gallery_detail_view.dart';

void main() {
  testWidgets('holding a tag offers saving, copying and leaving it out of searches', (tester) async {
    final chosen = <String>[];
    var saved = false;
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.pumpWidget(
      CupertinoApp(
        home: Center(
          child: ArtworkTagPill(
            color: const Color(0xFFFF2D55),
            onTap: () => chosen.add('search'),
            menu: () => artworkTagMenu(
              copy: ContentEnvironment.excludedTagRule('female:big breasts'),
              saved: saved,
              save: () {
                saved = !saved;
                chosen.add('save');
              },
              exclude: () => chosen.add('exclude'),
            ),
            child: const Text('big breasts'),
          ),
        ),
      ),
    );
    final pill = find.byType(ArtworkTagPill);
    await tester.longPress(pill);
    await tester.pumpAndSettle();
    expect(chosen, isEmpty, reason: 'Holding no longer saves the tag by itself');
    expect(find.text('Save Tag'), findsOneWidget);
    expect(find.text('Copy Tag'), findsOneWidget);
    expect(find.text('Add to Default Excluded Tags'), findsOneWidget);
    await tester.tap(find.text('Save Tag'));
    await tester.pumpAndSettle();
    expect(chosen, ['save']);

    await tester.longPress(pill);
    await tester.pumpAndSettle();
    expect(find.text('Remove Saved Tag'), findsOneWidget, reason: 'The menu now offers to remove it');
    await tester.tap(find.text('Copy Tag'));
    await tester.pumpAndSettle();
    expect(copied, 'female:big_breasts', reason: 'A comics tag copies as searches write it');

    await tester.tap(pill);
    await tester.pumpAndSettle();
    expect(chosen, ['save', 'search'], reason: 'A tap still searches');
  });
}
