import 'dart:ui' as ui;

import 'package:cupertino_ui/cupertino_ui.dart';

import '../../core/storage/folder_rules.dart';
import '../../core/support/l10n.dart';
import '../design/app_sheet.dart';
import '../design/ios_controls.dart';
import '../design/tegnal_theme.dart';
import 'folder_rule_editor.dart';

/// What a [showFolderNamePrompt] returned: the trimmed name, and whether it is to be a smart folder.
class FolderNameResult {
  const FolderNameResult(this.name, {this.smart = false});
  final String name;
  final bool smart;
}

/// Every place that makes a folder asks with this prompt: a name, and a switch that makes it a smart
/// folder, set up on the next screen. Returns the new folder's identity (a comics folder's sync
/// identity or an image folder's id), or null when nothing was made.
Future<String?> createFolderWithPrompt(
  BuildContext context, {
  required SmartFolderLibrary library,
  bool booru = false,
  String title = 'New Folder',
  String actionTitle = 'Create',
  String? placeholder,
}) async {
  final result = await showFolderNamePrompt(context, title: title, actionTitle: actionTitle, placeholder: placeholder, offersSmart: true);
  if (!context.mounted || result == null || result.name.isEmpty) return null;
  if (!result.smart) return library.createRuleFolder(result.name);
  return showAppSheet<String>(
    context,
    builder: (context, controller) => FolderRuleEditor.create(library: library, booru: booru, name: result.name, scrollController: controller),
  );
}

/// `FolderNameAlert`: a prompt with a name field, the smart folder switch when offered, Cancel and
/// the action. It sits centered above the keyboard, 339 pt wide.
Future<FolderNameResult?> showFolderNamePrompt(
  BuildContext context, {
  String title = 'New Folder',
  String actionTitle = 'Create',
  bool offersSmart = false,
  String initialName = '',
  String? placeholder,
}) => Navigator.of(context, rootNavigator: true).push(
  PageRouteBuilder<FolderNameResult>(
    opaque: false,
    // Darker than a sheet's dimming, so the prompt stands out from whatever is behind it.
    barrierColor: const Color(0x8C000000),
    barrierDismissible: false,
    transitionDuration: const Duration(milliseconds: 220),
    reverseTransitionDuration: const Duration(milliseconds: 180),
    pageBuilder: (context, animation, _) =>
        _FolderNamePrompt(title: title, actionTitle: actionTitle, offersSmart: offersSmart, initialName: initialName, placeholder: placeholder),
    transitionsBuilder: (context, animation, _, child) => FadeTransition(
      opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
      child: ScaleTransition(
        scale: Tween(begin: 1.06, end: 1.0).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
        child: child,
      ),
    ),
  ),
);

class _FolderNamePrompt extends StatefulWidget {
  const _FolderNamePrompt({required this.title, required this.actionTitle, required this.offersSmart, required this.initialName, this.placeholder});
  final String? placeholder;
  final String title;
  final String actionTitle;
  final bool offersSmart;
  final String initialName;

  @override
  State<_FolderNamePrompt> createState() => _FolderNamePromptState();
}

class _FolderNamePromptState extends State<_FolderNamePrompt> {
  late final _name = TextEditingController(text: widget.initialName)..addListener(() => setState(() {}));
  bool _smart = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  String get _trimmed => _name.text.trim();

  void _finish(FolderNameResult? result) => Navigator.of(context).pop(result);

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final dark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    final label = TegnalColors.label.resolveFrom(context);
    const shape = RoundedSuperellipseBorder(borderRadius: BorderRadius.all(Radius.circular(32)));
    // `secondarySystemBackground` and `tertiarySystemBackground`: a solid card rather than glass,
    // so the field and the switch read clearly on any background.
    final card = dark ? const Color(0xFF1C1C1E) : const Color(0xFFF2F2F7);
    final field = dark ? const Color(0xFF2C2C2E) : const Color(0xFFFFFFFF);
    final prompt = ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 339),
      child: DecoratedBox(
        decoration: const ShapeDecoration(
          shape: shape,
          shadows: [BoxShadow(color: Color(0x33000000), blurRadius: 30, offset: Offset(0, 10))],
        ),
        child: ClipPath(
          clipper: const ShapeBorderClipper(shape: shape),
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 24, sigmaY: 24),
            child: DecoratedBox(
              decoration: ShapeDecoration(
                color: card,
                shape: shape.copyWith(side: BorderSide(color: dark ? const Color(0x24FFFFFF) : const Color(0x14000000), width: 0.5)),
              ),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      L10n.text(widget.title),
                      style: TegnalType.style(17, weight: FontWeight.w600, color: label),
                    ),
                    const SizedBox(height: 16),
                    Container(
                      height: 48,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      decoration: ShapeDecoration(
                        color: field,
                        shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(14)),
                      ),
                      alignment: Alignment.centerLeft,
                      child: CupertinoTextField.borderless(
                        controller: _name,
                        autofocus: true,
                        placeholder: widget.placeholder ?? L10n.text('Folder Name'),
                        placeholderStyle: TegnalType.style(17, color: TegnalColors.secondaryLabel.resolveFrom(context)),
                        style: TegnalType.style(17, color: label),
                        padding: EdgeInsets.zero,
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) {
                          if (_trimmed.isNotEmpty) _finish(FolderNameResult(_trimmed, smart: _smart));
                        },
                      ),
                    ),
                    if (widget.offersSmart) ...[
                      const SizedBox(height: 16),
                      Container(
                        height: 48,
                        padding: const EdgeInsets.only(left: 16, right: 12),
                        decoration: ShapeDecoration(
                          color: field,
                          shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(14)),
                        ),
                        child: Row(
                          children: [
                            Icon(CupertinoIcons.sparkles, size: 20, color: TegnalColors.tint.resolveFrom(context)),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(L10n.text('Smart Folder'), style: TegnalType.style(17, color: label)),
                            ),
                            TegnalSwitch(value: _smart, onChanged: (value) => setState(() => _smart = value)),
                          ],
                        ),
                      ),
                      const SizedBox(height: 6),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Text(
                          L10n.text('Files works that match its tags here on their own. You choose the tags next.'),
                          style: TegnalType.style(13, color: TegnalColors.secondaryLabel.resolveFrom(context)),
                        ),
                      ),
                    ],
                    const SizedBox(height: 20),
                    Row(
                      children: [
                        Expanded(
                          child: _CapsuleButton(title: L10n.text('Cancel'), prominent: false, onPressed: () => _finish(null)),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _CapsuleButton(
                            title: L10n.text(_smart ? 'Next' : widget.actionTitle),
                            prominent: true,
                            onPressed: _trimmed.isEmpty ? null : () => _finish(FolderNameResult(_trimmed, smart: _smart)),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    // Centered between the status bar and the keyboard, with 24 pt margins.
    return Padding(
      padding: EdgeInsets.fromLTRB(24, media.padding.top, 24, media.viewInsets.bottom),
      child: Center(child: prompt),
    );
  }
}

/// `.bordered` and `.borderedProminent` capsule buttons at the large size.
class _CapsuleButton extends StatelessWidget {
  const _CapsuleButton({required this.title, required this.prominent, required this.onPressed});
  final String title;
  final bool prominent;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final dark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    final tint = TegnalColors.tint.resolveFrom(context);
    final enabled = onPressed != null;
    final Color fill;
    final Color text;
    if (prominent && enabled) {
      fill = tint;
      text = const Color(0xFFFFFFFF);
    } else if (prominent) {
      fill = dark ? const Color(0xCC000000) : const Color(0x14000000);
      text = TegnalColors.tertiaryLabel.resolveFrom(context);
    } else {
      fill = dark ? const Color(0xB3000000) : const Color(0x1F767680);
      text = tint;
    }
    return Semantics(
      button: true,
      enabled: enabled,
      child: GestureDetector(
        onTap: onPressed,
        child: Container(
          height: 57,
          alignment: Alignment.center,
          decoration: ShapeDecoration(color: fill, shape: const StadiumBorder()),
          child: Text(
            title,
            style: TegnalType.style(17, weight: prominent && enabled ? FontWeight.w600 : FontWeight.w400, color: text),
          ),
        ),
      ),
    );
  }
}
