import 'dart:math' as math;

import 'package:cupertino_ui/cupertino_ui.dart';

import '../../core/content/gallery_content.dart';
import '../../core/support/l10n.dart';
import '../design/tegnal_theme.dart';

/// `ArtworkCellStyle`: everything scales with the cell against a 160 pt reference.
class ArtworkCellStyle {
  const ArtworkCellStyle({
    this.width = 160,
    this.removesPadding = false,
    this.showsTitle = true,
    this.showsArtists = true,
    this.showsCategory = false,
    this.columns = 1,
  });

  final double width;
  final bool removesPadding;
  final bool showsTitle;
  final bool showsArtists;
  final bool showsCategory;
  final int columns;

  double get scale => math.min(1, math.max(0.2, width / 160));
  double inset(double value) => removesPadding ? 0 : value * scale;
  double radius(double value) => inset(value);
  double fontSize(double value, {double minimum = 8}) => math.max(minimum, value * scale);
}

/// `ArtworkGridGeometry`: column count, cell width, gaps and margins solved together.
class ArtworkGridGeometry {
  factory ArtworkGridGeometry({required double width, required int columns, double minimum = 160, required bool removesPadding, int maximumColumns = 5}) {
    final available = math.max(1.0, width);
    final count = columns == 0
        ? math.max(1, ((available - (removesPadding ? 0 : 32) + 14) / (minimum + 14)).floor())
        : math.min(math.max(1, maximumColumns), math.max(1, columns));
    final gaps = (count - 1).toDouble();
    final proposed = (available - 32 - gaps * 14) / count;
    final cellWidth = removesPadding
        ? available / count
        : proposed >= 160
        ? proposed
        : available / (count + (32 + gaps * 14) / 160);
    final scale = math.min(1.0, cellWidth / 160);
    return ArtworkGridGeometry._(count, cellWidth, removesPadding ? 0 : 14 * scale, removesPadding ? 0 : 16 * scale);
  }

  const ArtworkGridGeometry._(this.count, this.cellWidth, this.spacing, this.margin);
  final int count;
  final double cellWidth;
  final double spacing;
  final double margin;
}

/// Grid preferences that live in Settings; the defaults match a fresh native install.
class ArtworkGridPreferences {
  const ArtworkGridPreferences({
    this.columns = 0,
    this.removesPadding = false,
    this.showsTitles = true,
    this.showsArtists = true,
    this.showsCategories = false,
  });
  final int columns;
  final bool removesPadding;
  final bool showsTitles;
  final bool showsArtists;
  final bool showsCategories;
}

/// Online, saved, recommended and downloaded artwork share the same density.
/// Returns sliver content so it can sit inside a feed's scroll view.
class ArtworkGridSliver extends StatelessWidget {
  const ArtworkGridSliver({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.preferences = const ArtworkGridPreferences(),
    this.topMarginScale = 1,
  });

  final int itemCount;
  final Widget Function(BuildContext context, int index, ArtworkCellStyle style) itemBuilder;
  final ArtworkGridPreferences preferences;
  final double topMarginScale;

  @override
  Widget build(BuildContext context) {
    return SliverLayoutBuilder(
      builder: (context, constraints) {
        final textScale = MediaQuery.textScalerOf(context).scale(1);
        final geometry = ArtworkGridGeometry(
          width: constraints.crossAxisExtent,
          columns: textScale >= 1.35 ? 1 : preferences.columns,
          removesPadding: preferences.removesPadding,
        );
        final style = ArtworkCellStyle(
          width: geometry.cellWidth,
          removesPadding: preferences.removesPadding,
          showsTitle: preferences.showsTitles,
          showsArtists: preferences.showsArtists,
          showsCategory: preferences.showsCategories,
          columns: geometry.count,
        );
        final rows = (itemCount / geometry.count).ceil();
        return SliverPadding(
          padding: EdgeInsets.fromLTRB(geometry.margin, geometry.margin * topMarginScale, geometry.margin, geometry.margin),
          sliver: SliverList.separated(
            itemCount: rows,
            separatorBuilder: (_, _) => SizedBox(height: geometry.spacing),
            itemBuilder: (context, row) => Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var column = 0; column < geometry.count; column++) ...[
                  if (column > 0) SizedBox(width: geometry.spacing),
                  Expanded(
                    child: row * geometry.count + column < itemCount ? itemBuilder(context, row * geometry.count + column, style) : const SizedBox.shrink(),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Shared cover ratio, language badge and typography for local and remote galleries.
class GalleryCardLayout extends StatelessWidget {
  const GalleryCardLayout({
    super.key,
    required this.style,
    required this.title,
    required this.artists,
    required this.language,
    required this.cover,
    this.category = '',
    this.categoryColor,
    this.pages,
    this.showsLanguage = true,
  });

  final ArtworkCellStyle style;
  final String title;
  final String artists;
  final String language;
  final String category;
  final Color? categoryColor;

  /// Shown before the language, as “13 | korean”.
  final int? pages;
  final bool showsLanguage;
  final Widget cover;

  @override
  Widget build(BuildContext context) {
    final textScale = MediaQuery.textScalerOf(context);
    final radius = style.radius(12);
    return Semantics(
      container: true,
      label: [title, artists, category, _pageText, language].where((part) => part.isNotEmpty).join(' · '),
      excludeSemantics: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRSuperellipse(
            borderRadius: BorderRadius.circular(radius),
            child: AspectRatio(
              aspectRatio: 0.72,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  cover,
                  if (showsLanguage) Positioned(left: style.inset(6), right: style.inset(6), bottom: style.inset(6), child: _badges(context)),
                ],
              ),
            ),
          ),
          if (style.showsTitle || style.showsArtists && artists.isNotEmpty) ...[
            SizedBox(height: style.inset(6)),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: style.inset(2)),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (style.showsTitle)
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TegnalType.style(
                        style.fontSize(textScale.scale(15), minimum: 10),
                        weight: FontWeight.w500,
                        color: TegnalColors.label.resolveFrom(context),
                      ).copyWith(height: 1.2),
                      textScaler: TextScaler.noScaling,
                    ),
                  if (style.showsTitle && style.showsArtists && artists.isNotEmpty) SizedBox(height: style.inset(2)),
                  if (style.showsArtists && artists.isNotEmpty)
                    Text(
                      artists,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TegnalType.style(style.fontSize(textScale.scale(12), minimum: 9), color: TegnalColors.secondaryLabel.resolveFrom(context)),
                      textScaler: TextScaler.noScaling,
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _badges(BuildContext context) {
    final showsCategory = style.showsCategory && category.isNotEmpty;
    return Row(
      children: [
        if (showsCategory)
          Flexible(
            child: _badge(context, category, background: categoryColor, foreground: const Color(0xFFFFFFFF)),
          ),
        const Spacer(),
        if (_pageCount != null || language.isNotEmpty) _badge(context, language, material: true, pages: _pageCount),
      ],
    );
  }

  int? get _pageCount => pages != null && pages! > 0 ? pages : null;
  String get _pageText => _pageCount == null ? '' : L10n.text('%@ pages', ['$_pageCount']);

  Widget _badge(BuildContext context, String text, {Color? background, Color? foreground, bool material = false, int? pages}) {
    final textStyle = TegnalType.style(
      style.fontSize(MediaQuery.textScalerOf(context).scale(11)),
      weight: FontWeight.w700,
      color: foreground ?? TegnalColors.label.resolveFrom(context),
    );
    Widget words(String value) => Text(value, maxLines: 1, overflow: TextOverflow.clip, softWrap: false, style: textStyle, textScaler: TextScaler.noScaling);
    // The page count and the language share one badge, split by a thin line.
    final label = pages == null
        ? words(text)
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              words('$pages'),
              if (text.isNotEmpty) ...[
                SizedBox(width: style.inset(4)),
                Container(width: 1, height: (textStyle.fontSize ?? 11) * 0.85, color: TegnalColors.label.resolveFrom(context).withValues(alpha: 0.55)),
                SizedBox(width: style.inset(4)),
                words(text),
              ],
            ],
          );
    final padded = Padding(
      padding: EdgeInsets.symmetric(horizontal: style.inset(6), vertical: style.inset(2)),
      child: label,
    );
    if (!material) {
      return DecoratedBox(
        decoration: ShapeDecoration(color: background, shape: const StadiumBorder()),
        child: padded,
      );
    }
    // `.ultraThinMaterial`: a light frosted capsule over the cover.
    return ClipPath(
      clipper: const ShapeBorderClipper(shape: StadiumBorder()),
      child: DecoratedBox(
        decoration: ShapeDecoration(
          color: CupertinoTheme.brightnessOf(context) == Brightness.dark ? const Color(0x99606060) : const Color(0x33FFFFFF),
          shape: const StadiumBorder(),
        ),
        child: padded,
      ),
    );
  }
}

/// `GalleryCategory.color`: distinct hues let a grid be scanned by category at a glance.
Color galleryCategoryColor(String type) => switch (GalleryCategory.key(type)) {
  'doujinshi' => const Color.from(alpha: 1, red: 0.80, green: 0.24, blue: 0.24),
  'manga' => const Color.from(alpha: 1, red: 0.86, green: 0.45, blue: 0.10),
  'artistcg' => const Color.from(alpha: 1, red: 0.72, green: 0.56, blue: 0.04),
  'gamecg' => const Color.from(alpha: 1, red: 0.20, green: 0.58, blue: 0.30),
  'imageset' => const Color.from(alpha: 1, red: 0.30, green: 0.36, blue: 0.80),
  'anime' => const Color.from(alpha: 1, red: 0.08, green: 0.56, blue: 0.62),
  'western' => const Color.from(alpha: 1, red: 0.45, green: 0.58, blue: 0.10),
  'non-h' => const Color.from(alpha: 1, red: 0.16, green: 0.46, blue: 0.82),
  'cosplay' => const Color.from(alpha: 1, red: 0.56, green: 0.30, blue: 0.76),
  'photo' => const Color.from(alpha: 1, red: 0.80, green: 0.30, blue: 0.56),
  _ => const Color.from(alpha: 1, red: 0.42, green: 0.42, blue: 0.42),
};
