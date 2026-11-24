import 'dart:math' as math;

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/foundation.dart';

import '../../core/support/l10n.dart';
import '../design/tegnal_theme.dart';
import '../works/artwork_grid.dart';

/// `AuthorRuns`: a comics feed sometimes lists many works by one artist at once, which pushes
/// everything else down. Three or more works by one artist, each within a few works of the one
/// before, are shown as one row with the artist's name instead of a card each.
abstract final class AuthorRuns {
  /// Works by one artist that make a run: three, and always more than a row holds, so a run
  /// never replaces what would fit in a single row anyway (four in three columns).
  static int minimum(int columns) => math.max(3, columns + 1);

  /// Other works allowed between two of the artist's works in one run.
  static const allowedGap = 5;

  /// Runs among works whose artists are known; null is a work not loaded yet, which never joins
  /// a run but counts as a work between two of one. A work by several artists can join a run for
  /// any of them, and joins one run at most: the longer one wins, then the earlier.
  static List<AuthorRun> runs(List<List<String>?> artists, {int columns = 2}) {
    final least = minimum(columns);
    final positions = <String, List<int>>{};
    final names = <String, String>{};
    for (var index = 0; index < artists.length; index++) {
      final seen = <String>{};
      for (final name in artists[index] ?? const <String>[]) {
        final trimmed = name.trim();
        final key = trimmed.toLowerCase();
        if (key.isEmpty || !seen.add(key)) continue;
        positions.putIfAbsent(key, () => []).add(index);
        names.putIfAbsent(key, () => trimmed);
      }
    }
    final candidates = <(String, List<int>)>[
      for (final entry in positions.entries)
        for (final chain in _chains(entry.value, least)) (entry.key, chain),
    ];
    candidates.sort((first, second) {
      if (first.$2.length != second.$2.length) return second.$2.length.compareTo(first.$2.length);
      if (first.$2.first != second.$2.first) return first.$2.first.compareTo(second.$2.first);
      return first.$1.compareTo(second.$1);
    });
    final taken = <int>{};
    final accepted = <AuthorRun>[];
    for (final (key, members) in candidates) {
      for (final chain in _chains([
        for (final member in members)
          if (!taken.contains(member)) member,
      ], least)) {
        taken.addAll(chain);
        accepted.add(AuthorRun(names[key] ?? key, chain));
      }
    }
    accepted.sort((first, second) => first.members.first.compareTo(second.members.first));
    return accepted;
  }

  /// Ascending positions split where too many works lie between two, keeping long enough parts.
  static List<List<int>> _chains(List<int> list, int minimum) {
    final result = <List<int>>[];
    var current = <int>[];
    for (final position in list) {
      if (current.isNotEmpty && position - current.last > allowedGap + 1) {
        if (current.length >= minimum) result.add(current);
        current = [];
      }
      current.add(position);
    }
    if (current.length >= minimum) result.add(current);
    return result;
  }

  /// Lines for [count] works in [columns] columns. A run takes the place of its first work; one
  /// that starts partway through a row comes after that row, so no row is left short.
  static List<AuthorRunLine> lines(int count, List<AuthorRun> runs, int columns) {
    final perRow = math.max(1, columns);
    final starts = {for (final run in runs) run.members.first: run};
    final grouped = {for (final run in runs) ...run.members};
    final lines = <AuthorRunLine>[];
    var row = <int>[];
    final waiting = <AuthorRun>[];
    for (var index = 0; index < count; index++) {
      final run = starts[index];
      if (run != null) {
        if (row.isEmpty) {
          lines.add(AuthorRunLine.run(run));
        } else {
          waiting.add(run);
        }
        continue;
      }
      if (grouped.contains(index)) continue;
      row.add(index);
      if (row.length == perRow) {
        lines.add(AuthorRunLine.works(row));
        row = [];
        lines.addAll(waiting.map(AuthorRunLine.run));
        waiting.clear();
      }
    }
    if (row.isNotEmpty) lines.add(AuthorRunLine.works(row));
    lines.addAll(waiting.map(AuthorRunLine.run));
    return lines;
  }
}

/// One artist's works close together, as positions in the list.
@immutable
class AuthorRun {
  const AuthorRun(this.artist, this.members);
  final String artist;
  final List<int> members;

  @override
  bool operator ==(Object other) => other is AuthorRun && other.artist == artist && listEquals(other.members, members);
  @override
  int get hashCode => Object.hash(artist, Object.hashAll(members));
  @override
  String toString() => 'AuthorRun($artist, $members)';
}

/// A line of the feed: a row of cards, or one artist's run.
@immutable
class AuthorRunLine {
  const AuthorRunLine.works(this.positions) : run = null;
  AuthorRunLine.run(AuthorRun this.run) : positions = run.members;

  /// Every position the line shows.
  final List<int> positions;
  final AuthorRun? run;

  /// The first position the line shows, which names it in the list.
  int get first => positions.first;

  @override
  bool operator ==(Object other) => other is AuthorRunLine && other.run == run && listEquals(other.positions, positions);
  @override
  int get hashCode => Object.hash(run, Object.hashAll(positions));
  @override
  String toString() => run == null ? 'works($positions)' : 'run($run)';
}

/// `AuthorRunCard`: one artist's run, their name (which opens their works) over a strip of the
/// works' cards.
class AuthorRunCard extends StatelessWidget {
  const AuthorRunCard({super.key, required this.artist, required this.count, required this.style, required this.openArtist, required this.card});

  final String artist;
  final int count;
  final ArtworkCellStyle style;
  final VoidCallback? openArtist;

  /// The card of the run's [index]th work, laid out with the given strip style.
  final Widget Function(int index, ArtworkCellStyle style) card;

  @override
  Widget build(BuildContext context) {
    // Strip cards are the grid's cards, sized and lettered alike; the header names the artist,
    // so each card repeating it is noise.
    final strip = style.copyWith(showsArtists: false);
    final gap = style.spacing;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: ShapeDecoration(
        color: TegnalColors.secondaryBackground.resolveFrom(context),
        shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(math.max(12, style.radius(14)))),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            button: true,
            hint: L10n.text('Shows all works by this artist'),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: openArtist,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    Icon(CupertinoIcons.rectangle_stack_person_crop, size: 20, color: TegnalColors.tint.resolveFrom(context)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TegnalType.style(15, weight: FontWeight.w600, color: TegnalColors.label.resolveFrom(context)),
                          ),
                          const SizedBox(height: 1),
                          Text(
                            L10n.text('%@ works in a row', ['$count']),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TegnalType.style(12, color: TegnalColors.secondaryLabel.resolveFrom(context)),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(CupertinoIcons.chevron_right, size: 13, color: TegnalColors.tertiaryLabel.resolveFrom(context)),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var index = 0; index < count; index++) ...[if (index > 0) SizedBox(width: gap), SizedBox(width: strip.width, child: card(index, strip))],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
