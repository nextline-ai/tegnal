import 'package:cupertino_ui/cupertino_ui.dart';

import '../../core/support/l10n.dart';
import '../design/glass.dart';
import '../design/grouped_form.dart';
import '../design/tegnal_theme.dart';
import '../navigation/app_header.dart';
import '../navigation/root_tab_view.dart';

/// A screen pushed from Settings: an inline title between a glass back button and
/// optional trailing controls, over an inset-grouped list on the system background.
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.title, required this.children, this.trailing, this.controller, this.sheet = false});
  final String title;

  /// A page inside a sheet: the sheet's grouped background, its 76 pt bar and lighter glass.
  final bool sheet;
  final List<Widget> children;
  final Widget? trailing;
  final ScrollController? controller;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final top = media.padding.top + rootBarHeight;
    return ColoredBox(
      color: (sheet ? FormColors.background : FormColors.listBackground).resolveFrom(context),
      child: Stack(
        children: [
          Positioned.fill(
            bottom: media.viewInsets.bottom,
            child: ListView(
              controller: controller,
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: EdgeInsets.only(
                top: sheet ? 69 + 35 : top + 10,
                bottom: media.viewInsets.bottom > 0 ? 16 : (sheet ? 32 + media.padding.bottom : tabBarClearance(context)),
              ),
              children: children,
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: sheet
                // The sheet's bar centers its 44 pt buttons 38 pt below the sheet's top edge.
                ? MediaQuery(
                    data: media.copyWith(padding: media.padding.copyWith(top: 16)),
                    child: InlineTitleHeader(title: title, trailing: trailing, elevated: true),
                  )
                : InlineTitleHeader(title: title, trailing: trailing),
          ),
        ],
      ),
    );
  }
}

/// `.navigationBarTitleDisplayMode(.inline)` on a pushed screen: the back circle, the title centered.
class InlineTitleHeader extends StatelessWidget {
  const InlineTitleHeader({super.key, required this.title, this.trailing, this.back = true, this.elevated = false});
  final String title;
  final Widget? trailing;

  /// In a sheet the back button uses the lighter glass.
  final bool elevated;

  /// A sheet's root has no back button.
  final bool back;

  @override
  Widget build(BuildContext context) {
    final label = TegnalColors.label.resolveFrom(context);
    return Padding(
      padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
      child: SizedBox(
        height: rootBarHeight,
        child: Stack(
          children: [
            if (back)
              Positioned(
                left: 16,
                top: 0,
                child: Semantics(
                  button: true,
                  label: L10n.text('Back'),
                  excludeSemantics: true,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => Navigator.of(context).maybePop(),
                    child: Glass.circle(
                      elevated: elevated,
                      child: SizedBox.square(dimension: 44, child: Icon(CupertinoIcons.chevron_left, size: 22, color: label)),
                    ),
                  ),
                ),
              ),
            Positioned(
              left: 72,
              right: 72,
              top: 0,
              height: 44,
              child: Center(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TegnalType.style(17, weight: FontWeight.w600, color: label),
                ),
              ),
            ),
            if (trailing != null) Positioned(right: 16, top: 0, child: trailing!),
          ],
        ),
      ),
    );
  }
}

/// The gap the native inset-grouped list leaves between sections.
const settingsSectionGap = SizedBox(height: 28);
