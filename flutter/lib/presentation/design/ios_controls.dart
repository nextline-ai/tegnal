import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/services.dart';

import 'system_colors.dart';
import 'tegnal_theme.dart';

/// iOS 26 control colors, measured from the native forms in dark appearance.
abstract final class ControlColors {
  static const switchOffTrack = CupertinoDynamicColor.withBrightness(color: Color(0xFFE9E9EB), darkColor: Color(0xFF656569));
  static const sliderTrack = CupertinoDynamicColor.withBrightness(color: Color(0x33787880), darkColor: Color(0x47787880));
}

/// The iOS 26 `Toggle`: a 63 × 28 pt track with a 37 pt capsule knob, green when on.
/// The Cupertino switch still draws the older round knob, so it is drawn here.
class TegnalSwitch extends StatelessWidget {
  const TegnalSwitch({super.key, required this.value, required this.onChanged});
  final bool value;
  final ValueChanged<bool>? onChanged;

  static const Size size = Size(63, 28);
  static const Size knob = Size(37, 23);

  @override
  Widget build(BuildContext context) {
    final enabled = onChanged != null;
    final track = value ? SystemColors.green.resolveFrom(context) : ControlColors.switchOffTrack.resolveFrom(context);
    return Semantics(
      toggled: value,
      enabled: enabled,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled
            ? () {
                HapticFeedback.lightImpact();
                onChanged!(!value);
              }
            : null,
        onHorizontalDragEnd: enabled
            ? (details) {
                final velocity = details.primaryVelocity ?? 0;
                if (velocity != 0 && (velocity > 0) != value) onChanged!(velocity > 0);
              }
            : null,
        child: Opacity(
          opacity: enabled ? 1 : 0.5,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            width: size.width,
            height: size.height,
            decoration: ShapeDecoration(color: track, shape: const StadiumBorder()),
            child: AnimatedAlign(
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOutBack,
              alignment: value ? Alignment.centerRight : Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Container(
                  width: knob.width,
                  height: knob.height,
                  decoration: const ShapeDecoration(
                    color: Color(0xFFFFFFFF),
                    shape: StadiumBorder(),
                    shadows: [BoxShadow(color: Color(0x26000000), blurRadius: 4, offset: Offset(0, 1.5))],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The iOS 26 `Slider`: a 6 pt track filled with the tint up to a 37 × 24 pt capsule knob.
class TegnalSlider extends StatelessWidget {
  const TegnalSlider({super.key, required this.value, required this.onChanged, this.min = 0, this.max = 1, this.label});
  final double value;
  final double min;
  final double max;
  final ValueChanged<double>? onChanged;
  final String? label;

  static const Size knob = Size(37, 24);
  static const double trackHeight = 6;

  double get _fraction => max <= min ? 0 : ((value - min) / (max - min)).clamp(0, 1);

  void _update(double dx, double width) {
    final fraction = ((dx - knob.width / 2) / (width - knob.width)).clamp(0.0, 1.0);
    onChanged?.call(min + fraction * (max - min));
  }

  @override
  Widget build(BuildContext context) {
    final tint = TegnalColors.tint.resolveFrom(context);
    final track = ControlColors.sliderTrack.resolveFrom(context);
    return Semantics(
      label: label,
      slider: true,
      value: '${(_fraction * 100).round()}%',
      onIncrease: onChanged == null ? null : () => onChanged!((value + (max - min) / 10).clamp(min, max)),
      onDecrease: onChanged == null ? null : () => onChanged!((value - (max - min) / 10).clamp(min, max)),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final knobLeft = _fraction * (width - knob.width);
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (details) => _update(details.localPosition.dx, width),
            onHorizontalDragUpdate: (details) => _update(details.localPosition.dx, width),
            child: SizedBox(
              height: 44,
              child: Stack(
                alignment: Alignment.centerLeft,
                children: [
                  Container(
                    height: trackHeight,
                    decoration: ShapeDecoration(color: track, shape: const StadiumBorder()),
                  ),
                  Container(
                    width: knobLeft + knob.width / 2,
                    height: trackHeight,
                    decoration: ShapeDecoration(color: tint, shape: const StadiumBorder()),
                  ),
                  Positioned(
                    left: knobLeft,
                    child: Container(
                      width: knob.width,
                      height: knob.height,
                      decoration: const ShapeDecoration(
                        color: Color(0xFFFFFFFF),
                        shape: StadiumBorder(),
                        shadows: [BoxShadow(color: Color(0x26000000), blurRadius: 6, offset: Offset(0, 2))],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// The iOS 26 segmented `Picker`: a 32 pt capsule track with a 2 pt inset pill under the choice.
class TegnalSegmented<T> extends StatelessWidget {
  const TegnalSegmented({super.key, required this.options, required this.selected, required this.onSelected});
  final List<(T, String)> options;
  final T selected;
  final ValueChanged<T> onSelected;

  static const track = CupertinoDynamicColor.withBrightness(color: Color(0xFFE6E6EB), darkColor: Color(0xFF313136));
  static const pill = CupertinoDynamicColor.withBrightness(color: Color(0xFFFFFFFF), darkColor: Color(0xFF69696F));

  @override
  Widget build(BuildContext context) {
    final label = TegnalColors.label.resolveFrom(context);
    final index = options.indexWhere((option) => option.$1 == selected);
    return Container(
      height: 32,
      padding: const EdgeInsets.all(2),
      decoration: ShapeDecoration(color: track.resolveFrom(context), shape: const StadiumBorder()),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth / options.length;
          return Stack(
            children: [
              if (index >= 0)
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 260),
                  curve: Curves.easeOutCubic,
                  left: width * index,
                  top: 0,
                  bottom: 0,
                  width: width,
                  child: Container(
                    decoration: ShapeDecoration(
                      color: pill.resolveFrom(context),
                      shape: const StadiumBorder(),
                      shadows: CupertinoTheme.brightnessOf(context) == Brightness.dark
                          ? const []
                          : const [BoxShadow(color: Color(0x1F000000), blurRadius: 6, offset: Offset(0, 2))],
                    ),
                  ),
                ),
              Row(
                children: [
                  for (final (value, title) in options)
                    Expanded(
                      child: Semantics(
                        button: true,
                        selected: value == selected,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () {
                            if (value == selected) return;
                            HapticFeedback.selectionClick();
                            onSelected(value);
                          },
                          child: Center(
                            child: Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TegnalType.style(14, weight: value == selected ? FontWeight.w600 : FontWeight.w400, color: label),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}
