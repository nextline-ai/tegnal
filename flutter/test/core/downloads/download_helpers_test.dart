import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/downloads/download_store.dart';

void main() {
  test('download statuses carry the native labels and actions', () {
    expect(WorkDownloadStatus.values.map((status) => status.title), ['Queued', 'Downloading', 'Paused', 'Failed', 'Completed']);
    expect(WorkDownloadStatus.downloading.canPause, isTrue);
    expect(WorkDownloadStatus.failed.canResume, isTrue);
    expect(WorkDownloadStatus.failed.resumeTitle, 'Retry');
    expect(WorkDownloadStatus.paused.resumeTitle, 'Resume');
    expect(WorkDownloadStatus.completed.canPause || WorkDownloadStatus.completed.canResume, isFalse);
  });

  test('sizes read like the file style byte count', () {
    expect(FileByteCount.format(0, language: 'en'), 'Zero KB');
    expect(FileByteCount.format(512, language: 'en'), '512 bytes');
    expect(FileByteCount.format(1500, language: 'en'), '2 KB');
    expect(FileByteCount.format(1500000, language: 'en'), '1.5 MB');
    expect(FileByteCount.format(2000000, language: 'en'), '2 MB');
    expect(FileByteCount.format(1234567890, language: 'en'), '1.23 GB');
    expect(FileByteCount.format(1500000, language: 'ko'), '1.5MB');
    expect(FileByteCount.format(1500000, language: 'ja'), '1.5 MB');
  });
}
