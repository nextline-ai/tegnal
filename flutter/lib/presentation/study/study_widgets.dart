import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:cupertino_ui/cupertino_ui.dart';

import '../../core/booru/booru_store.dart';
import '../../core/study/study_models.dart';
import '../../core/study/study_store.dart';
import '../../core/support/l10n.dart';
import '../design/grouped_form.dart';
import '../design/system_colors.dart';
import '../design/tegnal_theme.dart';
import '../settings/settings_page.dart';
import '../settings/settings_rows.dart';

/// What the study screens show, read again whenever an answer may have changed it (`StudyBoard`).
class StudyBoard extends ChangeNotifier {
  StudyBoard({StudyCurriculum? curriculum}) : curriculum = curriculum ?? StudyCurriculum.bundled;
  final StudyCurriculum curriculum;
  Map<String, StudyProgress> progress = {};
  StudySummary summary = const StudySummary();

  void reload(BooruStore store) {
    final study = store.studyStore;
    try {
      progress = study.progress();
    } on Object {
      progress = {};
    }
    List<StudyDay> days;
    try {
      days = study.days();
    } on Object {
      days = [];
    }
    summary = StudySummary.of(curriculum: curriculum, progress: progress, days: days);
    notifyListeners();
  }
}

/// `StudyStyle`: the accent and the compact count.
abstract final class StudyStyle {
  /// `Color.indigo`.
  static Color accent(BuildContext context) => SystemColors.indigo.resolveFrom(context);

  /// `tertiarySystemFill`: the empty part of a bar, the ring's track and the chips.
  static const tertiaryFill = CupertinoDynamicColor.withBrightness(color: Color(0x1F767680), darkColor: Color(0x3D767680));

  /// `.number.notation(.compactName)` in the app language: 362K, 1.2M, or 36만 and 36万.
  static String count(int value, {String? language}) {
    final units = switch (language ?? L10n.language) {
      'ko' => const [(1e8, '억'), (1e4, '만'), (1e3, '천')],
      'ja' => const [(1e8, '億'), (1e4, '万')],
      _ => const [(1e12, 'T'), (1e9, 'B'), (1e6, 'M'), (1e3, 'K')],
    };
    for (final (size, suffix) in units) {
      if (value < size) continue;
      final scaled = value / size;
      final text = scaled < 10 ? _oneDecimal(scaled) : scaled.round().toString();
      // 9.96K reads as 10K, not 10.0K.
      return '$text$suffix';
    }
    return '$value';
  }

  static String _oneDecimal(double value) {
    final rounded = (value * 10).round() / 10;
    return rounded == rounded.roundToDouble() ? rounded.round().toString() : rounded.toStringAsFixed(1);
  }
}

/// The CupertinoIcons that stand in for the SF Symbols the iOS study screens use.
abstract final class StudySymbols {
  static const graduationCap = CupertinoIcons.book_fill;
  static const play = CupertinoIcons.play_fill;
  static const review = CupertinoIcons.arrow_2_circlepath;
  static const answered = CupertinoIcons.checkmark_circle;
  static const streak = CupertinoIcons.flame;
  static const posts = CupertinoIcons.photo_on_rectangle;
  static const otherName = CupertinoIcons.chat_bubble_text;
  static const prompt = CupertinoIcons.text_cursor;
  static const practice = CupertinoIcons.play_circle;
  static const search = CupertinoIcons.search;
  static const copy = CupertinoIcons.doc_on_doc;
  static const copied = CupertinoIcons.checkmark;
  static const info = CupertinoIcons.info_circle;
  static const right = CupertinoIcons.checkmark_circle_fill;
  static const wrong = CupertinoIcons.xmark_circle_fill;
  static const empty = CupertinoIcons.checkmark_seal;
  static const picture = CupertinoIcons.photo_fill;
  static const reset = CupertinoIcons.arrow_counterclockwise;
  static const guide = CupertinoIcons.book;
  static const streakFilled = CupertinoIcons.flame_fill;
  static const learnedFilled = CupertinoIcons.checkmark_seal_fill;
  static const todayFilled = CupertinoIcons.bolt_fill;

  /// `StudyLesson.symbol`, which names SF Symbols, as an icon.
  static IconData lesson(String symbol) => switch (symbol) {
    'text.alignleft' => CupertinoIcons.text_alignleft,
    'curlybraces' => CupertinoIcons.chevron_left_slash_chevron_right,
    'parentheses' => CupertinoIcons.number,
    'sparkles' => CupertinoIcons.sparkles,
    'minus.circle' => CupertinoIcons.minus_circle,
    'person.2' => CupertinoIcons.person_2,
    'textformat' => CupertinoIcons.textformat,
    'slider.horizontal.3' => CupertinoIcons.slider_horizontal_3,
    'lightbulb' => CupertinoIcons.lightbulb,
    _ => CupertinoIcons.book,
  };

  /// `StudyUnit.symbol`, which names SF Symbols, as an icon.
  static IconData unit(String symbol) => switch (symbol) {
    'person.2' => CupertinoIcons.person_2,
    'crop' => CupertinoIcons.crop,
    'camera' => CupertinoIcons.camera,
    'figure.stand' => CupertinoIcons.person_alt,
    'face.smiling' => CupertinoIcons.smiley,
    'comb' => CupertinoIcons.scissors,
    'eye' => CupertinoIcons.eye,
    'pawprint' => CupertinoIcons.paw,
    'tshirt' => CupertinoIcons.bag,
    'shoe' => CupertinoIcons.hare,
    'eyeglasses' => CupertinoIcons.eyeglasses,
    'mountain.2' => CupertinoIcons.photo,
    'sun.max' => CupertinoIcons.sun_max,
    'paintbrush.pointed' => CupertinoIcons.paintbrush,
    'doc.text' => CupertinoIcons.doc_text,
    _ => CupertinoIcons.tag,
  };
}

/// Where study pages are shown. Inside a post's details sheet they take the sheet's look.
class StudyPresentation extends InheritedWidget {
  const StudyPresentation({super.key, required this.sheet, required super.child});
  final bool sheet;

  static bool sheetOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<StudyPresentation>()?.sheet ?? false;

  /// The color of rows: on the screen itself, or in a sheet.
  static Color rowColor(BuildContext context) => (sheetOf(context) ? FormColors.row : FormColors.listRow).resolveFrom(context);

  @override
  bool updateShouldNotify(StudyPresentation old) => old.sheet != sheet;
}

/// A pushed study page: an inline title over an inset-grouped list, as the app's other pushed pages.
class StudyPage extends StatelessWidget {
  const StudyPage({super.key, required this.title, required this.children, this.trailing});
  final String title;
  final List<Widget> children;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => SettingsPage(title: title, sheet: StudyPresentation.sheetOf(context), trailing: trailing, children: children);
}

/// A section break, as between the app's other grouped sections.
const studySectionGap = settingsSectionGap;

Future<T?> pushStudy<T>(BuildContext context, WidgetBuilder builder) => Navigator.of(context).push<T>(CupertinoPageRoute<T>(builder: builder));

/// Text that can be selected and copied.
class StudySelectable extends StatelessWidget {
  const StudySelectable({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => SelectableRegion(
    selectionControls: cupertinoTextSelectionHandleControls,
    contextMenuBuilder: (context, state) =>
        CupertinoAdaptiveTextSelectionToolbar.buttonItems(anchors: state.contextMenuAnchors, buttonItems: state.contextMenuButtonItems),
    child: child,
  );
}

/// `StudyMastery`: one bar for each step up to "learned"; accent while learning, green once learned.
class StudyMastery extends StatelessWidget {
  const StudyMastery({super.key, required this.progress});
  final StudyProgress? progress;

  @override
  Widget build(BuildContext context) {
    final step = math.min(progress?.step ?? 0, StudyProgress.learnedStep);
    final filled = step >= StudyProgress.learnedStep ? SystemColors.green.resolveFrom(context) : StudyStyle.accent(context);
    final empty = StudyStyle.tertiaryFill.resolveFrom(context);
    return Semantics(
      label: L10n.text(
        progress?.isLearned == true
            ? 'Learned'
            : progress?.isNew == false
            ? 'Learning'
            : 'Not started',
      ),
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var index = 0; index < StudyProgress.learnedStep; index++) ...[
            if (index > 0) const SizedBox(width: 2),
            Container(
              width: 5,
              height: 12,
              decoration: ShapeDecoration(color: index < step ? filled : empty, shape: const StadiumBorder()),
            ),
          ],
        ],
      ),
    );
  }
}

/// `StudyBadge`: a small capsule with a symbol and a short text.
class StudyBadge extends StatelessWidget {
  const StudyBadge({super.key, required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: ShapeDecoration(color: StudyStyle.tertiaryFill.resolveFrom(context), shape: const StadiumBorder()),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: secondary),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TegnalType.style(12, color: secondary),
            ),
          ),
        ],
      ),
    );
  }
}

/// `.borderedProminent` and `.bordered` in the study accent.
class StudyButton extends StatelessWidget {
  const StudyButton({super.key, required this.title, required this.onPressed, this.icon, this.prominent = false, this.plain = false, this.expand = true});
  final String title;
  final IconData? icon;
  final bool prominent;

  /// A borderless button: accent text and icon only.
  final bool plain;
  final bool expand;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final accent = StudyStyle.accent(context);
    final foreground = prominent ? const Color(0xFFFFFFFF) : accent;
    return Semantics(
      button: true,
      enabled: onPressed != null,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: Container(
          height: 50,
          padding: EdgeInsets.symmetric(horizontal: plain ? 0 : 16),
          decoration: plain ? null : ShapeDecoration(color: prominent ? accent : accent.withValues(alpha: 0.15), shape: const StadiumBorder()),
          child: Row(
            mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (icon != null) ...[Icon(icon, size: 19, color: foreground), const SizedBox(width: 6)],
              Flexible(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TegnalType.style(17, weight: prominent ? FontWeight.w600 : FontWeight.w400, color: foreground),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A form row led by an accent symbol. Buttons tint their titles; links keep them in the label color.
class StudyActionRow extends StatelessWidget implements FormSeparatorInset {
  const StudyActionRow({super.key, required this.title, required this.icon, this.onTap, this.tinted = true, this.chevron = false});
  final String title;
  final IconData icon;
  final VoidCallback? onTap;
  final bool tinted;
  final bool chevron;

  @override
  double get separatorInset => settingsIconInset;

  @override
  Widget build(BuildContext context) {
    final accent = StudyStyle.accent(context);
    return Semantics(
      button: true,
      child: FormRow(
        onTap: onTap,
        separatorInset: separatorInset,
        child: Row(
          children: [
            SizedBox(
              width: 24,
              child: Center(child: Icon(icon, size: 22, color: accent)),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Text(title, style: TegnalType.style(17, color: tinted ? accent : TegnalColors.label.resolveFrom(context))),
            ),
            if (chevron) Icon(CupertinoIcons.chevron_right, size: 15, color: TegnalColors.tertiaryLabel.resolveFrom(context)),
          ],
        ),
      ),
    );
  }
}

/// `StudyTagRow` in a form row: the tag's words, its name in the app language, a two-line note,
/// its mastery and, once read, how many posts it has.
class StudyTagRow extends StatelessWidget {
  const StudyTagRow({super.key, required this.tag, required this.progress, this.count, this.onTap});
  final StudyTag tag;
  final StudyProgress? progress;
  final int? count;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    return FormRow(
      onTap: onTap,
      child: Padding(
        // The row is taller than the app's other two-line rows by iOS's 2 pt, plus the form row's own padding.
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Flexible(
                        child: Text(
                          tag.english,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TegnalType.style(17, weight: FontWeight.w600, color: TegnalColors.label.resolveFrom(context)),
                        ),
                      ),
                      if (L10n.language != 'en') ...[
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            tag.title(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TegnalType.style(15, color: secondary),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    tag.note.resolved(),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TegnalType.style(13, color: secondary),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                StudyMastery(progress: progress),
                if (count != null) ...[
                  const SizedBox(height: 5),
                  Text(
                    StudyStyle.count(count!),
                    style: TegnalType.style(
                      11,
                      color: TegnalColors.tertiaryLabel.resolveFrom(context),
                    ).copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
                  ),
                ],
              ],
            ),
            if (onTap != null) ...[
              const SizedBox(width: 10),
              Icon(CupertinoIcons.chevron_right, size: 15, color: TegnalColors.tertiaryLabel.resolveFrom(context)),
            ],
          ],
        ),
      ),
    );
  }
}

/// The accent tile that leads a study row: a symbol on a soft accent square.
class StudyTile extends StatelessWidget {
  const StudyTile({super.key, required this.icon, required this.width, required this.height, required this.radius, this.alpha = 0.1, this.size = 20});
  final IconData icon;
  final double width;
  final double height;
  final double radius;
  final double alpha;
  final double size;

  @override
  Widget build(BuildContext context) {
    final accent = StudyStyle.accent(context);
    return Container(
      width: width,
      height: height,
      decoration: ShapeDecoration(
        color: accent.withValues(alpha: alpha),
        shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(radius)),
      ),
      child: Icon(icon, size: size, color: accent),
    );
  }
}

extension StudyDigits on TextStyle {
  /// `.monospacedDigit()`.
  TextStyle get digits => copyWith(fontFeatures: const [FontFeature.tabularFigures()]);
}

/// `.safeAreaInset(edge: .bottom)` with `.bar`: buttons over a blurred strip, at most 640 pt wide.
class StudyBottomBar extends StatelessWidget {
  const StudyBottomBar({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => ClipRect(
    child: BackdropFilter(
      filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
      child: ColoredBox(
        color: FormColors.listBackground.resolveFrom(context).withValues(alpha: 0.86),
        child: Padding(
          padding: EdgeInsets.fromLTRB(20, 12, 20, 12 + MediaQuery.paddingOf(context).bottom),
          child: Center(
            heightFactor: 1,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: Row(children: children),
            ),
          ),
        ),
      ),
    ),
  );
}

/// `linkRow`: a tile, a title and a short line under it, as the rows of units and lessons.
class StudyLinkRow extends StatelessWidget {
  const StudyLinkRow({super.key, required this.icon, required this.title, required this.detail, this.onTap, this.trailing});
  final IconData icon;
  final String title;
  final String detail;
  final VoidCallback? onTap;

  /// Shown before the chevron, such as the check mark of a finished lesson.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => FormRow(
    // The line under a row starts where its title does.
    separatorInset: 66,
    // As the rows of units: about 14 pt above and below the tile and text.
    minHeight: 71,
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          StudyTile(icon: icon, width: 36, height: 36, radius: 9, size: 19),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TegnalType.style(17, weight: FontWeight.w500, color: TegnalColors.label.resolveFrom(context)),
                ),
                const SizedBox(height: 3),
                Text(
                  detail,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TegnalType.style(12, color: TegnalColors.secondaryLabel.resolveFrom(context)),
                ),
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 8), trailing!],
          const SizedBox(width: 10),
          Icon(CupertinoIcons.chevron_right, size: 15, color: TegnalColors.tertiaryLabel.resolveFrom(context)),
        ],
      ),
    ),
  );
}
