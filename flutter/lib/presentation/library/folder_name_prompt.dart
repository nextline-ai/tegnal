import 'dart:ui' as ui;

import 'package:cupertino_ui/cupertino_ui.dart';

import '../../core/support/l10n.dart';
import '../design/tegnal_theme.dart';

/// What a [showFolderNamePrompt] returned: the trimmed name, or the alternate action.
class FolderNameResult {
  const FolderNameResult(this.name, {this.alternate = false});
  final String name;
  final bool alternate;
}

/// `FolderNameAlert`: a glass prompt with a name field, Cancel and the action, and an
/// optional link below them. It sits centered above the keyboard, 339 pt wide.
Future<FolderNameResult?> showFolderNamePrompt(
  BuildContext context, {
  String title = 'New Folder',
  String actionTitle = 'Create',
  String? alternateTitle,
  String initialName = '',
  String? placeholder,
}) => Navigator.of(context, rootNavigator: true).push(
  PageRouteBuilder<FolderNameResult>(
    opaque: false,
    barrierColor: const Color(0x4D000000),
    barrierDismissible: false,
    transitionDuration: const Duration(milliseconds: 220),
    reverseTransitionDuration: const Duration(milliseconds: 180),
    pageBuilder: (context, animation, _) =>
        _FolderNamePrompt(title: title, actionTitle: actionTitle, alternateTitle: alternateTitle, initialName: initialName, placeholder: placeholder),
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
  const _FolderNamePrompt({required this.title, required this.actionTitle, required this.alternateTitle, required this.initialName, this.placeholder});
  final String? placeholder;
  final String title;
  final String actionTitle;
  final String? alternateTitle;
  final String initialName;

  @override
  State<_FolderNamePrompt> createState() => _FolderNamePromptState();
}

class _FolderNamePromptState extends State<_FolderNamePrompt> {
  late final _name = TextEditingController(text: widget.initialName)..addListener(() => setState(() {}));

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
    final tint = TegnalColors.tint.resolveFrom(context);
    const shape = RoundedSuperellipseBorder(borderRadius: BorderRadius.all(Radius.circular(32)));
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
                color: dark ? const Color(0x80303036) : const Color(0xCCFAFAFA),
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
                    const SizedBox(height: 20),
                    Container(
                      height: 48,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      decoration: ShapeDecoration(
                        color: label.withValues(alpha: 0.08),
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
                          if (_trimmed.isNotEmpty) _finish(FolderNameResult(_trimmed));
                        },
                      ),
                    ),
                    const SizedBox(height: 20),
                    Row(
                      children: [
                        Expanded(
                          child: _CapsuleButton(title: L10n.text('Cancel'), prominent: false, onPressed: () => _finish(null)),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _CapsuleButton(
                            title: L10n.text(widget.actionTitle),
                            prominent: true,
                            onPressed: _trimmed.isEmpty ? null : () => _finish(FolderNameResult(_trimmed)),
                          ),
                        ),
                      ],
                    ),
                    if (widget.alternateTitle != null) ...[
                      const SizedBox(height: 20),
                      GestureDetector(
                        onTap: () => _finish(FolderNameResult(_trimmed, alternate: true)),
                        child: Text(widget.alternateTitle!, style: TegnalType.style(15, color: tint)),
                      ),
                    ],
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
