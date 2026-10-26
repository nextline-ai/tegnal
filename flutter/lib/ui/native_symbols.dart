import 'package:material_ui/material_ui.dart';

/// Shared source selector symbol from the official Material icon set.
class TegnalServerIcon extends StatelessWidget {
  const TegnalServerIcon({
    super.key,
    this.size = 30,
    this.color,
    this.semanticLabel,
  });
  final double size;
  final Color? color;
  final String? semanticLabel;
  @override
  Widget build(BuildContext context) => Icon(
    Icons.dns_rounded,
    size: size,
    color: color,
    semanticLabel: semanticLabel,
  );
}
