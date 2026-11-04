import 'dart:async';
import 'dart:ui' as ui;

import 'package:cupertino_ui/cupertino_ui.dart';

import '../../core/content/content_environment.dart';
import '../../core/storage/app_database.dart';
import '../../core/storage/folder_rules.dart';
import '../../domain/models.dart';
import '../content/content_routes.dart';
import '../design/app_sheet.dart';
import '../design/tegnal_theme.dart';
import '../navigation/app_state.dart';
import '../navigation/root_tab_view.dart';
import '../works/artwork_grid.dart';
import 'add_work_sheet.dart';
import 'folder_color_sheet.dart';
import 'folder_order_view.dart';
import 'folder_rule_editor.dart';
import 'works_grid_view.dart';

/// Where the comics library leads: its folders, saved works, sheets and works.
/// Screens reload when [changes] fires, the stand-in for GRDB's value observation.
class LibraryRoutes {
  LibraryRoutes({required this.state, required this.database, required this.content, required this.contentRoutes, this.startCoverQueue});

  final AppState state;
  final AppDatabase database;
  final ContentEnvironment content;
  final ContentRoutes contentRoutes;

  /// Fills covers and information of newly saved works in the background.
  final void Function()? startCoverQueue;

  final changes = LibraryChanges();

  void notifyChanged() => changes.notify();

  ArtworkGridPreferences get folderGrid => ArtworkGridPreferences(columns: content.mangaFolderColumns, removesPadding: content.mangaRemovesGridPadding);

  ArtworkGridPreferences get worksGrid => ArtworkGridPreferences(
    columns: content.mangaColumns,
    removesPadding: content.mangaRemovesGridPadding,
    showsTitles: content.showsMangaTitles,
    showsArtists: content.showsMangaArtists,
    showsCategories: content.showsMangaCategories,
  );

  void openFolder(BuildContext context, Folder folder) => Navigator.of(context).push(
    CupertinoPageRoute<void>(
      builder: (_) => WorksGridView(routes: this, folder: folder),
    ),
  );

  void openSearch(BuildContext context, String query) => Navigator.of(context).push(
    CupertinoPageRoute<void>(
      builder: (_) => WorksGridView(routes: this, search: query),
    ),
  );

  /// A saved work opens like a thumbnail anywhere else: the reader, or its information first.
  void openWork(BuildContext context, int galleryID) => contentRoutes.openThumbnail(context, galleryID);

  void openDetails(BuildContext context, int galleryID) => contentRoutes.openGallery(context, galleryID);

  /// A saved tag or search opens its comics feed.
  void openQuery(BuildContext context, String query) => contentRoutes.search(context, query);

  Future<void> addWork(BuildContext context, {String initialText = ''}) async {
    await showAppSheet<void>(
      context,
      builder: (context, controller) => AddWorkSheet(routes: this, initialText: initialText, scrollController: controller),
    );
    notifyChanged();
  }

  Future<void> changeColor(BuildContext context, Folder folder) async {
    await showAppSheet<void>(
      context,
      grabber: true,
      builder: (context, controller) => FolderColorSheet(
        title: folder.displayName,
        color: folder.color,
        onSelected: (color) {
          final id = folder.id;
          if (id == null) return;
          database.setFolderColor(id, color);
          notifyChanged();
        },
      ),
    );
    notifyChanged();
  }

  Future<void> reorderFolders(BuildContext context) async {
    await showAppSheet<void>(
      context,
      builder: (context, controller) => FolderOrderView<int>(
        folders: [
          for (final folder in database.listFolders())
            if (folder.id != null) (id: folder.id!, name: folder.displayName),
        ],
        save: database.reorderFolders,
      ),
    );
    notifyChanged();
  }

  Future<void> editSmartFolder(BuildContext context, Folder folder) async {
    final id = folder.id;
    if (id == null) return;
    final identity = database.identityOfFolder(id);
    await showAppSheet<void>(
      context,
      builder: (context, controller) => FolderRuleEditor.existing(library: database, folder: identity, scrollController: controller),
    );
    notifyChanged();
  }

  Future<void> composeSmartFolder(BuildContext context, {String name = '', String tag = '', bool smart = true}) async {
    await showAppSheet<void>(
      context,
      builder: (context, controller) => FolderRuleEditor.create(library: database, name: name, tag: tag, smart: smart, scrollController: controller),
    );
    notifyChanged();
  }

  /// `transientMessage`: a short capsule notice at the bottom of the screen.
  /// Inside a tab the notice sits above the floating tab bar, as the tab's safe area places it.
  void showMessage(BuildContext context, String message) => showTransientMessage(context, message, bottom: tabBarClearance(context) + 8);
}

/// Fires after the library is written, so open screens read it again.
class LibraryChanges extends ChangeNotifier {
  void notify() => notifyListeners();
}

OverlayEntry? _message;
Timer? _messageTimer;

void showTransientMessage(BuildContext context, String message, {double? bottom}) {
  _messageTimer?.cancel();
  _message?.remove();
  final entry = OverlayEntry(
    builder: (context) {
      final media = MediaQuery.of(context);
      return Positioned(
        left: 16,
        right: 16,
        bottom: bottom ?? 24 + media.padding.bottom.clamp(34, double.infinity),
        child: IgnorePointer(
          child: Center(
            child: ClipPath(
              clipper: const ShapeBorderClipper(shape: StadiumBorder()),
              child: BackdropFilter(
                filter: ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  color: CupertinoTheme.brightnessOf(context) == Brightness.dark ? const Color(0xB32C2C2E) : const Color(0xCCF2F2F7),
                  child: Text(
                    message,
                    style: TegnalType.style(15, weight: FontWeight.w700, color: TegnalColors.label.resolveFrom(context)),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
  _message = entry;
  Overlay.of(context, rootOverlay: true).insert(entry);
  _messageTimer = Timer(const Duration(seconds: 2), () {
    if (_message == entry) {
      entry.remove();
      _message = null;
    }
  });
}
