import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import '../../core/booru/booru_models.dart';
import '../../core/booru/booru_browser.dart';
import '../../core/support/l10n.dart';
import '../content/gallery_preview_models.dart';
import '../content/gallery_detail_view.dart' show GlassIconButton, artworkTagColor;
import '../design/context_menu.dart';
import '../design/grouped_form.dart';
import '../design/ios_controls.dart';
import '../design/tegnal_theme.dart';
import '../library/folders_view.dart' show anchorOf;
import 'booru_common.dart';
import 'booru_feed_view.dart';
import 'booru_post_view.dart' show openExternalLink;

/// `BooruPostView.details`: the post's facts, its tags by category, pools, notes and content
/// controls. Tags and pools open their feeds inside the sheet.
class BooruPostDetails extends StatelessWidget {
  const BooruPostDetails({
    super.key,
    required this.booru,
    required this.post,
    required this.server,
    required this.notes,
    required this.notesError,
    required this.original,
    required this.onOriginal,
    required this.onResolved,
    required this.onRetryNotes,
    required this.onHidden,
    this.scrollController,
  });

  final BooruContext booru;
  final BooruPost post;
  final BooruServer server;
  final List<BooruNote> notes;
  final String? notesError;
  final bool original;
  final ValueChanged<bool> onOriginal;
  final ValueChanged<BooruPost> onResolved;
  final VoidCallback onRetryNotes;

  /// A hidden post or blocked artist closes the details and the viewer.
  final VoidCallback onHidden;
  final ScrollController? scrollController;

  @override
  Widget build(BuildContext context) {
    final sheet = Navigator.of(context);
    return Navigator(
      onGenerateRoute: (_) => CupertinoPageRoute<void>(
        builder: (context) => _DetailsPage(details: this, done: () => sheet.pop()),
      ),
    );
  }
}

class _DetailsPage extends StatefulWidget {
  const _DetailsPage({required this.details, required this.done});
  final BooruPostDetails details;
  final VoidCallback done;

  @override
  State<_DetailsPage> createState() => _DetailsPageState();
}

class _DetailsPageState extends State<_DetailsPage> {
  late BooruPost _post = widget.details.post;
  late bool _original = widget.details.original;
  String? _notice;

  BooruPostDetails get _details => widget.details;
  BooruContext get _booru => _details.booru;
  BooruServer get _server => _details.server;

  @override
  void initState() {
    super.initState();
    _booru.store.addListener(_changed);
    _resolveCategories();
  }

  @override
  void dispose() {
    _booru.store.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  /// Older engines list tags without categories; the post page has them.
  Future<void> _resolveCategories() async {
    if (!_server.engine.usesGelbooruPages || _post.tagCategories != null) return;
    try {
      final resolved = await _booru.source.details(_server, _post);
      if (!mounted) return;
      setState(() => _post = resolved);
      _details.onResolved(resolved);
    } on Object catch (error) {
      if (mounted) _show(BooruConnectionMessage.describe(error));
    }
  }

  void _show(String message) {
    setState(() => _notice = message);
    Future<void>.delayed(const Duration(seconds: 2), () {
      if (mounted && _notice == message) setState(() => _notice = null);
    });
  }

  void _saveTag(String tag, String kind) {
    final store = _booru.store;
    final saved = !store.savedTags(_server.id, kind: kind).contains(tag);
    try {
      store.toggleTag(tag, serverID: _server.id, kind: kind);
      HapticFeedback.mediumImpact();
      _show(L10n.text(saved ? 'Saved to Tags' : 'Removed from Tags'));
    } on Object catch (error) {
      _show('$error');
    }
  }

  void _hide(String rule) {
    final store = _booru.store;
    final old = store.blacklist(_server.id);
    store.setBlacklist(old.isEmpty ? rule : '$old\n$rule', serverID: _server.id);
    _details.onHidden();
  }

  void _openFeed({String query = '', BooruPool? pool}) => Navigator.of(context).push(
    CupertinoPageRoute<void>(
      builder: (context) => BooruFeedView(booru: _booru, servers: [_server], initialQuery: query, pool: pool, onBack: () => Navigator.of(context).pop()),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    final tint = TegnalColors.tint.resolveFrom(context);
    final groups = ArtworkTagGroup.make(tags: _post.tags, artists: _post.artists, categories: _post.tagCategories ?? const {});
    final row = FormColors.row.resolveFrom(context);
    Widget value(String title, String value) => FormRow(
      child: Row(
        children: [
          Text(title),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: TegnalType.style(17, color: secondary),
            ),
          ),
        ],
      ),
    );
    return Stack(
      children: [
        ScrollEdgeSheet(
          bar: SheetNavigationBar(
            title: L10n.text('Details'),
            trailing: GlassTextButton(label: L10n.text('Done'), prominent: true, onPressed: widget.done),
          ),
          child: ListView(
            controller: _details.scrollController,
            // An inset-grouped list without a first header starts 35 pt under the bar's band.
            padding: EdgeInsets.only(top: 69 + 35, bottom: 32 + MediaQuery.paddingOf(context).bottom),
            children: [
              FormSection(
                rowColor: row,
                children: [
                  FormRow(
                    child: Row(
                      children: [
                        const Text('ID'),
                        const Spacer(),
                        Text('${_post.postID}', style: TegnalType.style(17, color: secondary)),
                        const SizedBox(width: 8),
                        Semantics(
                          button: true,
                          label: L10n.text('Copy ID'),
                          child: GestureDetector(
                            onTap: () {
                              Clipboard.setData(ClipboardData(text: '${_post.postID}'));
                              HapticFeedback.selectionClick();
                            },
                            child: Icon(CupertinoIcons.doc_on_doc, size: 20, color: tint),
                          ),
                        ),
                      ],
                    ),
                  ),
                  value(L10n.text('Server'), _server.displayName),
                  value(L10n.text('Resolution'), '${_post.width} × ${_post.height}'),
                  value(L10n.text('Format'), _post.fileExtension.toUpperCase()),
                  value(L10n.text('Score'), '${_post.score}'),
                  if (!_post.isVideo && !_post.isAnimated)
                    FormRow(
                      child: Row(
                        children: [
                          Expanded(child: Text(L10n.text('Original Image'))),
                          TegnalSwitch(
                            value: _original,
                            onChanged: (value) {
                              setState(() => _original = value);
                              _details.onOriginal(value);
                            },
                          ),
                        ],
                      ),
                    ),
                  FormRow(
                    onTap: () => openExternalLink(_server.pageURL(_post.postID)),
                    child: Text(L10n.text('Open on Website'), style: TegnalType.style(17, color: tint)),
                  ),
                ],
              ),
              for (final group in groups) ...[
                const SizedBox(height: 28),
                FormSection(
                  rowColor: row,
                  prominentHeader: true,
                  header: _TagHeading(category: group.category),
                  children: [for (final tag in group.tags) _tagRow(context, tag, group.category)],
                ),
              ],
              if (_post.poolIDs.isNotEmpty) ...[
                const SizedBox(height: 28),
                FormSection(
                  rowColor: row,
                  header: Text(L10n.text('Pools')),
                  children: [
                    for (final id in _post.poolIDs)
                      FormRow(
                        onTap: () => _openFeed(
                          pool: BooruPool(id: id, name: 'Pool #$id', count: 0),
                        ),
                        child: Row(
                          children: [
                            Expanded(child: Text('Pool #$id')),
                            Icon(CupertinoIcons.chevron_right, size: 14, color: TegnalColors.tertiaryLabel.resolveFrom(context)),
                          ],
                        ),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 28),
              FormSection(
                rowColor: row,
                header: Text(L10n.text('Notes')),
                children: [
                  if (_details.notesError case final error?) ...[
                    FormRow(
                      child: Text(error, style: TegnalType.style(17, color: secondary)),
                    ),
                    FormRow(
                      onTap: _details.onRetryNotes,
                      child: Text(L10n.text('Try Again'), style: TegnalType.style(17, color: tint)),
                    ),
                  ] else if (_details.notes.isEmpty)
                    FormRow(
                      child: Text(L10n.text('No Notes'), style: TegnalType.style(17, color: secondary)),
                    ),
                  for (final (index, note) in _details.notes.indexed)
                    FormRow(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('#${index + 1}', style: TegnalType.style(12, color: secondary)),
                          const SizedBox(height: 6),
                          Text(note.body, style: TegnalType.style(17, color: TegnalColors.label.resolveFrom(context))),
                        ],
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 28),
              FormSection(
                rowColor: row,
                header: Text(L10n.text('Content Controls')),
                children: [
                  FormRow(
                    onTap: () =>
                        Navigator.of(context).push(CupertinoPageRoute<void>(builder: (context) => _ContentReportPage(page: _server.pageURL(_post.postID)))),
                    child: Row(
                      children: [
                        Icon(CupertinoIcons.flag, size: 22, color: tint),
                        const SizedBox(width: 12),
                        Expanded(child: Text(L10n.text('Report Content'))),
                        Icon(CupertinoIcons.chevron_right, size: 14, color: TegnalColors.tertiaryLabel.resolveFrom(context)),
                      ],
                    ),
                  ),
                  FormRow(
                    onTap: () => _hide('id:${_post.postID}'),
                    child: Row(
                      children: [
                        Icon(CupertinoIcons.eye_slash, size: 22, color: tint),
                        const SizedBox(width: 12),
                        Text(L10n.text('Hide This Post'), style: TegnalType.style(17, color: tint)),
                      ],
                    ),
                  ),
                  if (_post.artists.isNotEmpty)
                    Builder(
                      builder: (rowContext) => FormRow(
                        onTap: () => showActionMenu(
                          rowContext,
                          anchor: anchorOf(rowContext),
                          actions: [for (final artist in _post.artists) ContextMenuAction(title: artist, onSelected: () => _hide('artist:$artist'))],
                        ),
                        child: Row(
                          children: [
                            Icon(CupertinoIcons.person_crop_circle_badge_xmark, size: 22, color: tint),
                            const SizedBox(width: 12),
                            Text(L10n.text('Block Artist'), style: TegnalType.style(17, color: tint)),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
        if (_notice != null)
          Positioned(
            left: 16,
            right: 16,
            bottom: 32 + MediaQuery.paddingOf(context).bottom,
            child: IgnorePointer(
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: ShapeDecoration(color: TegnalColors.elevatedGlassFill.resolveFrom(context), shape: const StadiumBorder()),
                  child: Text(
                    _notice!,
                    style: TegnalType.style(15, weight: FontWeight.w600, color: TegnalColors.label.resolveFrom(context)),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _tagRow(BuildContext context, ArtworkTag tag, ArtworkTagCategory category) {
    final color = artworkTagColor(category, context);
    final kind = category.savedKind.rawValue;
    final saved = _booru.store.savedTags(_server.id, kind: kind).contains(tag.query);
    return Semantics(
      button: true,
      customSemanticsActions: {CustomSemanticsAction(label: L10n.text('Save Tag')): () => _saveTag(tag.query, kind)},
      child: FormRow(
        onTap: () => _openFeed(query: tag.query),
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onLongPress: () => _saveTag(tag.query, kind),
          child: Row(
            children: [
              Expanded(
                child: Text(tag.name, style: TegnalType.style(17, color: color)),
              ),
              Icon(CupertinoIcons.chevron_right, size: 14, color: TegnalColors.tertiaryLabel.resolveFrom(context)),
              const SizedBox(width: 10),
              Builder(
                builder: (buttonContext) => GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => showActionMenu(
                    buttonContext,
                    anchor: anchorOf(buttonContext),
                    actions: [
                      ContextMenuAction(
                        title: L10n.text(saved ? 'Remove Saved Tag' : 'Save Tag'),
                        icon: CupertinoIcons.tag,
                        onSelected: () => _saveTag(tag.query, kind),
                      ),
                      ContextMenuAction(title: L10n.text('Save Artist'), icon: CupertinoIcons.person, onSelected: () => _saveTag(tag.query, 'artist')),
                      ContextMenuAction(title: L10n.text('Blacklist Tag'), icon: CupertinoIcons.eye_slash, onSelected: () => _hide(tag.query)),
                    ],
                  ),
                  child: SizedBox(
                    width: 28,
                    height: 28,
                    child: Icon(saved ? CupertinoIcons.star_fill : CupertinoIcons.ellipsis_circle, size: 22, color: color),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// `ArtworkTagHeading`: the category's symbol and title in its color.
class _TagHeading extends StatelessWidget {
  const _TagHeading({required this.category});
  final ArtworkTagCategory category;

  static IconData _icon(ArtworkTagCategory category) => switch (category) {
    ArtworkTagCategory.artist => CupertinoIcons.paintbrush,
    ArtworkTagCategory.series => CupertinoIcons.book,
    ArtworkTagCategory.character => CupertinoIcons.person_crop_square,
    ArtworkTagCategory.female || ArtworkTagCategory.male => CupertinoIcons.person_crop_rectangle,
    ArtworkTagCategory.group => CupertinoIcons.person_2,
    ArtworkTagCategory.language => CupertinoIcons.globe,
    ArtworkTagCategory.type => CupertinoIcons.square_stack,
    ArtworkTagCategory.metadata => CupertinoIcons.info_circle,
    ArtworkTagCategory.general => CupertinoIcons.tag,
  };

  @override
  Widget build(BuildContext context) {
    final color = artworkTagColor(category, context);
    return Row(
      children: [
        Icon(_icon(category), size: 20, color: color),
        const SizedBox(width: 8),
        Text(L10n.text(category.title), style: TextStyle(color: color)),
      ],
    );
  }
}

/// `ContentReportView`: a prepared email and the website link for reporting a post.
class _ContentReportPage extends StatelessWidget {
  const _ContentReportPage({required this.page});
  final String page;

  @override
  Widget build(BuildContext context) {
    final tint = TegnalColors.tint.resolveFrom(context);
    final row = FormColors.row.resolveFrom(context);
    return ScrollEdgeSheet(
      bar: SheetNavigationBar(
        title: L10n.text('Report Content'),
        leading: GlassIconButton(icon: CupertinoIcons.chevron_left, label: L10n.text('Back'), onPressed: () => Navigator.of(context).pop()),
      ),
      child: ListView(
        padding: EdgeInsets.only(top: 76 + 4, bottom: 32 + MediaQuery.paddingOf(context).bottom),
        children: [
          FormSection(
            rowColor: row,
            footer: Text(
              L10n.text('NextLine can investigate app behavior. The source website controls its posts; use its reporting tools to request removal there.'),
            ),
            children: [
              FormRow(
                child: Text(
                  L10n.text(
                    'Include what is wrong with this content. Your mail app opens a draft containing the page address; nothing is sent until you send it.',
                  ),
                ),
              ),
              FormRow(
                onTap: () => openExternalLink(
                  Uri(scheme: 'mailto', path: 'contact@nextline.work', queryParameters: {'subject': 'TEGNAL — Content report', 'body': '$page\n\n'}).toString(),
                ),
                child: Text(L10n.text('Report by Email'), style: TegnalType.style(17, color: tint)),
              ),
              FormRow(
                onTap: () => openExternalLink(page),
                child: Text(L10n.text('Open on Website'), style: TegnalType.style(17, color: tint)),
              ),
              FormRow(
                child: Text(page, style: TegnalType.style(13, color: TegnalColors.label.resolveFrom(context))),
              ),
            ],
          ),
          const SizedBox(height: 26),
          FormSection(
            rowColor: row,
            children: [
              FormRow(
                child: Text('contact@nextline.work', style: TegnalType.style(17, color: TegnalColors.label.resolveFrom(context))),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A note's text. Translation into the viewer's language arrives with its own rebuild step.
class BooruNoteView extends StatelessWidget {
  const BooruNoteView({super.key, required this.note, this.scrollController});
  final BooruNote note;
  final ScrollController? scrollController;

  @override
  Widget build(BuildContext context) => ScrollEdgeSheet(
    bar: SheetNavigationBar(
      title: L10n.text('Notes'),
      trailing: GlassTextButton(label: L10n.text('Done'), prominent: true, onPressed: () => Navigator.of(context).pop()),
    ),
    child: ListView(
      controller: scrollController,
      padding: EdgeInsets.fromLTRB(24, 76 + 24, 24, 24 + MediaQuery.paddingOf(context).bottom),
      children: [Text(note.body, style: TegnalType.style(17, color: TegnalColors.label.resolveFrom(context)))],
    ),
  );
}
