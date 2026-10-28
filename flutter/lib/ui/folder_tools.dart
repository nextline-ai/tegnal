import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import '../core/library.dart';
import 'l10n.dart';

/// An opaque, unrestricted picker, like the native folder color sheet. Every
/// selection is applied immediately; closing the sheet keeps the last color.
Future<void> showFolderColorPicker(
  BuildContext context, {
  required String title,
  required int color,
  required ValueChanged<int> onChanged,
}) => showModalBottomSheet<void>(
  context: context,
  useRootNavigator: true,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (_) =>
      _FolderColorPicker(title: title, color: color, onChanged: onChanged),
);

class _FolderColorPicker extends StatefulWidget {
  const _FolderColorPicker({
    required this.title,
    required this.color,
    required this.onChanged,
  });
  final String title;
  final int color;
  final ValueChanged<int> onChanged;
  @override
  State<_FolderColorPicker> createState() => _FolderColorPickerState();
}

class _FolderColorPickerState extends State<_FolderColorPicker> {
  late Color _color = Color(widget.color).withAlpha(255);
  late final _hex = TextEditingController(
    text: _color.toARGB32().toRadixString(16).substring(2).toUpperCase(),
  );
  @override
  void dispose() {
    _hex.dispose();
    super.dispose();
  }

  void _change(Color color, {bool updateText = true}) {
    setState(() {
      _color = color.withAlpha(255);
      if (updateText) {
        _hex.text = _color
            .toARGB32()
            .toRadixString(16)
            .substring(2)
            .toUpperCase();
      }
    });
    widget.onChanged(_color.toARGB32());
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        20,
        12,
        20,
        20 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: DefaultTabController(
        length: 2,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    widget.title,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                IconButton(
                  tooltip: L10n.tr(context, 'Done'),
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.check),
                ),
              ],
            ),
            TabBar(
              tabs: [
                Tab(text: L10n.tr(context, 'Grid')),
                Tab(text: L10n.tr(context, 'Sliders')),
              ],
            ),
            SizedBox(
              height: 300,
              child: TabBarView(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    child: GridView.count(
                      crossAxisCount: 12,
                      mainAxisSpacing: 0,
                      crossAxisSpacing: 0,
                      childAspectRatio: 1.15,
                      children: [
                        for (var row = 0; row < 10; row++)
                          for (var column = 0; column < 12; column++)
                            Builder(
                              builder: (context) {
                                final swatch = row == 0
                                    ? Color.fromARGB(
                                        255,
                                        (255 * (1 - column / 11)).round(),
                                        (255 * (1 - column / 11)).round(),
                                        (255 * (1 - column / 11)).round(),
                                      )
                                    : HSVColor.fromAHSV(
                                        1,
                                        column * 30,
                                        row < 5 ? row / 4 : 1,
                                        row < 5 ? 1 : 1 - (row - 4) * .15,
                                      ).toColor();
                                return InkWell(
                                  key: ValueKey(
                                    'folder-color-${row * 12 + column}',
                                  ),
                                  onTap: () => _change(swatch),
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      color: swatch,
                                      border:
                                          _color.toARGB32() == swatch.toARGB32()
                                          ? Border.all(
                                              color: Colors.white,
                                              width: 2,
                                            )
                                          : null,
                                    ),
                                  ),
                                );
                              },
                            ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Column(
                      children: [
                        for (var channel = 0; channel < 3; channel++)
                          Builder(
                            builder: (context) {
                              final rgb = [
                                (_color.toARGB32() >> 16) & 255,
                                (_color.toARGB32() >> 8) & 255,
                                _color.toARGB32() & 255,
                              ];
                              return Row(
                                children: [
                                  SizedBox(
                                    width: 20,
                                    child: Text(['R', 'G', 'B'][channel]),
                                  ),
                                  Expanded(
                                    child: Slider(
                                      key: ValueKey(
                                        'folder-color-channel-$channel',
                                      ),
                                      value: rgb[channel].toDouble(),
                                      max: 255,
                                      divisions: 255,
                                      activeColor: [
                                        Colors.red,
                                        Colors.green,
                                        Colors.blue,
                                      ][channel],
                                      label: '${rgb[channel]}',
                                      onChanged: (value) {
                                        rgb[channel] = value.round();
                                        _change(
                                          Color.fromARGB(
                                            255,
                                            rgb[0],
                                            rgb[1],
                                            rgb[2],
                                          ),
                                        );
                                      },
                                    ),
                                  ),
                                  SizedBox(
                                    width: 28,
                                    child: Text(
                                      '${rgb[channel]}',
                                      textAlign: TextAlign.end,
                                    ),
                                  ),
                                ],
                              );
                            },
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: _color,
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: TextField(
                    key: const ValueKey('folder-color-hex'),
                    controller: _hex,
                    textCapitalization: TextCapitalization.characters,
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp('[0-9a-fA-F]')),
                      LengthLimitingTextInputFormatter(6),
                    ],
                    decoration: InputDecoration(
                      prefixText: '#',
                      labelText: L10n.tr(context, 'Hex Color'),
                    ),
                    onChanged: (value) {
                      if (value.length == 6) {
                        _change(
                          Color(0xFF000000 | int.parse(value, radix: 16)),
                          updateText: false,
                        );
                      }
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

Future<List<LibraryFolder>?> showFolderOrder(
  BuildContext context,
  List<LibraryFolder> folders,
) => showModalBottomSheet<List<LibraryFolder>>(
  context: context,
  useRootNavigator: true,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (_) => _FolderOrderSheet(folders: folders),
);

class _FolderOrderSheet extends StatefulWidget {
  const _FolderOrderSheet({required this.folders});
  final List<LibraryFolder> folders;
  @override
  State<_FolderOrderSheet> createState() => _FolderOrderSheetState();
}

class _FolderOrderSheetState extends State<_FolderOrderSheet> {
  late final List<LibraryFolder> _folders = List.of(widget.folders);
  @override
  Widget build(BuildContext context) => SafeArea(
    child: SizedBox(
      height: MediaQuery.sizeOf(context).height * .7,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
            child: Row(
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(L10n.tr(context, 'Cancel')),
                ),
                Expanded(
                  child: Text(
                    L10n.tr(context, 'Reorder Folders'),
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context, _folders),
                  child: Text(L10n.tr(context, 'Save')),
                ),
              ],
            ),
          ),
          Expanded(
            child: ReorderableListView.builder(
              buildDefaultDragHandles: false,
              itemCount: _folders.length,
              onReorderItem: (from, to) => setState(() {
                _folders.insert(to, _folders.removeAt(from));
              }),
              itemBuilder: (context, index) => ListTile(
                key: ValueKey('folder-order-${_folders[index].id}'),
                leading: Icon(
                  Icons.folder,
                  color: Color(_folders[index].color),
                ),
                title: Text(_folders[index].name),
                trailing: ReorderableDragStartListener(
                  index: index,
                  child: const Padding(
                    padding: EdgeInsets.all(12),
                    child: Icon(Icons.drag_handle),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
