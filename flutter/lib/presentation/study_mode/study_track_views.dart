import 'package:cupertino_ui/cupertino_ui.dart';

import '../../core/addons/addon_store.dart';
import '../../core/study/study_models.dart';
import '../../core/study/study_path.dart';
import '../../core/support/l10n.dart';
import 'study_kit.dart';
import 'study_mode_model.dart';
import 'study_reactions.dart';

// The tracks that add-ons bring to learning mode: the chooser above the path, the track's own heading, and the page
// that marks one finished. Ported from `StudyTrackViews.swift`.

/// `StudyTrackPicker`: chooses between the main path and the tracks that add-ons bring. Shown only while a track is on.
class StudyTrackPicker extends StatelessWidget {
  const StudyTrackPicker({super.key, required this.model});
  final StudyModeModel model;

  @override
  Widget build(BuildContext context) {
    final theme = StudyTheme.of(context);
    return SingleChildScrollView(
      key: const Key('study.tracks'),
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.only(left: 18, right: 18, bottom: 6),
      child: Row(
        children: [
          _chip(id: null, title: L10n.text('Main Track'), symbol: 'map.fill', color: theme.primary, done: false),
          for (final track in model.tracks) ...[
            const SizedBox(width: 8),
            _chip(id: track.id, title: track.title.resolved(), symbol: track.symbol, color: studyHex(track.color), done: track.complete(model.records)),
          ],
        ],
      ),
    );
  }

  Widget _chip({required String? id, required String title, required String symbol, required Color color, required bool done}) {
    final chosen = model.trackID == id;
    return Semantics(
      key: Key('study.track.${id ?? 'main'}'),
      container: true,
      selected: chosen,
      value: done ? L10n.text('Track Completed') : null,
      child: StudyPressButton(
        color: color,
        radius: 16,
        depth: 4,
        outlined: !chosen,
        onPressed: () {
          StudySound.tap.play();
          model.trackID = id;
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              StudyIcon(done ? 'checkmark.seal.fill' : symbol, size: 14),
              const SizedBox(width: 6),
              Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: StudyTheme.body(14, StudyTheme.heavy)),
            ],
          ),
        ),
      ),
    );
  }
}

/// `StudyTrackHeader`: what a track is, how far along it is, and its seal once every lesson is done.
class StudyTrackHeader extends StatelessWidget {
  const StudyTrackHeader({super.key, required this.track, required this.records});
  final StudyTrack track;
  final Map<String, StudyLessonRecord> records;

  @override
  Widget build(BuildContext context) {
    final theme = StudyTheme.of(context);
    final lessons = track.path.lessons;
    final done = lessons.where((lesson) => records[lesson.id] != null).length;
    final color = studyHex(track.color);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18),
      child: Semantics(
        key: const Key('study.track.header'),
        container: true,
        child: MergeSemantics(
          child: StudyCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    StudyIcon(track.symbol, size: 22, color: color),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(studyWords(track.title.resolved()), style: StudyTheme.title(20).copyWith(color: theme.ink)),
                          const SizedBox(height: 2),
                          Text(L10n.text('Add-on Track'), style: StudyTheme.body(12, StudyTheme.bold).copyWith(color: theme.muted)),
                        ],
                      ),
                    ),
                    if (done == lessons.length) ...[
                      const SizedBox(width: 10),
                      Row(
                        key: const Key('study.track.completed'),
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          StudyIcon('checkmark.seal.fill', size: 13, color: theme.good),
                          const SizedBox(width: 6),
                          Text(L10n.text('Completed'), style: StudyTheme.body(13, StudyTheme.heavy).copyWith(color: theme.good)),
                        ],
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 8),
                Text(studyWords(track.summary.resolved()), style: StudyTheme.body(14, StudyTheme.medium).copyWith(color: theme.muted)),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: StudyBar(value: lessons.isEmpty ? 0 : done / lessons.length, color: color, height: 10),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '$done/${lessons.length}',
                      style: StudyTheme.body(13, StudyTheme.heavy).copyWith(color: theme.muted, fontFeatures: const [FontFeature.tabularFigures()]),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// `StudyTrackCertificate`: the page that marks a track finished: every one of its lessons done.
class StudyTrackCertificate extends StatefulWidget {
  const StudyTrackCertificate({super.key, required this.track, required this.close});
  final StudyTrack track;
  final VoidCallback close;

  @override
  State<StudyTrackCertificate> createState() => _StudyTrackCertificateState();
}

class _StudyTrackCertificateState extends State<StudyTrackCertificate> with SingleTickerProviderStateMixin {
  /// `.spring(duration: 0.6, bounce: 0.45)`: the seal landing.
  static final _land = StudySpring(0.6, 0.45);
  late final AnimationController _shown = AnimationController(vsync: this, duration: _land.settle);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      StudySound.complete.play();
      if (MediaQuery.disableAnimationsOf(context)) {
        _shown.value = 1;
      } else {
        _shown.forward();
      }
    });
  }

  @override
  void dispose() {
    _shown.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = StudyTheme.of(context);
    final color = studyHex(widget.track.color);
    const gap = SizedBox(height: 22);
    return ColoredBox(
      color: theme.background,
      child: SafeArea(
        child: DefaultTextStyle(
          style: StudyTheme.body().copyWith(color: theme.ink),
          child: Column(
            children: [
              const Spacer(),
              gap,
              SizedBox.square(
                dimension: 190,
                child: Stack(
                  clipBehavior: Clip.none,
                  alignment: Alignment.center,
                  children: [
                    DecoratedBox(
                      decoration: ShapeDecoration(color: color.withValues(alpha: 0.16), shape: const CircleBorder()),
                      child: const SizedBox.square(dimension: 190),
                    ),
                    AnimatedBuilder(
                      animation: _shown,
                      builder: (context, child) {
                        final t = _land.transform(_shown.value);
                        return Opacity(
                          opacity: t.clamp(0.0, 1.0),
                          child: Transform.scale(scale: 0.3 + 0.7 * t, child: child),
                        );
                      },
                      child: StudyIcon('checkmark.seal.fill', size: 96, color: color),
                    ),
                    const Positioned.fill(child: StudyBurst(trigger: 1, count: 30, reach: 150, onAppear: true)),
                  ],
                ),
              ),
              gap,
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 28),
                child: Column(
                  children: [
                    Text(
                      L10n.text('Track Completed'),
                      textAlign: TextAlign.center,
                      style: StudyTheme.body(16, StudyTheme.heavy).copyWith(color: color),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      studyWords(widget.track.title.resolved()),
                      key: const Key('study.track.certificate'),
                      textAlign: TextAlign.center,
                      style: StudyTheme.title(30).copyWith(color: theme.ink),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      L10n.text('You finished every lesson of this track.'),
                      textAlign: TextAlign.center,
                      style: StudyTheme.body(16, StudyTheme.medium).copyWith(color: theme.muted),
                    ),
                  ],
                ),
              ),
              gap,
              const Spacer(),
              gap,
              Padding(
                padding: const EdgeInsets.only(left: 22, right: 22, bottom: 16),
                child: StudyMainButton(key: const Key('study.done'), title: L10n.text('Continue'), color: color, onPressed: widget.close),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
