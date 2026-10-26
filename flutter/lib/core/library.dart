import 'content.dart';

class LibraryFolder {
  const LibraryFolder({
    required this.id,
    required this.mode,
    required this.name,
    this.color = 0xFF5E5CE6,
    this.position = 0,
  });
  final String id;
  final AppMode mode;
  final String name;
  final int color;
  final int position;
  Map<String, dynamic> toJson() => {
    'id': id,
    'mode': mode.name,
    'name': name,
    'color': color,
    'position': position,
  };
  factory LibraryFolder.fromJson(Map<String, dynamic> j) => LibraryFolder(
    id: j['id'] as String,
    mode: AppMode.values.byName(j['mode'] as String),
    name: j['name'] as String,
    color: j['color'] as int,
    position: j['position'] as int? ?? 0,
  );
}

class SavedItem {
  const SavedItem({
    required this.item,
    required this.savedAt,
    this.folderIds = const [],
    this.note = '',
  });
  final ContentItem item;
  final DateTime savedAt;
  final List<String> folderIds;
  final String note;
}

enum ReadingMode { horizontal, vertical, continuous }

class ReaderPreferences {
  const ReaderPreferences({
    this.readingMode = ReadingMode.horizontal,
    this.rightToLeft = false,
    this.showPageNumber = true,
    this.tapNavigation = true,
    this.keepAwake = true,
    this.originalImages = false,
    this.showNotes = true,
    this.autoAdvance = false,
    this.autoSeconds = 10,
    this.dimming = 0,
  });
  final ReadingMode readingMode;
  final bool rightToLeft;
  final bool showPageNumber;
  final bool tapNavigation;
  final bool keepAwake;
  final bool originalImages;
  final bool showNotes;
  final bool autoAdvance;
  final int autoSeconds;
  final double dimming;
  Map<String, dynamic> toJson() => {
    'readingMode': readingMode.name,
    'rightToLeft': rightToLeft,
    'showPageNumber': showPageNumber,
    'tapNavigation': tapNavigation,
    'keepAwake': keepAwake,
    'originalImages': originalImages,
    'showNotes': showNotes,
    'autoAdvance': autoAdvance,
    'autoSeconds': autoSeconds,
    'dimming': dimming,
  };
  factory ReaderPreferences.fromJson(Map<String, dynamic> j) =>
      ReaderPreferences(
        readingMode:
            ReadingMode.values
                .where((v) => v.name == j['readingMode'])
                .firstOrNull ??
            ReadingMode.horizontal,
        rightToLeft: j['rightToLeft'] == true,
        showPageNumber: j['showPageNumber'] != false,
        tapNavigation: j['tapNavigation'] != false,
        keepAwake: j['keepAwake'] != false,
        originalImages: j['originalImages'] == true,
        showNotes: j['showNotes'] != false,
        autoAdvance: j['autoAdvance'] == true,
        autoSeconds: ((j['autoSeconds'] as num?)?.toInt() ?? 10).clamp(2, 120),
        dimming: ((j['dimming'] as num?)?.toDouble() ?? 0).clamp(0, 0.65),
      );
  ReaderPreferences copyWith({
    ReadingMode? readingMode,
    bool? rightToLeft,
    bool? showPageNumber,
    bool? tapNavigation,
    bool? keepAwake,
    bool? originalImages,
    bool? showNotes,
    bool? autoAdvance,
    int? autoSeconds,
    double? dimming,
  }) => ReaderPreferences(
    readingMode: readingMode ?? this.readingMode,
    rightToLeft: rightToLeft ?? this.rightToLeft,
    showPageNumber: showPageNumber ?? this.showPageNumber,
    tapNavigation: tapNavigation ?? this.tapNavigation,
    keepAwake: keepAwake ?? this.keepAwake,
    originalImages: originalImages ?? this.originalImages,
    showNotes: showNotes ?? this.showNotes,
    autoAdvance: autoAdvance ?? this.autoAdvance,
    autoSeconds: autoSeconds ?? this.autoSeconds,
    dimming: dimming ?? this.dimming,
  );
}

class SearchEntry {
  const SearchEntry(this.mode, this.sourceId, this.query, this.usedAt);
  final AppMode mode;
  final String sourceId;
  final String query;
  final DateTime usedAt;
}

class ArtistEntry {
  const ArtistEntry({
    required this.name,
    required this.mode,
    this.sourceId = '',
    this.kind = 0,
    this.note = '',
  });
  final String name;
  final AppMode mode;
  final String sourceId;
  final int kind;
  final String note;
  Map<String, dynamic> toJson() => {
    'name': name,
    'mode': mode.name,
    'sourceId': sourceId,
    'kind': kind,
    'note': note,
  };
  factory ArtistEntry.fromJson(Map<String, dynamic> j) => ArtistEntry(
    name: j['name'] as String,
    mode: AppMode.values.byName(j['mode'] as String),
    sourceId: j['sourceId'] as String? ?? '',
    kind: j['kind'] as int? ?? 0,
    note: j['note'] as String? ?? '',
  );
}

/// This is a capability report, never a request to fetch/install a model.
class DeviceAiCapabilities {
  const DeviceAiCapabilities({
    this.available = false,
    this.reason = 'No supported preinstalled system AI service is connected.',
  });
  final bool available;
  final String reason;
  bool get allowsModelDownload => false;
}
