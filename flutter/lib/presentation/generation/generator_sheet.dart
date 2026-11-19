import 'package:cupertino_ui/cupertino_ui.dart';

import '../../core/generation/generation_store.dart';
import '../design/app_sheet.dart';
import '../design/grouped_form.dart';
import '../design/tegnal_theme.dart';

/// Pushes a screen of its own, as a `NavigationLink` does.
Future<T?> pushGenerator<T>(BuildContext context, WidgetBuilder builder) => Navigator.of(context).push<T>(CupertinoPageRoute<T>(builder: builder));

/// The monospaced face the prompt fields use (`.callout.monospaced()`).
TextStyle generatorMonospace(BuildContext context, {double size = 16}) =>
    TegnalType.style(size, color: TegnalColors.label.resolveFrom(context)).copyWith(fontFamily: 'monospace', fontFamilyFallback: const []);

/// What every generator screen reads: the store, and whether Safe Mode is on.
class GeneratorEnvironment {
  const GeneratorEnvironment({required this.store, required this.safeMode});
  final GenerationStore store;
  final bool Function() safeMode;
}

/// A sheet over the screen, as `.sheet` with a `NavigationStack` presents one.
Future<T?> showGeneratorSheet<T>(BuildContext context, WidgetBuilder builder) => showAppSheet<T>(context, builder: (context, controller) => builder(context));

/// A sheet's page: its bar with a title and buttons over a grouped list.
class GeneratorSheetPage extends StatelessWidget {
  const GeneratorSheetPage({super.key, required this.title, required this.children, this.leading, this.trailing, this.controller});
  final String title;

  /// The list's scroll controller.
  final ScrollController? controller;
  final Widget? leading;
  final Widget? trailing;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: FormColors.background.resolveFrom(context),
    child: Column(
      children: [
        SheetNavigationBar(title: title, leading: leading, trailing: trailing),
        Expanded(
          child: ListView(
            controller: controller,
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.only(top: 8, bottom: 32),
            children: children,
          ),
        ),
      ],
    ),
  );
}
