import 'dart:io';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/content/content_environment.dart';
import '../../core/content/content_errors.dart';
import '../../core/content/gallery_content.dart';
import '../../core/content/keyed_catalog_source.dart';
import '../../core/content/keyed_work_extras.dart';
import '../../core/content/content_transport.dart';
import '../../core/support/document_files.dart';
import '../../core/support/l10n.dart';
import '../design/alert_dialog.dart';
import '../design/app_sheet.dart';
import '../design/grouped_form.dart';
import '../design/pull_down_menu.dart';
import '../design/tegnal_theme.dart';
import 'gallery_preview_models.dart';
import '../library/folders_view.dart' show ContentUnavailable;
import '../../core/support/privacy_settings.dart';

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

/// `WorkExtrasSection`: rating, how often a work is kept, who uploaded it and comments, on
/// websites that keep them, with the account's actions in a box of rows. Nothing shows for
/// websites that don't.
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

  /// A box with the page's other boxes' corners and fill.
  Widget _box(BuildContext context, List<Widget> rows) => ClipRSuperellipse(
    borderRadius: BorderRadius.circular(galleryBoxRadius),
    child: ColoredBox(
      color: FormColors.row.resolveFrom(context),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows),
    ),
  );

  Widget _separator(BuildContext context, {double leading = galleryTextInset}) => Padding(
    padding: EdgeInsets.only(left: leading, right: galleryTextInset),
    child: Container(height: 0.5, color: TegnalColors.separator.resolveFrom(context)),
  );

  /// One of the account's actions: an icon in its column and the title after it, a list row's height.
  Widget _actionRow(BuildContext context, String label, IconData icon, VoidCallback onPressed) {
    final tint = TegnalColors.tint.resolveFrom(context);
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: galleryRowHeight),
          child: Row(
            children: [
              SizedBox(
                width: galleryIconColumn,
                child: Icon(icon, size: 22, color: tint),
              ),
              Expanded(
                child: Text(label, style: TegnalType.style(17, color: tint)),
              ),
              const SizedBox(width: galleryTextInset),
            ],
          ),
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
    final provider = _provider;
    final actions = <Widget>[
      if (extras.comments.isNotEmpty)
        _actionRow(
          context,
          L10n.text('All Comments'),
          CupertinoIcons.text_bubble,
          () => showAppSheet<void>(
            context,
            builder: (context, controller) =>
                WorkCommentsPage(galleryID: widget.galleryID, initial: extras.comments, loadsAll: extras.hasMoreComments, provider: provider),
          ),
        ),
      if (extras.canComment && provider != null)
        _actionRow(
          context,
          L10n.text('Write Comment'),
          CupertinoIcons.square_pencil,
          () => showAppSheet<void>(
            context,
            builder: (context, controller) => WorkCommentComposerPage(
              galleryID: widget.galleryID,
              provider: provider,
              posted: (comments) => setState(() {
                _extras?.comments = comments;
                _extras?.hasMoreComments = false;
              }),
            ),
          ),
        ),
      // The page hands its rating key, and so its votes and archives, only to a signed-in account.
      if (extras.canRate && extras.tagVotes.isNotEmpty && provider != null)
        _actionRow(
          context,
          L10n.text('Vote on Tags'),
          CupertinoIcons.hand_thumbsup,
          () => showAppSheet<void>(
            context,
            builder: (context, controller) => WorkTagVotesPage(
              galleryID: widget.galleryID,
              votes: extras.tagVotes,
              provider: provider,
              changed: (votes) => setState(() => _extras?.tagVotes = votes),
            ),
          ),
        ),
      if (extras.canRate && extras.archiveURL != null && provider != null)
        _actionRow(
          context,
          L10n.text('Archive Download'),
          CupertinoIcons.archivebox,
          () => showAppSheet<void>(
            context,
            builder: (context, controller) => WorkArchivePage(galleryID: widget.galleryID, provider: provider),
          ),
        ),
    ];
    final previews = WorkExtrasSection.preview(extras.comments);
    return Padding(
      padding: const EdgeInsets.only(top: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(height: 0.5, color: TegnalColors.separator.resolveFrom(context)),
          const SizedBox(height: 14),
          // The rating line sits a little inside the rounded stats under it; the stats keep the margin.
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: galleryLabelInset),
            child: canRate
                ? Builder(
                    builder: (anchor) => Semantics(
                      button: true,
                      label: L10n.text('Rate This Work'),
                      child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: () => _rate(anchor), child: ratingRow),
                    ),
                  )
                : ratingRow,
          ),
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
            ],
          ),
          if (previews.isNotEmpty) ...[
            const SizedBox(height: 14),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: galleryTextInset),
              child: Text(
                L10n.text('Comments'),
                style: TegnalType.style(17, weight: FontWeight.w600, color: label),
              ),
            ),
            const SizedBox(height: 8),
            // One box, its corners the same as every other box on the page.
            _box(context, [
              for (final (index, comment) in previews.indexed) ...[
                if (index > 0) _separator(context),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: galleryTextInset, vertical: 12),
                  child: WorkCommentRow(comment: comment, maxLines: 4),
                ),
              ],
            ]),
          ],
          if (actions.isNotEmpty) ...[
            const SizedBox(height: 14),
            _box(context, [
              for (final (index, row) in actions.indexed) ...[if (index > 0) _separator(context, leading: galleryIconColumn), row],
            ]),
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

String _failure(Object error) => error is SiteMessage ? error.text : ContentError.message(error);

Future<void> _alert(BuildContext context, String title, String message) => showCupertinoDialog<void>(
  context: context,
  builder: (context) => TegnalAlertDialog(
    title: Text(title),
    content: Text(message),
    actions: [CupertinoDialogAction(isDefaultAction: true, onPressed: () => Navigator.pop(context), child: Text(L10n.text('OK')))],
  ),
);

/// `WorkTagVotesView`: the work's tags with the account's votes. A vote decides, with everyone
/// else's, which tags the work keeps on the website; voting against the account's own vote withdraws it.
class WorkTagVotesPage extends StatefulWidget {
  const WorkTagVotesPage({super.key, required this.galleryID, required this.votes, required this.provider, required this.changed});
  final int galleryID;
  final List<WorkTagVote> votes;
  final WorkExtrasProviding provider;
  final ValueChanged<List<WorkTagVote>> changed;

  @override
  State<WorkTagVotesPage> createState() => _WorkTagVotesPageState();
}

class _WorkTagVotesPageState extends State<WorkTagVotesPage> {
  late List<WorkTagVote> _votes = widget.votes;
  String? _voting;

  Future<void> _vote(WorkTagVote tag) async {
    final choice = await showCupertinoModalPopup<int>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: Text(tag.name),
        actions: [
          if (tag.vote == 0) ...[
            CupertinoActionSheetAction(onPressed: () => Navigator.pop(context, 1), child: Text(L10n.text('Vote Up'))),
            CupertinoActionSheetAction(onPressed: () => Navigator.pop(context, -1), child: Text(L10n.text('Vote Down'))),
          ] else
            CupertinoActionSheetAction(onPressed: () => Navigator.pop(context, -tag.vote), child: Text(L10n.text('Withdraw Vote'))),
        ],
        cancelButton: CupertinoActionSheetAction(onPressed: () => Navigator.pop(context), child: Text(L10n.text('Cancel'))),
      ),
    );
    if (choice == null || !mounted) return;
    setState(() => _voting = tag.tag);
    try {
      final votes = await widget.provider.voteTag(widget.galleryID, tag: tag.tag, vote: choice);
      widget.changed(votes);
      if (mounted) setState(() => _votes = votes);
    } on Object catch (error) {
      if (mounted) await _alert(context, L10n.text('Unable to Vote'), _failure(error));
    }
    if (mounted) setState(() => _voting = null);
  }

  @override
  Widget build(BuildContext context) {
    final row = FormColors.listRow.resolveFrom(context);
    final namespaces = <String>[];
    for (final tag in _votes) {
      if (!namespaces.contains(tag.localNamespace)) namespaces.add(tag.localNamespace);
    }
    return ColoredBox(
      color: FormColors.background.resolveFrom(context),
      child: Column(
        children: [
          SheetNavigationBar(
            title: L10n.text('Vote on Tags'),
            trailing: GlassTextButton(label: L10n.text('Done'), prominent: true, onPressed: () => Navigator.of(context).pop()),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(top: 8, bottom: 32),
              children: [
                for (final namespace in namespaces) ...[
                  FormSection(
                    rowColor: row,
                    header: Text(namespace.isEmpty ? L10n.text('Tags') : namespace),
                    children: [
                      for (final tag in _votes.where((tag) => tag.localNamespace == namespace))
                        FormRow(
                          onTap: _voting == null ? () => _vote(tag) : null,
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(tag.name, style: TegnalType.style(17, color: TegnalColors.label.resolveFrom(context))),
                              ),
                              if (_voting == tag.tag)
                                const CupertinoActivityIndicator()
                              else if (tag.vote > 0)
                                Semantics(
                                  label: L10n.text('Voted Up'),
                                  child: Icon(CupertinoIcons.hand_thumbsup_fill, size: 20, color: CupertinoColors.systemGreen.resolveFrom(context)),
                                )
                              else if (tag.vote < 0)
                                Semantics(
                                  label: L10n.text('Voted Down'),
                                  child: Icon(CupertinoIcons.hand_thumbsdown_fill, size: 20, color: CupertinoColors.systemRed.resolveFrom(context)),
                                ),
                            ],
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 28),
                ],
                FormSection(
                  rowColor: row,
                  footer: Text(L10n.text('Votes decide, with everyone else’s, which tags the work keeps on the website.')),
                  children: const [],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// `WorkCommentComposer`: writes a comment under the work, posted on the website under the signed-in account.
class WorkCommentComposerPage extends StatefulWidget {
  const WorkCommentComposerPage({super.key, required this.galleryID, required this.provider, required this.posted});
  final int galleryID;
  final WorkExtrasProviding provider;
  final ValueChanged<List<WorkComment>> posted;

  @override
  State<WorkCommentComposerPage> createState() => _WorkCommentComposerPageState();
}

class _WorkCommentComposerPageState extends State<WorkCommentComposerPage> {
  final _text = TextEditingController();
  bool _posting = false;

  @override
  void initState() {
    super.initState();
    _text.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _post() async {
    setState(() => _posting = true);
    try {
      final comments = await widget.provider.postComment(widget.galleryID, _text.text);
      widget.posted(comments);
      if (mounted) Navigator.of(context).pop();
      return;
    } on Object catch (error) {
      if (mounted) await _alert(context, L10n.text('Unable to Post'), _failure(error));
    }
    if (mounted) setState(() => _posting = false);
  }

  @override
  Widget build(BuildContext context) {
    final row = FormColors.listRow.resolveFrom(context);
    return ColoredBox(
      color: FormColors.background.resolveFrom(context),
      child: Column(
        children: [
          SheetNavigationBar(
            title: L10n.text('Write Comment'),
            leading: GlassTextButton(label: L10n.text('Cancel'), onPressed: _posting ? null : () => Navigator.of(context).pop()),
            trailing: _posting
                ? const CupertinoActivityIndicator()
                : GlassTextButton(label: L10n.text('Post'), prominent: true, onPressed: _text.text.trim().isEmpty ? null : _post),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(top: 8, bottom: 32),
              children: [
                FormSection(
                  rowColor: row,
                  footer: Text(L10n.text('Your comment is posted on the website under your account, where everyone can read it.')),
                  children: [
                    FormRow(
                      child: CupertinoTextField.borderless(
                        controller: _text,
                        padding: EdgeInsets.zero,
                        minLines: 8,
                        maxLines: 16,
                        style: TegnalType.style(17, color: TegnalColors.label.resolveFrom(context)),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// `WorkArchiveView`: the work's archives as the website offers them, with what each costs the
/// account, and a download of the one chosen, saved wherever the person picks.
class WorkArchivePage extends StatefulWidget {
  const WorkArchivePage({super.key, required this.galleryID, required this.provider});
  final int galleryID;
  final WorkExtrasProviding provider;

  @override
  State<WorkArchivePage> createState() => _WorkArchivePageState();
}

class _WorkArchivePageState extends State<WorkArchivePage> {
  WorkArchiveOffer? _offer;
  String? _error;
  bool _downloading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final offer = await widget.provider.archiveOffer(widget.galleryID);
      if (mounted) setState(() => _offer = offer);
    } on Object catch (error) {
      if (mounted) setState(() => _error = _failure(error));
    }
  }

  Future<void> _download(WorkArchiveOption option) async {
    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => TegnalAlertDialog(
        title: Text(L10n.text('Download This Archive?')),
        content: Text(L10n.text('It costs %@.', [option.cost])),
        actions: [
          CupertinoDialogAction(onPressed: () => Navigator.pop(context, false), child: Text(L10n.text('Cancel'))),
          CupertinoDialogAction(isDefaultAction: true, onPressed: () => Navigator.pop(context, true), child: Text(L10n.text('Download'))),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _downloading = true);
    try {
      final address = await widget.provider.archiveDownloadURL(widget.galleryID, option);
      final file = await ArchiveFile.download(address, name: '${widget.galleryID}-${option.kind}');
      await const DocumentFiles().createDocument(name: file.uri.pathSegments.last, source: file, mimeType: 'application/zip');
    } on Object catch (error) {
      if (mounted) await _alert(context, L10n.text('Unable to Download'), _failure(error));
    }
    if (mounted) setState(() => _downloading = false);
  }

  @override
  Widget build(BuildContext context) {
    final row = FormColors.listRow.resolveFrom(context);
    final offer = _offer;
    final Widget body;
    if (offer != null) {
      body = ListView(
        padding: const EdgeInsets.only(top: 8, bottom: 32),
        children: [
          if (offer.funds case final funds?) ...[
            FormSection(
              rowColor: row,
              children: [SettingsValueRowLite(title: L10n.text('Account Balance'), value: funds)],
            ),
            const SizedBox(height: 28),
          ],
          FormSection(
            rowColor: row,
            footer: Text(L10n.text('The website takes the cost shown from your account when it prepares the archive. Save the file where you like.')),
            children: [
              for (final option in offer.options)
                FormRow(
                  onTap: option.available && !_downloading ? () => _download(option) : null,
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              L10n.text(option.isOriginal ? 'Original Archive' : 'Resampled Archive'),
                              style: TegnalType.style(17, color: (option.available ? TegnalColors.label : TegnalColors.tertiaryLabel).resolveFrom(context)),
                            ),
                            Text(option.size, style: TegnalType.style(13, color: TegnalColors.secondaryLabel.resolveFrom(context))),
                          ],
                        ),
                      ),
                      Text(option.cost, style: TegnalType.style(17, color: TegnalColors.secondaryLabel.resolveFrom(context))),
                    ],
                  ),
                ),
            ],
          ),
          if (_downloading) ...[
            const SizedBox(height: 28),
            FormSection(
              rowColor: row,
              children: [
                FormRow(
                  child: Row(
                    children: [
                      const CupertinoActivityIndicator(),
                      const SizedBox(width: 12),
                      Text(L10n.text('Preparing Archive…'), style: TegnalType.style(17, color: TegnalColors.label.resolveFrom(context))),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ],
      );
    } else if (_error != null) {
      body = Center(
        child: ContentUnavailable(icon: CupertinoIcons.archivebox, title: L10n.text('Unable to Load'), description: _error),
      );
    } else {
      body = const Center(child: CupertinoActivityIndicator());
    }
    return ColoredBox(
      color: FormColors.background.resolveFrom(context),
      child: Column(
        children: [
          SheetNavigationBar(
            title: L10n.text('Archive Download'),
            trailing: GlassTextButton(label: L10n.text('Done'), prominent: true, onPressed: _downloading ? null : () => Navigator.of(context).pop()),
          ),
          Expanded(child: body),
        ],
      ),
    );
  }
}

/// A plain title and value row, as Settings shows one.
class SettingsValueRowLite extends StatelessWidget {
  const SettingsValueRowLite({super.key, required this.title, required this.value});
  final String title;
  final String value;

  @override
  Widget build(BuildContext context) => FormRow(
    child: Row(
      children: [
        Expanded(
          child: Text(title, style: TegnalType.style(17, color: TegnalColors.label.resolveFrom(context))),
        ),
        Text(value, style: TegnalType.style(17, color: TegnalColors.secondaryLabel.resolveFrom(context))),
      ],
    ),
  );
}

/// An archive the website prepared, downloaded to a file the person can save.
abstract final class ArchiveFile {
  static Future<File> download(Uri url, {required String name}) async {
    if (url.scheme != 'https' || !KeyedCatalogSource.safeMediaURL(url)) throw ContentError.unsupportedFormat;
    final client = HttpClient()..userAgent = ContentTransport.userAgent;
    NetworkPrivacy.configure(client);
    try {
      final request = await client.getUrl(url);
      final response = await request.close();
      if (response.statusCode < 200 || response.statusCode >= 300) throw ContentError.unavailable(response.statusCode);
      final folder = Directory('${(await getTemporaryDirectory()).path}/archives');
      await folder.create(recursive: true);
      final disposition = response.headers.value('content-disposition') ?? '';
      final suggested = RegExp(r'filename="?([^";]+\.zip)"?', caseSensitive: false).firstMatch(disposition)?.group(1);
      final file = File('${folder.path}/${(suggested ?? '$name.zip').replaceAll('/', '_')}');
      await response.pipe(file.openWrite());
      return file;
    } finally {
      client.close();
    }
  }
}
