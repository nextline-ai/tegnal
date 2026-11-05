// `ReadingQueueTests` from native-ios/TEGNALTests/ReaderUXTests.swift.

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/content/reading_queue.dart';
import 'package:tegnal/core/support/preferences.dart';

void main() {
  late Directory covers;
  setUp(() => covers = Directory.systemTemp.createTempSync('reading-queue'));
  tearDown(() {
    if (covers.existsSync()) covers.deleteSync(recursive: true);
  });

  ReadingQueueItem item(int id) => ReadingQueueItem(id: id, title: 'Work $id', artists: '', details: '');

  test('works wait in order once and leave when read', () async {
    final preferences = MemoryPreferences();
    final queue = ReadingQueue(preferences, covers: covers);
    expect(queue.add(item(1), cover: Future.value(Uint8List.fromList([1, 2, 3]))), isTrue);
    expect(queue.add(item(2)), isTrue);
    expect(queue.add(item(1)), isFalse, reason: 'A waiting work keeps its place');
    expect(queue.add(item(3)), isTrue);
    expect([for (final item in queue.items) item.id], [1, 2, 3]);
    expect(queue.sequence(2), [2, 3], reason: 'The reader pages on through the rest of the list');
    await Future<void>.delayed(Duration.zero);
    expect(queue.cover(1), [1, 2, 3]);

    queue.move(2, 0);
    expect([for (final item in ReadingQueue(preferences, covers: covers).items) item.id], [3, 1, 2], reason: 'The order survives a relaunch');

    queue.finished(1);
    expect([for (final item in queue.items) item.id], [3, 2]);
    expect(queue.cover(1), isNull);
    queue.clear();
    expect(preferences.object(ReadingQueue.key), isNull);
  });

  test('a carried work joins only when let go over the drop panel', () {
    final queue = ReadingQueue(MemoryPreferences(), covers: covers);
    const panel = Rect.fromLTWH(16, 560, 370, 133);
    queue.beginCarry(item(7), at: const Offset(100, 300));
    queue.dropZone = panel;
    queue.moveCarry(const Offset(120, 400));
    expect(queue.isOverDropZone, isFalse);
    expect(queue.endCarry(), isFalse, reason: 'Letting go anywhere else adds nothing');
    expect(queue.carried, isNull);
    expect(queue.isEmpty, isTrue);

    queue.beginCarry(item(9), at: const Offset(100, 300));
    queue.moveCarry(const Offset(200, 640));
    expect(queue.isOverDropZone, isTrue);
    expect(queue.endCarry(), isTrue);
    expect([for (final item in queue.items) item.id], [9]);
    expect(queue.carried, isNull);
  });
}
