import 'package:cupertino_ui/cupertino_ui.dart';

import '../../core/content/content_environment.dart';
import '../../core/content/gallery_content.dart';
import '../../core/content/manga_urls.dart';
import '../../core/storage/app_database.dart';
import '../../core/support/preferences.dart';
import '../../core/taste/taste_models.dart';
import '../browser/in_app_manga_browser_view.dart';
import '../navigation/app_state.dart';
import '../navigation/root_tab_view.dart';
import 'content_bookmark.dart';
import '../design/app_sheet.dart';
import '../settings/downloads_view.dart';
import 'explore_view.dart';
import 'gallery_detail_view.dart';
import 'page_image_store.dart';
import 'reader_models.dart';
import 'reader_view.dart';
import 'work_save_feedback.dart';

/// Where works open from Explore, details and the reader: `NativeContentView.navigate`.
class ContentRoutes {
  ContentRoutes({
    required this.state,
    required this.content,
    required this.database,
    required this.images,
    required this.preferences,
    required this.bookmarks,
    this.downloads,
  });

  final AppState state;
  final ContentEnvironment content;
  final AppDatabase database;
  final PageImageStore images;
  final Preferences preferences;
  final BookmarkSession bookmarks;

  /// Where the reader's Download Work queues a work.
  final DownloadsContext? downloads;

  ContentProviding get source => content.source;

  /// A thumbnail opens the reader, or work information first when that is chosen.
  void openThumbnail(BuildContext context, int id) {
    final opening = MangaThumbnailOpening.stored(preferences);
    // `ContentEntryView`: the embedded browser opens the work's page on the website instead.
    if (content.useEmbeddedBrowser && content.isSiteVerified) {
      openInAppMangaBrowser(context, opening.url(id), sheet: opening == MangaThumbnailOpening.information);
      return;
    }
    if (opening == MangaThumbnailOpening.information) {
      openGallery(context, id);
    } else {
      read(context, id, page: 1);
    }
  }

  void openGallery(BuildContext context, int id) {
    if (content.useEmbeddedBrowser && content.isSiteVerified) {
      openInAppMangaBrowser(context, MangaUrls.galleryUrl(id), sheet: true);
      return;
    }
    _showGallery(context, id);
  }

  void _showGallery(BuildContext context, int id) => showGalleryDetail(
    context,
    galleryID: id,
    source: source,
    images: images,
    content: content,
    database: database,
    actions: (sheetContext) => GalleryDetailActions(
      read: (page, {required resume}) => read(sheetContext, id, page: page + 1, resumesProgress: resume),
      save: (gallery) async => showWorkSaveFeedback(
        sheetContext,
        WorkSaveFeedback.perform(
          () => ContentBookmarkAction.save(id, gallery: gallery, session: bookmarks, images: images, context: DiscoveryContext.unknown),
          galleryID: id,
        ),
        session: bookmarks,
      ),
      search: (text) {
        Navigator.of(sheetContext).pop();
        search(context, text);
      },
      openVersion: (version) {
        Navigator.of(sheetContext).pop();
        openGallery(context, version);
      },
      openRelated: (related) {
        Navigator.of(sheetContext).pop();
        openThumbnail(context, related);
      },
    ),
  );

  /// [queue] opens a work from Up Next; any reader can move on to the works waiting there.
  void read(BuildContext context, int id, {required int page, bool resumesProgress = true, bool queue = false}) => openReader(
    context,
    galleryID: id,
    initialPage: page,
    source: source,
    images: images,
    content: content,
    database: database,
    preferences: preferences,
    resumesProgress: resumesProgress,
    // The open work, which changes when the reader moves on through Up Next.
    bookmark: (gallery) async => toggleBookmark(context, gallery.id, gallery),
    search: (text) => search(context, text),
    download: downloads == null
        ? null
        : (readerContext, gallery) {
            downloads!.store.enqueue(gallery);
            _showDownloads(readerContext);
          },
  );

  void _showDownloads(BuildContext context) =>
      showAppSheet<void>(context, builder: (context, controller) => DownloadsView(downloads: downloads!, inSheet: true));

  void toggleBookmark(BuildContext context, int id, NativeGallery? gallery, {bool aboveTabBar = false}) => showWorkSaveFeedback(
    context,
    WorkSaveFeedback.perform(
      () => ContentBookmarkAction.toggle(id, gallery: gallery, session: bookmarks, images: images),
      galleryID: id,
    ),
    session: bookmarks,
    bottom: aboveTabBar ? tabBarClearance(context) + 8 : null,
  );

  /// A tag, artist or search opens its own feed on top of Explore.
  void search(BuildContext context, String text) => Navigator.of(context).push(
    CupertinoPageRoute<void>(
      builder: (context) => ExploreView(
        state: state,
        source: source,
        images: images,
        database: database,
        content: content,
        initialQuery: text,
        onBack: () => Navigator.of(context).pop(),
        openGallery: (id) => openThumbnail(context, id),
        bookmark: (id, gallery) => toggleBookmark(context, id, gallery, aboveTabBar: true),
      ),
    ),
  );
}
