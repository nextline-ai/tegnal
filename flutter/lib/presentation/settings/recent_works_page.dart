import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/foundation.dart' show Uint8List;

import '../../core/booru/booru_models.dart';
import '../../core/booru/booru_store.dart';
import '../../core/content/recent_works.dart';
import '../../core/storage/work_query.dart';
import '../../core/support/l10n.dart';
import '../design/alert_dialog.dart';
import '../design/grouped_form.dart';
import '../design/symbols.dart';
import '../design/tegnal_theme.dart';
import '../works/search_controls.dart';
import 'settings_page.dart';
import 'settings_rows.dart';

/// The rows Search History settings gain: the list of recently opened works or images, and a
/// slider for how many to keep.
abstract final class RecentWorksSettingsRows {
  static List<Widget> comics(BuildContext context, {required RecentWorks recents, required void Function(BuildContext context, int id) open}) => [
    ListenableBuilder(
      listenable: recents,
      builder: (context, _) => SettingsLinkRow(
        title: L10n.text('Recently Opened Works'),
        value: '${recents.entries.length}',
        onTap: () => Navigator.of(context).push(
          CupertinoPageRoute<void>(
            builder: (_) => RecentWorksPage(recents: recents, open: open),
          ),
        ),
      ),
    ),
    _LimitRow(title: L10n.text('Keep Recent Works'), unit: '%@ works', limit: () => recents.limit, setLimit: recents.setLimit),
  ];

  static List<Widget> images(
    BuildContext context, {
    required RecentImages recents,
    required BooruStore store,
    required Widget Function(BooruPost post, BooruServer server) thumbnail,
    required void Function(BuildContext context, BooruPost post, List<BooruPost> posts) open,
  }) => [
    ListenableBuilder(
      listenable: recents,
      builder: (context, _) => SettingsLinkRow(
        title: L10n.text('Recently Opened Images'),
        value: '${recents.entries.length}',
        onTap: () => Navigator.of(context).push(
          CupertinoPageRoute<void>(
            builder: (_) => RecentImagesPage(recents: recents, store: store, thumbnail: thumbnail, open: open),
          ),
        ),
      ),
    ),
    _LimitRow(title: L10n.text('Keep Recent Images'), unit: '%@ items', limit: () => recents.limit, setLimit: recents.setLimit),
  ];

  static String title(int count, String unit) => count == 0 ? L10n.text("Don't Keep") : L10n.text(unit, ['$count']);
}

/// None, or up to 500 in steps of ten; the list follows once the slider is let go.
class _LimitRow extends StatefulWidget {
  const _LimitRow({required this.title, required this.unit, required this.limit, required this.setLimit});
  final String title;
  final String unit;
  final int Function() limit;
  final ValueChanged<int> setLimit;

  @override
  State<_LimitRow> createState() => _LimitRowState();
}

class _LimitRowState extends State<_LimitRow> {
  late double _value = widget.limit().toDouble();

  @override
  Widget build(BuildContext context) {
    final shown = RecentWorksSettingsRows.title(_value.round(), widget.unit);
    return FormRow(
      child: Semantics(
        label: widget.title,
        value: shown,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(child: Text(widget.title)),
                Text(shown, style: TegnalType.style(17, color: TegnalColors.secondaryLabel.resolveFrom(context))),
              ],
            ),
            CupertinoSlider(
              value: _value,
              max: RecentLimit.maximum.toDouble(),
              divisions: RecentLimit.maximum ~/ RecentLimit.step,
              onChanged: (value) => setState(() => _value = value),
              onChangeEnd: (value) => widget.setLimit(value.round()),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> _confirmClear(BuildContext context, String title, VoidCallback clear) async {
  final confirmed = await showCupertinoDialog<bool>(
    context: context,
    builder: (context) => TegnalAlertDialog(
      title: Text(title),
      actions: [
        CupertinoDialogAction(onPressed: () => Navigator.pop(context, false), child: Text(L10n.text('Cancel'))),
        CupertinoDialogAction(isDestructiveAction: true, onPressed: () => Navigator.pop(context, true), child: Text(L10n.text('Clear All'))),
      ],
    ),
  );
  if (confirmed == true) clear();
}

/// `Date.formatted(.relative(presentation: .named))`, in the app's words.
String _ago(DateTime date) {
  final elapsed = DateTime.now().difference(date);
  if (elapsed.inMinutes < 1) return L10n.text('Just now');
  if (elapsed.inHours < 1) return L10n.text('%@ min ago', ['${elapsed.inMinutes}']);
  if (elapsed.inDays < 1) return L10n.text('%@ hr ago', ['${elapsed.inHours}']);
  return L10n.text('%@ days ago', ['${elapsed.inDays}']);
}

Widget _empty(BuildContext context, {required String title, required String message}) {
  final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
  return Padding(
    padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 80),
    child: Column(
      children: [
        Icon(CupertinoIcons.clock, size: 44, color: secondary),
        const SizedBox(height: 12),
        Text(
          title,
          textAlign: TextAlign.center,
          style: TegnalType.style(22, weight: FontWeight.w700, color: TegnalColors.label.resolveFrom(context)),
        ),
        const SizedBox(height: 6),
        Text(
          message,
          textAlign: TextAlign.center,
          style: TegnalType.style(15, color: secondary),
        ),
      ],
    ),
  );
}

Widget _dismissible(BuildContext context, {required Key key, required VoidCallback remove, required Widget child}) => Dismissible(
  key: key,
  direction: DismissDirection.endToStart,
  onDismissed: (_) => remove(),
  background: Container(
    color: CupertinoColors.systemRed.resolveFrom(context),
    alignment: Alignment.centerRight,
    padding: const EdgeInsets.only(right: 16),
    child: const Icon(CupertinoIcons.trash, color: Color(0xFFFFFFFF)),
  ),
  child: child,
);

/// `RecentWorksView`: recently opened works, newest first, searched as Saved is; a tap opens
/// the work again.
class RecentWorksPage extends StatefulWidget {
  const RecentWorksPage({super.key, required this.recents, required this.open});
  final RecentWorks recents;
  final void Function(BuildContext context, int id) open;

  @override
  State<RecentWorksPage> createState() => _RecentWorksPageState();
}

class _RecentWorksPageState extends State<RecentWorksPage> {
  final _search = TextEditingController();
  final _focus = FocusNode();

  @override
  void dispose() {
    _search.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([widget.recents, _search]),
    builder: (context, _) {
      final recents = widget.recents;
      final query = WorkQuery(_search.text);
      final shown = query.isEmpty ? recents.entries : recents.entries.where((entry) => entry.matches(query)).toList();
      return SettingsPage(
        title: L10n.text('Recently Opened Works'),
        trailing: recents.entries.isEmpty
            ? null
            : GlassTextButton(label: L10n.text('Clear All'), onPressed: () => _confirmClear(context, L10n.text('Clear recently opened works?'), recents.clear)),
        children: [
          ScrollSearchBar(controller: _search, focusNode: _focus, prompt: L10n.text('Search works')),
          if (recents.entries.isEmpty)
            _empty(context, title: L10n.text('No Recent Works'), message: L10n.text('Works you open in the viewer appear here.'))
          else if (shown.isEmpty)
            _empty(context, title: L10n.text('No Results'), message: L10n.text("No results for '%@'", [_search.text]))
          else
            FormSection(
              rowColor: FormColors.listRow.resolveFrom(context),
              children: [
                for (final entry in shown)
                  FormRow(
                    onTap: () => widget.open(context, entry.id),
                    child: _dismissible(
                      context,
                      key: ValueKey(entry.id),
                      remove: () => recents.remove(entry.id),
                      child: _RecentWorkRow(entry: entry, cover: recents.cover(entry.id)),
                    ),
                  ),
              ],
            ),
        ],
      );
    },
  );
}

class _RecentWorkRow extends StatelessWidget {
  const _RecentWorkRow({required this.entry, required this.cover});
  final RecentWork entry;
  final Uint8List? cover;

  @override
  Widget build(BuildContext context) {
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    final item = entry.item;
    final detail = [item.artists, item.details].where((part) => part.isNotEmpty).join(' · ');
    final image = cover;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: 48,
              height: 68,
              child: image != null
                  ? Image.memory(image, fit: BoxFit.cover, gaplessPlayback: true)
                  : ColoredBox(
                      color: TegnalColors.coverPlaceholder.resolveFrom(context),
                      child: Center(child: Icon(Symbols.book, color: secondary)),
                    ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.displayTitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TegnalType.style(15, weight: FontWeight.w600),
                ),
                if (detail.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    detail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TegnalType.style(12, color: secondary),
                  ),
                ],
                const SizedBox(height: 3),
                Text(_ago(entry.openedAt), style: TegnalType.style(11, color: TegnalColors.tertiaryLabel.resolveFrom(context))),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Recently opened images, newest first, searched as favorites are; a tap opens the image again.
class RecentImagesPage extends StatefulWidget {
  const RecentImagesPage({super.key, required this.recents, required this.store, required this.thumbnail, required this.open});
  final RecentImages recents;
  final BooruStore store;
  final Widget Function(BooruPost post, BooruServer server) thumbnail;
  final void Function(BuildContext context, BooruPost post, List<BooruPost> posts) open;

  @override
  State<RecentImagesPage> createState() => _RecentImagesPageState();
}

class _RecentImagesPageState extends State<RecentImagesPage> {
  final _search = TextEditingController();
  final _focus = FocusNode();

  @override
  void dispose() {
    _search.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([widget.recents, _search]),
    builder: (context, _) {
      final recents = widget.recents;
      final query = _search.text;
      final shown = recents.entries.where((entry) => BooruStore.matches(entry.post, query) && widget.store.isShownInSafeMode(entry.post)).toList();
      final servers = {for (final server in widget.store.servers) server.id: server};
      final openable = [
        for (final entry in shown)
          if (servers.containsKey(entry.post.serverID)) entry.post,
      ];
      final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
      return SettingsPage(
        title: L10n.text('Recently Opened Images'),
        trailing: recents.entries.isEmpty
            ? null
            : GlassTextButton(
                label: L10n.text('Clear All'),
                onPressed: () => _confirmClear(context, L10n.text('Clear recently opened images?'), recents.clear),
              ),
        children: [
          ScrollSearchBar(controller: _search, focusNode: _focus, prompt: L10n.text('Search tags')),
          if (recents.entries.isEmpty)
            _empty(context, title: L10n.text('No Recent Images'), message: L10n.text('Images you open in the viewer appear here.'))
          else if (shown.isEmpty)
            _empty(context, title: L10n.text('No Results'), message: L10n.text("No results for '%@'", [query]))
          else
            FormSection(
              rowColor: FormColors.listRow.resolveFrom(context),
              children: [
                for (final entry in shown)
                  FormRow(
                    onTap: servers.containsKey(entry.post.serverID) ? () => widget.open(context, entry.post, openable) : null,
                    child: _dismissible(
                      context,
                      key: ValueKey(entry.id),
                      remove: () => recents.remove(entry.id),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: SizedBox(
                                width: 56,
                                height: 56,
                                child: servers[entry.post.serverID] != null
                                    ? widget.thumbnail(entry.post, servers[entry.post.serverID]!)
                                    : ColoredBox(
                                        color: TegnalColors.coverPlaceholder.resolveFrom(context),
                                        child: Center(child: Icon(CupertinoIcons.photo, color: secondary)),
                                      ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '${servers[entry.post.serverID]?.displayName ?? entry.post.serverID} · ${entry.post.postID}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TegnalType.style(15, weight: FontWeight.w600),
                                  ),
                                  if (entry.post.tags.isNotEmpty) ...[
                                    const SizedBox(height: 3),
                                    Text(
                                      entry.post.tags.take(8).join(' ').replaceAll('_', ' '),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: TegnalType.style(12, color: secondary),
                                    ),
                                  ],
                                  const SizedBox(height: 3),
                                  Text(_ago(entry.openedAt), style: TegnalType.style(11, color: TegnalColors.tertiaryLabel.resolveFrom(context))),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
        ],
      );
    },
  );
}
