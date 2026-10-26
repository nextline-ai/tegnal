import 'package:material_ui/material_ui.dart';

import '../core/app_controller.dart';
import '../core/content.dart';
import 'l10n.dart';

/// Lets the user choose the Booru sources used by Explore.
///
/// This selection is deliberately independent from saved library contents.
/// Returns true when the user applied a selection, including an empty one.
Future<bool> showBooruSourcePicker(
  BuildContext context,
  AppController controller,
) async {
  final selected = controller
      .selectedSources(AppMode.booru)
      .map((source) => source.id)
      .toSet();
  final choices = controller.sources(AppMode.booru);
  final apply = await showModalBottomSheet<bool>(
    context: context,
    useRootNavigator: true,
    useSafeArea: true,
    builder: (context) => StatefulBuilder(
      builder: (context, setSheet) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.all(20),
                child: DefaultTextStyle(
                  style: Theme.of(context).textTheme.titleLarge!,
                  child: Text(L10n.tr(context, 'Servers')),
                ),
              ),
              for (final source in choices)
                CheckboxListTile(
                  title: Text(source.name),
                  value: selected.contains(source.id),
                  onChanged: (_) => setSheet(() {
                    selected.contains(source.id)
                        ? selected.remove(source.id)
                        : selected.add(source.id);
                  }),
                  controlAffinity: ListTileControlAffinity.leading,
                ),
              const Divider(),
              ListTile(
                title: Text(L10n.tr(context, 'Done')),
                onTap: () => Navigator.pop(context, true),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  if (apply != true) return false;

  controller.selectSources(
    choices.where((source) => selected.contains(source.id)).toList(),
  );
  return true;
}
