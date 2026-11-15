import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/services.dart';

import '../../core/content/content_environment.dart';
import '../../core/content/content_errors.dart';
import '../../core/content/gallery_content.dart';
import '../../core/content/keyed_work_extras.dart';
import '../../core/support/l10n.dart';
import '../design/alert_dialog.dart';
import '../design/app_sheet.dart';
import '../design/grouped_form.dart';
import '../design/pull_down_menu.dart';
import '../design/tegnal_theme.dart';
import '../library/folders_view.dart' show ContentUnavailable;

const _borderedFill = CupertinoDynamicColor.withBrightness(color: Color(0x1F787880), darkColor: Color(0xFF39393D));

String _shortDate(DateTime date, {bool time = false}) {
  final local = date.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  final day = '${local.year}-${two(local.month)}-${two(local.day)}';
  return time ? '$day ${two(local.hour)}:${two(local.minute)}' : day;
}

String _count(int value) {
  final digits = '$value';
  final buffer = StringBuffer();
  for (var index = 0; index < digits.length; index++) {
    if (index > 0 && (digits.length - index) % 3 == 0) buffer.write(',');
    buffer.write(digits[index]);
  }
  return buffer.toString();
}

/// `WorkExtrasSection`: rating, how often a work is kept, who uploaded it, comments and torrents,
/// on websites that keep them. Nothing shows for websites that don't.
class WorkExtrasSection extends StatefulWidget {
  const WorkExtrasSection({super.key, required this.galleryID, required this.source, required this.content});
  final int galleryID;
  final ContentProviding source;
  final ContentEnvironment content;

  /// The uploader's note first, then the best-scored comments.
  static List<WorkComment> preview(List<WorkComment> comments) {
    final note = comments.where((comment) => comment.isUploader);
    final others = comments.where((comment) => !comment.isUploader).toList()..sort((a, b) => (b.score ?? 0).compareTo(a.score ?? 0));
    return [...note, ...others].take(2).toList();
  }

  @override
  State<WorkExtrasSection> createState() => _WorkExtrasSectionState();
}

class _WorkExtrasSectionState extends State<WorkExtrasSection> {
  WorkExtras? _extras;
  bool _rating = false;

  WorkExtrasProviding? get _provider => widget.source is WorkExtrasProviding ? widget.source as WorkExtrasProviding : null;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(WorkExtrasSection old) {
    super.didUpdateWidget(old);
    if (old.galleryID != widget.galleryID) {
      _extras = null;
      _load();
    }
  }

  Future<void> _load() async {
    final provider = _provider;
    if (provider == null) return;
    try {
      final extras = await provider.extras(widget.galleryID);
      if (mounted) setState(() => _extras = extras);
    } on Object {
      // The rest of the page stays usable without what only the website's own page says.
    }
  }

  Future<void> _rate(BuildContext anchor) async {
    final provider = _provider;
    if (provider == null) return;
    final halfStars = await showPullDownMenu<int>(
      anchor,
      anchor: anchorRectOf(anchor),
      items: [
        for (var value = 10; value >= 1; value--)
          PullDownMenuItem(value: value, title: '${'★' * (value ~/ 2)}${value.isOdd ? '½' : ''} ${(value / 2).toStringAsFixed(1)}'),
      ],
    );
    if (halfStars == null || !mounted) return;
    setState(() => _rating = true);
    try {
      final (average, count) = await provider.rate(widget.galleryID, halfStars);
      if (!mounted) return;
      setState(() {
        _extras?.rating = average;
        _extras?.ratingCount = count;
      });
    } on Object catch (error) {
      if (!mounted) return;
      await showCupertinoDialog<void>(
        context: context,
        builder: (context) => TegnalAlertDialog(
          title: Text(L10n.text('Unable to Rate')),
          content: Text(ContentError.message(error)),
          actions: [CupertinoDialogAction(isDefaultAction: true, onPressed: () => Navigator.pop(context), child: Text(L10n.text('OK')))],
        ),
      );
    } finally {
      if (mounted) setState(() => _rating = false);
    }
  }

  Widget _stat(BuildContext context, String text, IconData icon, {Color? tint}) {
    final color = tint ?? TegnalColors.secondaryLabel.resolveFrom(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: ShapeDecoration(color: TegnalColors.secondaryLabel.resolveFrom(context).withValues(alpha: 0.1), shape: const StadiumBorder()),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TegnalType.style(13, color: color),
            ),
          ),
        ],
      ),
    );
  }

  Widget _wideButton(BuildContext context, String label, IconData icon, VoidCallback onPressed) {
    final tint = TegnalColors.tint.resolveFrom(context);
    return CupertinoButton(
      padding: EdgeInsets.zero,
      onPressed: onPressed,
      child: Container(
        height: 44,
        decoration: ShapeDecoration(color: _borderedFill.resolveFrom(context), shape: const StadiumBorder()),
        alignment: Alignment.center,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: tint),
            const SizedBox(width: 6),
            Text(
              label,
              style: TegnalType.style(15, weight: FontWeight.w600, color: tint),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final extras = _extras;
    if (extras == null || !extras.hasContent) return const SizedBox.shrink();
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    final label = TegnalColors.label.resolveFrom(context);
    final canRate = extras.canRate && widget.content.siteAccountSignedIn;
    final rating = extras.rating;
    final ratingRow = Row(
      children: [
        WorkRatingStars(rating: rating ?? 0),
        const SizedBox(width: 8),
        Text(
          rating == null ? L10n.text('Not Rated Yet') : rating.toStringAsFixed(2),
          style: TegnalType.style(15, weight: rating == null ? FontWeight.w400 : FontWeight.w600, color: rating == null ? secondary : label),
        ),
        if (extras.ratingCount case final count?) ...[
          const SizedBox(width: 8),
          Text(L10n.text('%@ ratings', [_count(count)]), style: TegnalType.style(15, color: secondary)),
        ],
        if (_rating) ...[const SizedBox(width: 8), const CupertinoActivityIndicator(radius: 8)],
        const Spacer(),
        if (canRate) Icon(CupertinoIcons.chevron_up_chevron_down, size: 13, color: secondary),
      ],
    );
    return Padding(
      padding: const EdgeInsets.only(top: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(height: 0.5, color: TegnalColors.separator.resolveFrom(context)),
          const SizedBox(height: 14),
          if (canRate)
            Builder(
              builder: (anchor) => Semantics(
                button: true,
                label: L10n.text('Rate This Work'),
                child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: () => _rate(anchor), child: ratingRow),
              ),
            )
          else
            ratingRow,
          const SizedBox(height: 14),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              if (extras.favorited case final favorited?) _stat(context, L10n.text('%@ favorites', [_count(favorited)]), CupertinoIcons.heart),
              if (extras.favoriteName case final name? when extras.favoriteCategory != null)
                _stat(context, name, CupertinoIcons.heart_fill, tint: CupertinoColors.systemPink.resolveFrom(context)),
              if (extras.fileSize case final size?) _stat(context, size, CupertinoIcons.archivebox),
              if (extras.posted case final posted?) _stat(context, _shortDate(posted), CupertinoIcons.calendar),
              if (extras.uploader case final uploader?) _stat(context, uploader, CupertinoIcons.person),
            ],
          ),
          if (extras.comments.isNotEmpty) ...[
            const SizedBox(height: 14),
            Text(
              L10n.text('Comments'),
              style: TegnalType.style(17, weight: FontWeight.w600, color: label),
            ),
            const SizedBox(height: 8),
            for (final comment in WorkExtrasSection.preview(extras.comments)) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: ShapeDecoration(
                  color: TegnalColors.secondaryLabel.resolveFrom(context).withValues(alpha: 0.08),
                  shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(14)),
                ),
                child: WorkCommentRow(comment: comment, maxLines: 4),
              ),
              const SizedBox(height: 8),
            ],
            _wideButton(
              context,
              L10n.text('All Comments'),
              CupertinoIcons.text_bubble,
              () => showAppSheet<void>(
                context,
                builder: (context, controller) =>
                    WorkCommentsPage(galleryID: widget.galleryID, initial: extras.comments, loadsAll: extras.hasMoreComments, provider: _provider),
              ),
            ),
          ],
          if (extras.torrentCount > 0) ...[
            const SizedBox(height: 8),
            _wideButton(
              context,
              L10n.text('Torrents (%@)', ['${extras.torrentCount}']),
              CupertinoIcons.arrow_down_doc,
              () => showAppSheet<void>(
                context,
                builder: (context, controller) => WorkTorrentsPage(galleryID: widget.galleryID, provider: _provider),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class WorkRatingStars extends StatelessWidget {
  const WorkRatingStars({super.key, required this.rating});
  final double rating;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var index = 0; index < 5; index++)
          Icon(
            rating - index >= 0.75
                ? CupertinoIcons.star_fill
                : rating - index >= 0.25
                ? CupertinoIcons.star_lefthalf_fill
                : CupertinoIcons.star,
            size: 15,
            color: CupertinoColors.systemOrange.resolveFrom(context),
          ),
      ],
    ),
  );
}

class WorkCommentRow extends StatelessWidget {
  const WorkCommentRow({super.key, required this.comment, this.maxLines});
  final WorkComment comment;
  final int? maxLines;

  @override
  Widget build(BuildContext context) {
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    final score = comment.score;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Flexible(
              child: Text(
                comment.author,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TegnalType.style(15, weight: FontWeight.w600, color: TegnalColors.label.resolveFrom(context)),
              ),
            ),
            if (comment.isUploader) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: ShapeDecoration(color: TegnalColors.tint.resolveFrom(context).withValues(alpha: 0.15), shape: const StadiumBorder()),
                child: Text(
                  L10n.text('Uploader'),
                  style: TegnalType.style(11, weight: FontWeight.w600, color: TegnalColors.tint.resolveFrom(context)),
                ),
              ),
            ],
            const Spacer(),
            if (score != null)
              Text(
                score > 0 ? '+$score' : '$score',
                style: TegnalType.style(
                  12,
                  weight: FontWeight.w600,
                  color: score > 0
                      ? CupertinoColors.systemGreen.resolveFrom(context)
                      : score < 0
                      ? CupertinoColors.systemRed.resolveFrom(context)
                      : secondary,
                ),
              ),
          ],
        ),
        if (comment.posted case final posted?) ...[
          const SizedBox(height: 4),
          Text(_shortDate(posted, time: true), style: TegnalType.style(12, color: secondary)),
        ],
        const SizedBox(height: 6),
        Text(
          comment.text,
          maxLines: maxLines,
          overflow: maxLines == null ? null : TextOverflow.ellipsis,
          style: TegnalType.style(15, color: TegnalColors.label.resolveFrom(context)),
        ),
      ],
    );
  }
}

/// `WorkCommentsView`: every comment under a work.
class WorkCommentsPage extends StatefulWidget {
  const WorkCommentsPage({super.key, required this.galleryID, required this.initial, required this.loadsAll, required this.provider});
  final int galleryID;
  final List<WorkComment> initial;
  final bool loadsAll;
  final WorkExtrasProviding? provider;

  @override
  State<WorkCommentsPage> createState() => _WorkCommentsPageState();
}

class _WorkCommentsPageState extends State<WorkCommentsPage> {
  List<WorkComment>? _comments;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final provider = widget.provider;
    if (!widget.loadsAll || provider == null) {
      setState(() => _comments = widget.initial);
      return;
    }
    try {
      final comments = await provider.allComments(widget.galleryID);
      if (mounted) setState(() => _comments = comments);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        if (widget.initial.isEmpty) {
          _error = ContentError.message(error);
        } else {
          _comments = widget.initial;
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final comments = _comments;
    final Widget body;
    if (comments != null) {
      body = comments.isEmpty
          ? Center(
              child: ContentUnavailable(icon: CupertinoIcons.text_bubble, title: L10n.text('No Comments')),
            )
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
              itemCount: comments.length,
              separatorBuilder: (context, index) =>
                  Container(height: 0.5, margin: const EdgeInsets.symmetric(vertical: 12), color: TegnalColors.separator.resolveFrom(context)),
              itemBuilder: (context, index) => WorkCommentRow(comment: comments[index]),
            );
    } else if (_error != null) {
      body = Center(
        child: ContentUnavailable(icon: CupertinoIcons.wifi_exclamationmark, title: L10n.text('Unable to Load'), description: _error),
      );
    } else {
      body = const Center(child: CupertinoActivityIndicator());
    }
    return ColoredBox(
      color: TegnalColors.background.resolveFrom(context),
      child: Column(
        children: [
          SheetNavigationBar(
            title: L10n.text('Comments'),
            trailing: GlassTextButton(label: L10n.text('Done'), prominent: true, onPressed: () => Navigator.of(context).pop()),
          ),
          Expanded(child: body),
        ],
      ),
    );
  }
}

/// `WorkTorrentsView`: the torrents a website offers for a work.
class WorkTorrentsPage extends StatefulWidget {
  const WorkTorrentsPage({super.key, required this.galleryID, required this.provider});
  final int galleryID;
  final WorkExtrasProviding? provider;

  @override
  State<WorkTorrentsPage> createState() => _WorkTorrentsPageState();
}

class _WorkTorrentsPageState extends State<WorkTorrentsPage> {
  static const _screen = MethodChannel('work.nextline.tegnal/screen');
  List<WorkTorrent>? _torrents;
  String? _error;
  String? _copied;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final provider = widget.provider;
    if (provider == null) {
      setState(() => _torrents = const []);
      return;
    }
    try {
      final torrents = await provider.torrents(widget.galleryID);
      if (mounted) setState(() => _torrents = torrents);
    } on Object catch (error) {
      if (mounted) setState(() => _error = ContentError.message(error));
    }
  }

  String _details(WorkTorrent torrent) => [
    ?torrent.size,
    if (torrent.seeds case final seeds?) L10n.text('Seeds %@', ['$seeds']),
    if (torrent.peers case final peers?) L10n.text('Peers %@', ['$peers']),
    if (torrent.downloads case final downloads?) L10n.text('Downloads %@', ['$downloads']),
    ?torrent.posted,
  ].join(' · ');

  Widget _smallButton(BuildContext context, String label, IconData icon, VoidCallback onPressed) {
    final tint = TegnalColors.tint.resolveFrom(context);
    return CupertinoButton(
      padding: EdgeInsets.zero,
      minimumSize: const Size(0, 32),
      onPressed: onPressed,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: ShapeDecoration(color: _borderedFill.resolveFrom(context), shape: const StadiumBorder()),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: tint),
            const SizedBox(width: 4),
            Text(label, style: TegnalType.style(13, color: tint)),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final torrents = _torrents;
    final Widget body;
    if (torrents != null) {
      body = torrents.isEmpty
          ? Center(
              child: ContentUnavailable(icon: CupertinoIcons.arrow_down_doc, title: L10n.text('No Torrents')),
            )
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
              itemCount: torrents.length,
              separatorBuilder: (context, index) =>
                  Container(height: 0.5, margin: const EdgeInsets.symmetric(vertical: 12), color: TegnalColors.separator.resolveFrom(context)),
              itemBuilder: (context, index) {
                final torrent = torrents[index];
                final magnet = torrent.magnet;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      torrent.name,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TegnalType.style(15, weight: FontWeight.w600, color: TegnalColors.label.resolveFrom(context)),
                    ),
                    const SizedBox(height: 4),
                    Text(_details(torrent), style: TegnalType.style(12, color: TegnalColors.secondaryLabel.resolveFrom(context))),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        if (magnet != null) ...[
                          _smallButton(context, L10n.text('Copy Magnet Link'), CupertinoIcons.link, () {
                            Clipboard.setData(ClipboardData(text: magnet.toString()));
                            setState(() => _copied = torrent.url.toString());
                          }),
                          const SizedBox(width: 10),
                        ],
                        _smallButton(
                          context,
                          L10n.text('Share'),
                          CupertinoIcons.share,
                          () => _screen.invokeMethod<void>('share', {'text': torrent.url.toString()}),
                        ),
                      ],
                    ),
                    if (_copied == torrent.url.toString()) ...[
                      const SizedBox(height: 4),
                      Text(L10n.text('Copied'), style: TegnalType.style(11, color: CupertinoColors.systemGreen.resolveFrom(context))),
                    ],
                  ],
                );
              },
            );
    } else if (_error != null) {
      body = Center(
        child: ContentUnavailable(icon: CupertinoIcons.wifi_exclamationmark, title: L10n.text('Unable to Load'), description: _error),
      );
    } else {
      body = const Center(child: CupertinoActivityIndicator());
    }
    return ColoredBox(
      color: TegnalColors.background.resolveFrom(context),
      child: Column(
        children: [
          SheetNavigationBar(
            title: L10n.text('Torrents'),
            trailing: GlassTextButton(label: L10n.text('Done'), prominent: true, onPressed: () => Navigator.of(context).pop()),
          ),
          Expanded(child: body),
        ],
      ),
    );
  }
}
