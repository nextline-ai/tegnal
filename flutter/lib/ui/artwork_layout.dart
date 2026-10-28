import '../core/app_controller.dart';
import '../core/content.dart';

/// Shared geometry for saved works and Explore. A zero column preference uses
/// the native automatic layout; explicit values apply consistently to both.
class ArtworkLayout {
  const ArtworkLayout(this.controller, this.mode) : _snapshot = null;
  const ArtworkLayout._(this.controller, this.mode, this._snapshot);

  /// Freeze preferences once for a lazy grid. Building a tile or laying out
  /// another scroll row must not synchronously query SQLite for each property.
  factory ArtworkLayout.snapshot(AppController controller, AppMode mode) =>
      ArtworkLayout._(controller, mode, (
        noPadding: controller.modePreference('removesGridPadding', mode),
        titles:
            mode == AppMode.manga &&
            controller.modePreference('showsMangaTitles', mode, true),
        artists:
            mode == AppMode.manga &&
            controller.modePreference('showsMangaArtists', mode, true),
        fit:
            mode == AppMode.booru &&
            controller.modePreference('fitThumbnails', mode),
        gridColumns: controller.columns('gridColumns', mode),
        folderColumns: controller.columns('folderColumns', mode),
      ));
  final ({
    bool noPadding,
    bool titles,
    bool artists,
    bool fit,
    int gridColumns,
    int folderColumns,
  })?
  _snapshot;
  final AppController controller;
  final AppMode mode;

  bool get removesPadding =>
      _snapshot?.noPadding ??
      controller.modePreference('removesGridPadding', mode);
  bool get showsTitles =>
      mode == AppMode.manga &&
      (_snapshot?.titles ??
          controller.modePreference('showsMangaTitles', mode, true));
  bool get showsArtists =>
      mode == AppMode.manga &&
      (_snapshot?.artists ??
          controller.modePreference('showsMangaArtists', mode, true));
  bool get fitsThumbnails =>
      mode == AppMode.booru &&
      (_snapshot?.fit ?? controller.modePreference('fitThumbnails', mode));
  double get margin => removesPadding ? 0 : 12;
  double get spacing => removesPadding
      ? 0
      : mode == AppMode.booru
      ? 10
      : 18;
  double get radius => removesPadding ? 0 : 12;
  double get aspectRatio => mode == AppMode.booru
      ? .78
      : showsTitles || showsArtists
      ? .61
      : .72;

  int columns(double width, {bool folders = false}) {
    final requested =
        (folders ? _snapshot?.folderColumns : _snapshot?.gridColumns) ??
        controller.columns(folders ? 'folderColumns' : 'gridColumns', mode);
    if (requested > 0) return requested;
    final fullWidth =
        width +
        (removesPadding
            ? 0
            : folders
            ? 32
            : margin * 2);
    final minimum = folders && fullWidth >= 840 ? 240.0 : 160.0;
    return ((fullWidth - (removesPadding ? 0 : 32) + 14) / (minimum + 14))
        .floor()
        .clamp(1, 5);
  }
}
