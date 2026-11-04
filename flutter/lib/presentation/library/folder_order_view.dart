import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/services.dart';

import '../../core/support/l10n.dart';
import '../design/grouped_form.dart';
import '../design/tegnal_theme.dart';

/// `FolderOrderView`: the folders in an editing list, dragged by their handles, saved together.
/// Comics and image folders differ only in their identifiers and store.
class FolderOrderView<ID extends Object> extends StatefulWidget {
  const FolderOrderView({super.key, required this.folders, required this.save});
  final List<({ID id, String name})> folders;
  final void Function(List<ID> order) save;

  @override
  State<FolderOrderView<ID>> createState() => _FolderOrderViewState<ID>();
}

class _FolderOrderViewState<ID extends Object> extends State<FolderOrderView<ID>> {
  late final List<({ID id, String name})> _entries = [...widget.folders];
  String? _error;

  void _save() {
    try {
      widget.save([for (final entry in _entries) entry.id]);
      Navigator.of(context).pop();
    } on Object catch (error) {
      setState(() => _error = '$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final row = FormColors.row.resolveFrom(context);
    final separator = TegnalColors.separator.resolveFrom(context);
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    return ScrollEdgeSheet(
      bar: SheetNavigationBar(
        title: L10n.text('Reorder Folders'),
        leading: GlassTextButton(label: L10n.text('Cancel'), onPressed: () => Navigator.of(context).pop()),
        trailing: GlassTextButton(label: L10n.text('Save'), prominent: true, onPressed: _save),
      ),
      child: CustomScrollView(
        slivers: [
          const SliverToBoxAdapter(child: SizedBox(height: 76 + 4)),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            sliver: SliverReorderableList(
              itemCount: _entries.length,
              onReorderStart: (_) => HapticFeedback.selectionClick(),
              onReorderItem: (from, to) => setState(() => _entries.insert(to, _entries.removeAt(from))),
              proxyDecorator: (child, index, animation) => DecoratedBox(
                decoration: const BoxDecoration(
                  boxShadow: [BoxShadow(color: Color(0x33000000), blurRadius: 16, offset: Offset(0, 6))],
                ),
                child: child,
              ),
              itemBuilder: (context, index) {
                final entry = _entries[index];
                final first = index == 0, last = index == _entries.length - 1;
                return ReorderableDelayedDragStartListener(
                  key: ValueKey(entry.id),
                  index: index,
                  child: Container(
                    height: 52,
                    decoration: ShapeDecoration(
                      color: row,
                      shape: RoundedSuperellipseBorder(
                        borderRadius: BorderRadius.vertical(top: Radius.circular(first ? 26 : 0), bottom: Radius.circular(last ? 26 : 0)),
                      ),
                    ),
                    child: Stack(
                      children: [
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(entry.name, style: TegnalType.style(17, color: TegnalColors.label.resolveFrom(context))),
                              ),
                              ReorderableDragStartListener(
                                index: index,
                                child: SizedBox(width: 44, height: 52, child: Icon(CupertinoIcons.line_horizontal_3, size: 22, color: secondary)),
                              ),
                            ],
                          ),
                        ),
                        if (!last) Positioned(left: 16, right: 16, bottom: 0, child: Container(height: 0.5, color: separator)),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          if (_error != null)
            SliverPadding(
              padding: const EdgeInsets.all(16),
              sliver: SliverToBoxAdapter(
                child: Text(_error!, style: TegnalType.style(15, color: CupertinoColors.systemRed)),
              ),
            ),
        ],
      ),
    );
  }
}
