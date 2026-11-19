// Ported from native-ios/TEGNALUITests/NativeContentUITests.swift (testFavoritesSyncAsksHowToStartFirst).
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/content/keyed_work_extras.dart';
import 'package:tegnal/core/content/site_favorites_sync.dart';
import 'package:tegnal/presentation/settings/site_favorites_setup_sheet.dart';

void main() {
  testWidgets('the first sync shows what bringing favorites in does, and each choice answers', (tester) async {
    tester.view.physicalSize = const Size(1206, 2622);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    late BuildContext context;
    await tester.pumpWidget(
      CupertinoApp(
        home: Builder(
          builder: (built) {
            context = built;
            return const SizedBox.expand();
          },
        ),
      ),
    );
    const offer = SiteFavoritesSetupOffer(
      site: 'keyed.example',
      host: 'keyed.example',
      favorites: AccountFavorites(categories: [], members: {}, exclusive: true),
      favoriteCount: 120,
      newWorks: 35,
      filedWorks: 40,
      newFolders: ['Favorites 0', 'Favorites 3'],
    );
    SiteFavoritesSetupChoice? chosen;
    SiteFavoritesSetupSheet.show(context, offer).then((value) => chosen = value);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('keyed.example has 120 favorites. Choose how they start syncing with your folders.'), findsOneWidget);
    expect(
      find.text(
        "Adds 35 works your library doesn't have. Also puts 40 saved works in folders named after the website's categories. From then on, each category and its folder hold the same works.",
      ),
      findsOneWidget,
    );
    expect(find.text('New folders: Favorites 0, Favorites 3'), findsOneWidget);
    await tester.tap(find.text('Keep My Library As It Is'));
    await tester.pumpAndSettle();
    expect(chosen, SiteFavoritesSetupChoice.keepLibrary);
  });
}
