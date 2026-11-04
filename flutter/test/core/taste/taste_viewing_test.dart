import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/taste/taste_viewing.dart';

void main() {
  final start = DateTime(2026, 11, 4, 12);
  DateTime at(double seconds) => start.add(Duration(milliseconds: (seconds * 1000).round()));

  test('leaving at once is not viewing time', () {
    final session = TasteViewingSession()..resume(at(0));
    expect(session.finish(at(2)), isNull);
  });

  test('paused time is not counted and each idle stretch is capped', () {
    final session = TasteViewingSession()..resume(at(0));
    session.pause(at(10));
    session.resume(at(100));
    final dwell = session.finish(at(100 + 500));
    expect(dwell?.seconds, 10 + TasteViewingSession.idleLimit);
    expect(dwell?.pages, 1);
  });

  test('showing pages restarts the idle window and records the last page', () {
    final session = TasteViewingSession()..resume(at(0));
    session.show(1, date: at(100));
    session.show(2, isLast: true, date: at(200));
    final dwell = session.finish(at(250));
    expect(dwell?.seconds, 250);
    expect(dwell?.pages, 2);
    expect(dwell?.finished, isTrue);
  });

  test('finishing resets the session', () {
    final session = TasteViewingSession()..resume(at(0));
    session.finish(at(30));
    session.resume(at(40));
    expect(session.finish(at(41)), isNull);
  });
}
