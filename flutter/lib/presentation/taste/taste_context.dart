import 'package:cupertino_ui/cupertino_ui.dart';

import '../../core/taste/taste_controller.dart';
import '../../core/taste/taste_models.dart';
import '../booru/booru_common.dart';
import '../content/content_routes.dart';
import '../content/page_image_store.dart';
import '../navigation/app_state.dart';

/// What the Smart tab, recaps, challenges and imports share, created once with the root.
class TasteContext {
  TasteContext({required this.controller, required this.booru, required this.comics, required this.images, required this.explore});

  final TasteController controller;

  /// Image mode's store, sources, caches and preferences.
  final BooruContext booru;

  /// Opens comics works, searches and bookmarks.
  final ContentRoutes comics;

  /// Comics cover and page images.
  final PageImageStore images;

  /// Switches to the current library's Explore tab.
  final VoidCallback explore;

  AppState get state => booru.state;

  /// The library the person is browsing now.
  TasteMode get mode => state.mode == AppMode.booru ? TasteMode.booru : TasteMode.comics;
}
