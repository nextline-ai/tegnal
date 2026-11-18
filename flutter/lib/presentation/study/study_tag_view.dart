import 'dart:async';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';

import '../../core/booru/booru_models.dart';
import '../../core/study/study_dtext.dart';
import '../../core/study/study_engine.dart';
import '../../core/study/study_models.dart';
import '../../core/study/study_session.dart';
import '../../core/support/l10n.dart';
import '../../core/taste/taste_models.dart';
import '../booru/booru_common.dart';
import '../booru/booru_feed_view.dart';
import '../booru/booru_post_view.dart';
import '../design/grouped_form.dart';
import '../design/tegnal_theme.dart';
import '../generation/generator_view.dart';
import '../library/library_routes.dart' show showTransientMessage;
import '../settings/settings_rows.dart';
import 'study_quiz_view.dart';
import 'study_widgets.dart';

/// Everything about one tag: what it means, what it looks like, what it is mixed up with and what the server says.
/// It works for any tag; a tag the curriculum does not teach shows what the server knows.
class StudyTagView extends StatefulWidget {
  const StudyTagView({super.key, required this.booru, required this.name});
  final BooruContext booru;
  final String name;

  @override
  State<StudyTagView> createState() => _StudyTagViewState();
}

class _StudyTagViewState extends State<StudyTagView> {
  final _board = StudyBoard();
  StudyTagInfo? _info;
  List<BooruPost> _examples = [];
  bool _loading = true;
  bool _copied = false;
  bool _showsWholePage = false;
  Timer? _copiedTimer;
  int _generation = 0;
  String _servers = '';

  BooruContext get _booru => widget.booru;
  String get _name => widget.name;
  StudyTag? get _tag => _board.curriculum.tag(_name);
  String get _words => StudyPrompt.words(_name);

  /// Saved tags belong to a server; with several chosen, the first is the one the button reads and changes.
  bool get _saved {
    final server = _booru.store.selectedServers.firstOrNull;
    return server != null && _booru.store.savedTags(server.id).contains(_name);
  }

  @override
  void initState() {
    super.initState();
    _board.reload(_booru.store);
    _board.addListener(_changed);
    _servers = _booru.store.selectedServerIDs.join(',');
    _booru.store.addListener(_storeChanged);
    _load();
  }

  @override
  void dispose() {
    _copiedTimer?.cancel();
    _booru.store.removeListener(_storeChanged);
    _board.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  /// Another choice of servers asks again; a saved tag only redraws.
  void _storeChanged() {
    final servers = _booru.store.selectedServerIDs.join(',');
    if (servers != _servers) {
      _servers = servers;
      _load();
    }
    _changed();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    if (_loading != true) setState(() => _loading = true);
    final (posts, details) = await (
      StudyLookup.examples(_name, store: _booru.store, source: _booru.source),
      StudyLookup.info(_name, store: _booru.store, source: _booru.source),
    ).wait;
    if (!mounted || generation != _generation) return;
    setState(() {
      _examples = posts.take(18).toList();
      _info = details;
      _loading = false;
    });
  }

  Future<void> _practice() async {
    final tag = _tag;
    if (tag == null) return;
    await openStudyQuiz(
      context,
      booru: _booru,
      session: StudySession(scope: StudyScope.tags([_name, ...?tag.confusable]), store: _booru.store, source: _booru.source),
    );
    if (mounted) _board.reload(_booru.store);
  }

  void _copy() {
    Clipboard.setData(ClipboardData(text: _words));
    setState(() => _copied = true);
    _copiedTimer?.cancel();
    _copiedTimer = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  void _toggleSaved() {
    final server = _booru.store.selectedServers.firstOrNull;
    if (server == null) return;
    try {
      _booru.store.toggleTag(_name, serverID: server.id);
    } on Object catch (error) {
      showTransientMessage(context, '$error');
    }
  }

  void _browse() => pushStudy<void>(
    context,
    (context) => BooruFeedView(booru: _booru, servers: _booru.store.selectedServers, initialQuery: _name, onBack: () => Navigator.of(context).pop()),
  );

  void _open(BooruPost post) =>
      BooruPostView.open(context, booru: _booru, post: post, posts: _examples, discovery: DiscoveryContext.unknown, source: _booru.source);

  void _openTag(String name) => pushStudy<void>(context, (context) => StudyTagView(booru: _booru, name: name));

  @override
  Widget build(BuildContext context) {
    final tag = _tag;
    final rowColor = StudyPresentation.rowColor(context);
    final mixed = [for (final name in tag?.confusable ?? const <String>[]) ?_board.curriculum.tag(name)];
    final related = (_info?.related ?? const <StudyRelatedTag>[]).where((other) => other.category == 0).take(16).toList();
    final wiki = _info?.wiki;
    final selected = _booru.store.selectedServers;
    return StudyPage(
      title: _words,
      children: [
        const SizedBox(height: 25),
        _heading(context, rowColor),
        studySectionGap,
        _actions(context, rowColor),
        if (selected.isNotEmpty) ...[studySectionGap, _pictures(context, rowColor)],
        if (mixed.isNotEmpty) ...[
          studySectionGap,
          FormSection(
            prominentHeader: true,
            rowColor: rowColor,
            header: Text(L10n.text('Often Mixed Up With')),
            children: [for (final other in mixed) StudyTagRow(tag: other, progress: _board.progress[other.name], onTap: () => _openTag(other.name))],
          ),
        ],
        if (related.isNotEmpty) ...[
          studySectionGap,
          FormSection(
            prominentHeader: true,
            rowColor: rowColor,
            header: Text(L10n.text('Often Used Together')),
            footer: Text(L10n.text("The share of this tag's posts that also carry each tag.")),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: SizedBox(
                  width: double.infinity,
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final other in related)
                        _Chip(title: StudyPrompt.words(other.name), detail: '${(other.frequency * 100).round()}%', onTap: () => _openTag(other.name)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
        if (wiki != null) ..._page(context, rowColor, wiki),
      ],
    );
  }

  Widget _heading(BuildContext context, Color rowColor) {
    final tag = _tag;
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    final label = TegnalColors.label.resolveFrom(context);
    final unit = _board.curriculum.unitOf(_name);
    final other = _info?.wiki?.otherNames.where((value) => value != _name).firstOrNull;
    return FormSection(
      rowColor: rowColor,
      children: [
        FormRow(
          child: SizedBox(
            width: double.infinity,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            StudySelectable(
                              child: Text(
                                _words,
                                style: TegnalType.style(22, weight: FontWeight.w700, color: label),
                              ),
                            ),
                            if (tag != null && L10n.language != 'en') ...[
                              const SizedBox(height: 4),
                              Text(
                                tag.title(),
                                style: TegnalType.style(17, weight: FontWeight.w600, color: secondary),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      if (tag != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: StudyMastery(progress: _board.progress[_name]),
                        ),
                    ],
                  ),
                  if (tag != null) ...[
                    const SizedBox(height: 10),
                    Text(tag.note.resolved(), style: TegnalType.style(17, color: label)),
                  ] else if (!_loading && _info?.wiki == null) ...[
                    const SizedBox(height: 10),
                    Text(L10n.text('This tag is not part of the lessons, and the server has no page about it.'), style: TegnalType.style(15, color: secondary)),
                  ],
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (_info?.count case final count?) StudyBadge(icon: StudySymbols.posts, text: L10n.text('%@ posts', [StudyStyle.count(count)])),
                      if (unit != null) StudyBadge(icon: StudySymbols.unit(unit.symbol), text: unit.title.resolved()),
                      if (other != null) StudyBadge(icon: StudySymbols.otherName, text: other.replaceAll('_', ' ')),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _actions(BuildContext context, Color rowColor) {
    final selected = _booru.store.selectedServers;
    return FormSection(
      rowColor: rowColor,
      children: [
        StudyActionRow(
          key: const Key('study.copy'),
          title: L10n.text(_copied ? 'Copied' : 'Copy for a Prompt'),
          icon: _copied ? StudySymbols.copied : StudySymbols.copy,
          onTap: _copy,
        ),
        if (selected.isNotEmpty) ...[
          StudyActionRow(title: L10n.text('Browse Pictures With This Tag'), icon: StudySymbols.search, tinted: false, chevron: true, onTap: _browse),
          StudyActionRow(
            title: L10n.text(_saved ? 'Remove Saved Tag' : 'Save Tag'),
            icon: _saved ? CupertinoIcons.star_fill : CupertinoIcons.star,
            onTap: _toggleSaved,
          ),
        ],
        if (_tag != null)
          StudyActionRow(key: const Key('study.practice'), title: L10n.text('Practice This Tag'), icon: StudySymbols.practice, onTap: _practice),
      ],
    );
  }

  Widget _pictures(BuildContext context, Color rowColor) {
    final Widget content;
    if (_examples.isEmpty) {
      content = _loading
          ? const SizedBox(height: 120, child: Center(child: CupertinoActivityIndicator()))
          : Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                L10n.text('No pictures could be read for this tag.'),
                style: TegnalType.style(15, color: TegnalColors.secondaryLabel.resolveFrom(context)),
              ),
            );
    } else {
      content = SizedBox(
        height: 174,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.all(12).copyWith(left: 16, right: 16),
          children: [
            for (final post in _examples)
              if (_booru.store.servers.where((server) => server.id == post.serverID).firstOrNull case final server?)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: GestureDetector(
                    key: Key('study.example.${post.postID}'),
                    onTap: () => _open(post),
                    child: SizedBox(
                      width: 112,
                      height: 150,
                      child: ClipRSuperellipse(
                        borderRadius: BorderRadius.circular(10),
                        child: BooruThumbnail(post: post, server: server, booru: _booru),
                      ),
                    ),
                  ),
                ),
          ],
        ),
      );
    }
    return FormSection(prominentHeader: true, rowColor: rowColor, header: Text(L10n.text('Examples')), children: [content]);
  }

  List<Widget> _page(BuildContext context, Color rowColor, StudyWiki wiki) {
    final blocks = StudyDText.blocks(wiki.body);
    if (blocks.isEmpty) return const [];
    final shown = _showsWholePage ? blocks : blocks.take(6).toList();
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    final server = StudyLookup.infoServer(_booru.store);
    return [
      studySectionGap,
      FormSection(
        prominentHeader: true,
        rowColor: rowColor,
        header: Text(L10n.text("From the Server's Tag Page")),
        footer: server == null ? null : Text(server.displayName),
        children: [
          // One row for the whole page, so that its lines sit as close as running text.
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: SizedBox(
              width: double.infinity,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final (index, block) in shown.indexed) ...[
                    if (index > 0) const SizedBox(height: 8),
                    switch (block) {
                      StudyHeading(:final text) => Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          text,
                          style: TegnalType.style(15, weight: FontWeight.w600, color: TegnalColors.label.resolveFrom(context)),
                        ),
                      ),
                      StudyParagraph(:final spans) => StudyLinkedText(spans: spans, onTag: _openTag),
                      StudyBullet(:final level, :final spans) => Padding(
                        padding: EdgeInsets.only(left: (level - 1).clamp(0, 100) * 14.0),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('•', style: TegnalType.style(15, color: secondary)),
                            const SizedBox(width: 8),
                            Expanded(
                              child: StudyLinkedText(spans: spans, onTag: _openTag),
                            ),
                          ],
                        ),
                      ),
                    },
                  ],
                ],
              ),
            ),
          ),
          if (blocks.length > shown.length)
            FormRow(
              onTap: () => setState(() => _showsWholePage = true),
              child: Text(L10n.text('Show the Whole Page'), style: TegnalType.style(17, color: StudyStyle.accent(context))),
            ),
        ],
      ),
    ];
  }
}

/// `StudyLinkedText`: wiki wording whose tag links open that tag's page here.
class StudyLinkedText extends StatefulWidget {
  const StudyLinkedText({super.key, required this.spans, required this.onTag});
  final List<StudySpan> spans;
  final ValueChanged<String> onTag;

  @override
  State<StudyLinkedText> createState() => _StudyLinkedTextState();
}

class _StudyLinkedTextState extends State<StudyLinkedText> {
  final _recognizers = <TapGestureRecognizer>[];

  void _release() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
  }

  @override
  void dispose() {
    _release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _release();
    final base = TegnalType.style(15, color: TegnalColors.label.resolveFrom(context));
    final accent = StudyStyle.accent(context);
    return StudySelectable(
      child: Text.rich(
        TextSpan(
          children: [
            for (final span in widget.spans)
              TextSpan(
                text: span.text,
                style: base.copyWith(
                  fontWeight: span.bold ? FontWeight.w600 : null,
                  fontStyle: span.italic ? FontStyle.italic : null,
                  color: span.tag == null ? null : accent,
                ),
                recognizer: span.tag == null ? null : (TapGestureRecognizer()..onTap = () => widget.onTag(span.tag!)),
              ),
          ],
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.title, required this.detail, required this.onTap});
  final String title;
  final String detail;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: ShapeDecoration(color: StudyStyle.tertiaryFill.resolveFrom(context), shape: const StadiumBorder()),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(title, style: TegnalType.style(15, color: TegnalColors.label.resolveFrom(context))),
          const SizedBox(width: 5),
          Text(detail, style: TegnalType.style(11, color: TegnalColors.secondaryLabel.resolveFrom(context)).digits),
        ],
      ),
    ),
  );
}

/// A picture's tags written the way image generators are prompted, with the tags it can teach below.
class StudyPromptView extends StatefulWidget {
  const StudyPromptView({super.key, required this.booru, required this.post});
  final BooruContext booru;
  final BooruPost post;

  static const styleKey = 'study.promptStyle';
  static const artistsKey = 'study.promptArtists';

  @override
  State<StudyPromptView> createState() => _StudyPromptViewState();
}

class _StudyPromptViewState extends State<StudyPromptView> {
  final _board = StudyBoard();
  bool _copied = false;
  Timer? _copiedTimer;

  BooruContext get _booru => widget.booru;
  StudyPromptStyle get _style {
    final value = _booru.booruDefaults.string(StudyPromptView.styleKey);
    return StudyPromptStyle.values.where((style) => style.rawValue == value).firstOrNull ?? StudyPromptStyle.natural;
  }

  bool get _artists => _booru.booruDefaults.boolean(StudyPromptView.artistsKey) ?? false;
  String get _text => StudyPrompt.text(StudyPrompt.ordered(widget.post, artists: _artists), style: _style);

  @override
  void initState() {
    super.initState();
    _board.reload(_booru.store);
    _board.addListener(_changed);
  }

  @override
  void dispose() {
    _copiedTimer?.cancel();
    _board.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _copy() {
    Clipboard.setData(ClipboardData(text: _text));
    setState(() => _copied = true);
    _copiedTimer?.cancel();
    _copiedTimer = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  Future<void> _practice(List<StudyTag> taught) async {
    await openStudyQuiz(
      context,
      booru: _booru,
      session: StudySession(scope: StudyScope.tags([for (final tag in taught) tag.name]), store: _booru.store, source: _booru.source),
    );
    if (mounted) _board.reload(_booru.store);
  }

  @override
  Widget build(BuildContext context) {
    final rowColor = StudyPresentation.rowColor(context);
    final taught = _board.curriculum.taughtIn(widget.post);
    final style = _style;
    final footer = switch (style) {
      StudyPromptStyle.escaped => 'For tools that read brackets as emphasis: brackets that belong to a tag are escaped.',
      StudyPromptStyle.tags => 'The tags as the server writes them, ready to search with.',
      StudyPromptStyle.natural => 'Headcount first, then characters and series, then what the picture shows. File and translation tags are left out.',
    };
    return StudyPage(
      title: L10n.text('Prompt'),
      children: [
        const SizedBox(height: 25),
        FormSection(
          rowColor: rowColor,
          footer: Text(L10n.text(footer)),
          children: [
            SettingsSegmentedRow<StudyPromptStyle>(
              options: [
                (StudyPromptStyle.natural, L10n.text('Prompt')),
                (StudyPromptStyle.escaped, L10n.text('Escaped Brackets')),
                (StudyPromptStyle.tags, L10n.text('Search Tags')),
              ],
              selected: style,
              onSelected: (value) {
                _booru.booruDefaults.set(StudyPromptView.styleKey, value.rawValue);
                setState(() {});
              },
            ),
            FormRow(
              child: SizedBox(
                width: double.infinity,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: StudySelectable(
                    child: Text(
                      _text,
                      key: const Key('study.prompt'),
                      style: TegnalType.style(
                        16,
                        color: TegnalColors.label.resolveFrom(context),
                      ).copyWith(fontFamily: 'monospace', fontFamilyFallback: const []),
                    ),
                  ),
                ),
              ),
            ),
            if (widget.post.artists.isNotEmpty)
              SettingsToggleRow(
                title: L10n.text('Include Artist Names'),
                value: _artists,
                onChanged: (value) {
                  _booru.booruDefaults.set(StudyPromptView.artistsKey, value);
                  setState(() {});
                },
              ),
            StudyActionRow(
              key: const Key('study.promptCopy'),
              title: L10n.text(_copied ? 'Copied' : 'Copy Prompt'),
              icon: _copied ? StudySymbols.copied : StudySymbols.copy,
              onTap: _copy,
            ),
            StudyActionRow(
              key: const Key('study.promptGenerate'),
              title: L10n.text('Generate With This Prompt'),
              icon: CupertinoIcons.wand_stars,
              chevron: true,
              tinted: false,
              onTap: () => pushStudy<void>(
                context,
                (context) => GeneratorView.forBooru(_booru, prompt: StudyPrompt.text(StudyPrompt.ordered(widget.post, artists: _artists), style: StudyPromptStyle.escaped)),
              ),
            ),
          ],
        ),
        if (taught.isNotEmpty) ...[
          studySectionGap,
          FormSection(
            prominentHeader: true,
            rowColor: rowColor,
            header: Text(L10n.text('Tags in This Picture')),
            children: [
              StudyActionRow(
                key: const Key('study.promptPractice'),
                title: L10n.text('Practice These Tags'),
                icon: StudySymbols.practice,
                onTap: () => _practice(taught),
              ),
              for (final tag in taught)
                StudyTagRow(
                  tag: tag,
                  progress: _board.progress[tag.name],
                  onTap: () => pushStudy<void>(context, (context) => StudyTagView(booru: _booru, name: tag.name)),
                ),
            ],
          ),
        ],
      ],
    );
  }
}
