import 'package:cupertino_ui/cupertino_ui.dart';

import '../../core/booru/booru_account.dart';
import '../../core/content/site_favorites_sync.dart';
import '../../core/support/l10n.dart';
import '../design/app_sheet.dart';
import '../design/grouped_form.dart';
import '../design/tegnal_theme.dart';
import '../home/home_stage.dart';

/// `SiteFavoritesSetupSheet`: asked the first time a signed-in website's favorites can be synced,
/// before anything changes: bring them into the library, keep the library as it is and sync only
/// later changes, or don't sync. Closing it without a choice asks again next time.
class SiteFavoritesSetupSheet extends StatelessWidget {
  const SiteFavoritesSetupSheet({
    super.key,
    required this.host,
    required this.favoriteCount,
    required this.bringInDetail,
    required this.newFolders,
    required this.controller,
  });
  final String host;
  final int favoriteCount;
  final String bringInDetail;
  final List<String> newFolders;
  final ScrollController controller;

  static Future<SiteFavoritesSetupChoice?> _show(BuildContext context, {required String host, required int count, required String detail, required List<String> folders}) =>
      showAppSheet<SiteFavoritesSetupChoice>(
        context,
        builder: (context, controller) =>
            SiteFavoritesSetupSheet(host: host, favoriteCount: count, bringInDetail: detail, newFolders: folders, controller: controller),
      );

  /// A comics website's favorites.
  static Future<SiteFavoritesSetupChoice?> show(BuildContext context, SiteFavoritesSetupOffer offer) {
    final lists = !offer.favorites.exclusive;
    return _show(
      context,
      host: offer.host,
      count: offer.favoriteCount,
      folders: offer.newFolders,
      detail: [
        if (offer.newWorks > 0) L10n.text("Adds %@ works your library doesn't have.", ['${offer.newWorks}']),
        if (offer.filedWorks > 0)
          L10n.text(
            lists ? "Also puts %@ saved works in folders named after the website's lists." : "Also puts %@ saved works in folders named after the website's categories.",
            ['${offer.filedWorks}'],
          ),
        L10n.text(lists ? 'From then on, each list and its folder hold the same works.' : 'From then on, each category and its folder hold the same works.'),
      ].join(' '),
    );
  }

  /// An image server's favorites.
  static Future<SiteFavoritesSetupChoice?> showImages(BuildContext context, BooruFavoritesSetupOffer offer) => _show(
    context,
    host: offer.serverName,
    count: offer.favoriteCount,
    folders: offer.newFolders,
    detail: [
      if (offer.newImages > 0) L10n.text("Adds %@ images your library doesn't have.", ['${offer.newImages}']),
      if (offer.filedImages > 0) L10n.text("Also puts %@ saved images in folders named after the website's favorite groups.", ['${offer.filedImages}']),
      L10n.text('From then on, your favorites and these folders hold the same images.'),
    ].join(' '),
  );

  @override
  Widget build(BuildContext context) {
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    return ScrollEdgeSheet(
      bar: SheetNavigationBar(title: L10n.text('Website Favorites')),
      child: ListView(
        controller: controller,
        padding: EdgeInsets.only(top: 76 + 4, bottom: 32 + MediaQuery.paddingOf(context).bottom),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
            child: Text(
              L10n.text('%@ has %@ favorites. Choose how they start syncing with your folders.', [host, '$favoriteCount']),
              style: TegnalType.style(15, color: secondary),
            ),
          ),
          FormSection(
            footer: newFolders.isEmpty ? null : Text(L10n.text('New folders: %@', [newFolders.join(', ')])),
            children: [_choice(context, SiteFavoritesSetupChoice.bringIn, 'Bring In Favorites', CupertinoIcons.square_arrow_down, bringInDetail)],
          ),
          const SizedBox(height: 24),
          FormSection(
            children: [
              _choice(
                context,
                SiteFavoritesSetupChoice.keepLibrary,
                'Keep My Library As It Is',
                CupertinoIcons.lock,
                L10n.text(
                  "Nothing changes now, in the app or on the website. Favorites already on the website are left alone; only what you add or remove from now on is synced. To bring them in later, turn the sync off and on again in the website's settings.",
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          FormSection(
            children: [
              _choice(
                context,
                SiteFavoritesSetupChoice.off,
                "Don't Sync",
                CupertinoIcons.xmark_circle,
                L10n.text("The app and the website stay apart. You can turn the sync on later in the website's settings."),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _choice(BuildContext context, SiteFavoritesSetupChoice choice, String title, IconData icon, String detail) {
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    return Semantics(
      identifier: 'favoritesSetup.${choice.name}',
      button: true,
      child: FormRow(
        separatorInset: 52,
        onTap: () => Navigator.of(context).pop(choice),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 24,
                child: Icon(icon, size: 20, color: choice == SiteFavoritesSetupChoice.off ? secondary : TegnalColors.tint.resolveFrom(context)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(L10n.text(title), style: TegnalType.style(17, weight: FontWeight.w600, color: TegnalColors.label.resolveFrom(context))),
                    const SizedBox(height: 4),
                    Text(detail, style: TegnalType.style(13, color: secondary)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// `SiteFavoritesSetupGate`: shows [SiteFavoritesSetupSheet] once a website's or image server's
/// favorites wait for an answer, never over the home scene.
class SiteFavoritesSetupGate extends StatefulWidget {
  const SiteFavoritesSetupGate({super.key, required this.sync, required this.images, required this.child});
  final SiteFavoritesSync sync;
  final BooruAccountSync images;
  final Widget child;

  @override
  State<SiteFavoritesSetupGate> createState() => _SiteFavoritesSetupGateState();
}

class _SiteFavoritesSetupGateState extends State<SiteFavoritesSetupGate> {
  bool _asking = false;

  @override
  void initState() {
    super.initState();
    widget.sync.addListener(_check);
    widget.images.addListener(_check);
    widget.images.store.addListener(_check);
    HomeStage.shared.addListener(_check);
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  @override
  void dispose() {
    widget.sync.removeListener(_check);
    widget.images.removeListener(_check);
    widget.images.store.removeListener(_check);
    HomeStage.shared.removeListener(_check);
    super.dispose();
  }

  Future<void> _check() async {
    if (!mounted || _asking || HomeStage.shared.coversScreen) return;
    if (widget.sync.offer case final offer?) {
      _asking = true;
      final choice = await SiteFavoritesSetupSheet.show(context, offer);
      _asking = false;
      await widget.sync.answer(choice);
    } else if (widget.images.setupOffer case final offer? when !widget.images.store.folderStylePending) {
      // An older image library first chooses how its folders work.
      _asking = true;
      final choice = await SiteFavoritesSetupSheet.showImages(context, offer);
      _asking = false;
      await widget.images.answerSetup(choice);
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
