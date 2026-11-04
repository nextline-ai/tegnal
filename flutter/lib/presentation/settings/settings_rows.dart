import 'package:cupertino_ui/cupertino_ui.dart';

import '../design/grouped_form.dart';
import '../design/ios_controls.dart';
import '../design/pull_down_menu.dart';
import '../design/tegnal_theme.dart';

/// A row title, with the setting's info button beside it when it has help.
class SettingsTitle extends StatelessWidget {
  const SettingsTitle(this.title, {super.key, this.help, this.style});
  final String title;
  final String? help;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Flexible(child: Text(title, style: style)),
      if (help != null) ...[const SizedBox(width: 4), FormHelpButton(title: title, message: help!)],
    ],
  );
}

/// A settings list row whose title has an info button, as measured on iOS 26.
const double settingsHelpRowHeight = 61;

/// The leading width of a `Label` row: the symbol centers 28 pt in, the title starts at 56 pt.
const double settingsIconInset = 56;

/// `Label` in a settings list: a tinted symbol before the title, with a chevron for links.
/// Buttons tint their titles; navigation links keep them in the label color.
class SettingsLinkRow extends StatelessWidget {
  const SettingsLinkRow({
    super.key,
    required this.title,
    this.icon,
    this.symbol,
    this.onTap,
    this.tinted = false,
    this.chevron = true,
    this.value,
    this.destructive = false,
    this.help,
  });
  final String title;

  /// A help button after the title, as `SettingsInfoButton` beside a button.
  final String? help;
  final IconData? icon;
  final Widget Function(Color color)? symbol;
  final VoidCallback? onTap;
  final bool tinted;
  final bool chevron;
  final String? value;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final tint = destructive ? CupertinoColors.systemRed.resolveFrom(context) : TegnalColors.tint.resolveFrom(context);
    final enabled = onTap != null;
    final hasIcon = icon != null || symbol != null;
    final row = FormRow(
      onTap: onTap,
      minHeight: help == null ? 52 : settingsHelpRowHeight,
      separatorInset: hasIcon ? settingsIconInset : 16,
      child: Opacity(
        opacity: enabled ? 1 : 0.4,
        child: Row(
          children: [
            if (hasIcon) ...[
              SizedBox(
                width: 24,
                child: Center(child: symbol?.call(tint) ?? Icon(icon, size: 22, color: tint)),
              ),
              const SizedBox(width: 16),
            ],
            Expanded(
              child: help == null
                  ? Text(title, style: TegnalType.style(17, color: tinted || destructive ? tint : TegnalColors.label.resolveFrom(context)))
                  : SettingsTitle(
                      title,
                      help: help,
                      style: TegnalType.style(17, color: tinted || destructive ? tint : TegnalColors.label.resolveFrom(context)),
                    ),
            ),
            if (value != null) ...[
              Text(value!, style: TegnalType.style(17, color: TegnalColors.secondaryLabel.resolveFrom(context))),
              const SizedBox(width: 6),
            ],
            if (chevron) Icon(CupertinoIcons.chevron_right, size: 15, color: TegnalColors.tertiaryLabel.resolveFrom(context)),
          ],
        ),
      ),
    );
    return Semantics(button: enabled, child: row);
  }
}

/// `Toggle` with an optional help button, its switch at the trailing edge.
class SettingsToggleRow extends StatelessWidget {
  const SettingsToggleRow({super.key, required this.title, required this.value, required this.onChanged, this.help});
  final String title;
  final String? help;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) => FormRow(
    minHeight: help == null ? 52 : settingsHelpRowHeight,
    child: Row(
      children: [
        Expanded(child: SettingsTitle(title, help: help)),
        const SizedBox(width: 8),
        // Native switches sit 2 pt closer to the row's trailing edge than text does.
        Transform.translate(
          offset: const Offset(2, 0),
          child: TegnalSwitch(value: value, onChanged: onChanged),
        ),
      ],
    ),
  );
}

/// `Picker` in its menu style: the choice and a chevron pair open a pull-down menu.
/// A picker inside its own row (`.pickerStyle(.menu)` beside a label) shows the choice tinted.
class SettingsPickerRow<T> extends StatelessWidget {
  const SettingsPickerRow({
    super.key,
    required this.title,
    required this.options,
    required this.selected,
    required this.onSelected,
    this.help,
    this.tinted = false,
    this.enabled = true,
  });
  final String title;
  final String? help;
  final List<(T, String)> options;
  final T selected;
  final ValueChanged<T> onSelected;
  final bool tinted;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final color = tinted ? TegnalColors.tint.resolveFrom(context) : TegnalColors.secondaryLabel.resolveFrom(context);
    final current = options.where((option) => option.$1 == selected).firstOrNull?.$2 ?? '';
    return Builder(
      builder: (context) => FormRow(
        minHeight: help == null ? 52 : settingsHelpRowHeight,
        onTap: enabled
            ? () async {
                final value = await showPullDownMenu<T>(
                  context,
                  anchor: anchorRectOf(context),
                  items: [for (final (value, label) in options) PullDownMenuItem(value: value, title: label, checked: value == selected)],
                );
                if (value != null) onSelected(value);
              }
            : null,
        child: Opacity(
          opacity: enabled ? 1 : 0.4,
          child: Row(
            children: [
              Expanded(child: SettingsTitle(title, help: help)),
              const SizedBox(width: 8),
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.45),
                child: Text(
                  current,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: TegnalType.style(17, color: color),
                ),
              ),
              const SizedBox(width: 4),
              Icon(CupertinoIcons.chevron_up_chevron_down, size: 15, color: color),
            ],
          ),
        ),
      ),
    );
  }
}

/// `LabeledContent`: a title and its value in the secondary color.
class SettingsValueRow extends StatelessWidget {
  const SettingsValueRow({super.key, required this.title, required this.value, this.small = false});
  final String title;
  final String value;
  final bool small;

  @override
  Widget build(BuildContext context) {
    final size = small ? 13.0 : 17.0;
    return FormRow(
      child: Row(
        children: [
          Expanded(
            child: Text(title, style: TegnalType.style(size, color: TegnalColors.label.resolveFrom(context))),
          ),
          Text(value, style: TegnalType.style(size, color: TegnalColors.secondaryLabel.resolveFrom(context))),
        ],
      ),
    );
  }
}

/// A segmented picker under its title, as the column pickers lay out.
class SettingsSegmentedRow<T> extends StatelessWidget {
  const SettingsSegmentedRow({super.key, this.title, this.help, required this.options, required this.selected, required this.onSelected});
  final String? title;
  final String? help;
  final List<(T, String)> options;
  final T selected;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) => Padding(
    // Measured on iOS 26 lists: 14 pt around a lone picker, 19.5 / 17.5 pt around a titled one.
    padding: EdgeInsets.fromLTRB(16, title == null ? 14 : 19.5, 16, title == null ? 14 : 17.5),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (title != null) ...[
          SettingsTitle(
            title!,
            help: help,
            style: TegnalType.style(15, color: TegnalColors.label.resolveFrom(context)),
          ),
          const SizedBox(height: 8),
        ],
        TegnalSegmented<T>(options: options, selected: selected, onSelected: onSelected),
      ],
    ),
  );
}
