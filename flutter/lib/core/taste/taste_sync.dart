import 'package:flutter/foundation.dart';

import '../support/l10n.dart';
import '../support/swift_json.dart';
import 'taste_analyzer.dart';
import 'taste_controller.dart';
import 'taste_models.dart';
import 'taste_store.dart';

/// One immutable batch of a mode's analysis history and reports, as the native app
/// writes its `taste-*.json` files.
class TasteSyncChunk {
  TasteSyncChunk({this.version = 1, required this.mode, required this.epoch, required this.events, List<TasteReport>? reports}) : reports = reports ?? [];
  int version;
  TasteMode mode;
  String epoch;
  List<TasteEvent> events;
  List<TasteReport> reports;

  factory TasteSyncChunk.fromJson(JsonObject json) => TasteSyncChunk(
    version: json.integer('version'),
    mode: TasteMode.values.byName(json.string('mode')),
    epoch: json.string('epoch'),
    events: json.list('events', (value) => TasteEvent.fromJson(jsonObject(value))),
    reports: json.listOrNull('reports', (value) => TasteReport.fromJson(jsonObject(value))) ?? [],
  );

  JsonObject toJson() => {
    'version': version,
    'mode': mode.name,
    'epoch': epoch,
    'events': [for (final event in events) event.toJson()],
    'reports': [for (final report in reports) report.toJson()],
  };
}

/// Where synced analysis chunks live. Android offers no cloud for them yet.
abstract interface class TasteSyncBackend {
  /// Chunks written by other devices since the last call, and the newest settings they carry.
  Future<(List<TasteSyncChunk> chunks, TasteControl? control)> download();
  Future<void> upload(TasteSyncChunk chunk, TasteControl control);
}

/// `TasteSyncCoordinator`. Without a backend it does nothing, and the screens present
/// taste sync as coming soon.
class TasteSyncCoordinator extends ChangeNotifier {
  TasteSyncCoordinator({this.backend});
  final TasteSyncBackend? backend;
  String status = L10n.text('Sync Off');
  bool syncing = false;

  bool get isAvailable => backend != null;

  void deletionPending() {
    if (backend == null) return;
    status = L10n.text('iCloud deletion pending');
    notifyListeners();
  }

  Future<void> synchronize(TasteController controller) async {
    final backend = this.backend;
    if (backend == null || syncing) return;
    if (!controller.control.cloudEnabled) {
      status = L10n.text('Analysis sync is off');
      notifyListeners();
      return;
    }
    syncing = true;
    notifyListeners();
    try {
      final (chunks, remote) = await backend.download();
      if (remote != null) controller.apply(controller.control.merged(remote), remote: true);
      for (final chunk in chunks) {
        if (chunk.version != 1) continue;
        final store = controller.store(chunk.mode);
        if (chunk.epoch != controller.control.epoch) continue;
        store.merge(chunk.events);
        for (final report in chunk.reports) {
          store.saveReport(report, uploaded: true);
        }
      }
      for (final mode in TasteMode.values) {
        final store = controller.store(mode);
        final events = store.pending();
        final reports = store.pendingReports();
        if (events.isEmpty && reports.isEmpty) continue;
        await backend.upload(TasteSyncChunk(mode: mode, epoch: controller.control.epoch, events: events, reports: reports), controller.control);
        store.acknowledge([for (final event in events) event.id]);
        store.acknowledgeReports([for (final report in reports) report.id]);
      }
      status = L10n.text('Analysis synced');
    } on Object {
      status = L10n.text('Unable to sync now. Your data is saved on this device.');
    } finally {
      syncing = false;
      notifyListeners();
    }
  }
}
