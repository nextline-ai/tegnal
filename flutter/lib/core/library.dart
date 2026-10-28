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

enum ReaderResumeBehavior { ask, continueReading, fromBeginning }

class ReaderLayout {
  static int start(int page, int count) =>
      page.clamp(0, 1 << 30) ~/ count.clamp(1, 4) * count.clamp(1, 4);
  static int next(int page, int delta, int count, int total) =>
      (start(page, count) + delta * count.clamp(1, 4)).clamp(
        0,
        start((total - 1).clamp(0, 1 << 30), count),
      );
}

class ReaderLoadingPolicy {
  static List<int> adjacentPages(int index, int total, int count) {
    if (count <= 0) return const [];
    final ahead = count.clamp(0, 5);
    return [
      if (index > 0) index - 1,
      for (var offset = 1; offset <= ahead; offset++)
        if (index + offset < total) index + offset,
    ];
  }
}

class ReaderPreferences {
  const ReaderPreferences({
    this.readingMode = ReadingMode.horizontal,
    this.rightToLeft = false,
    this.showPageNumber = false,
    this.tapNavigation = true,
    this.keepAwake = true,
    this.originalImages = false,
    this.showNotes = true,
    this.autoAdvance = false,
    this.autoSeconds = 10,
    this.dimming = 0,
    this.resumeBehavior = ReaderResumeBehavior.ask,
    this.pagesPerSpread = 1,
    this.prefetch = 3,
    this.bottomMenu = false,
    this.continuousPreviewSwipe = false,
    this.reducedData = false,
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
  final ReaderResumeBehavior resumeBehavior;
  final int pagesPerSpread;
  final int prefetch;
  final bool bottomMenu;
  final bool continuousPreviewSwipe;
  final bool reducedData;
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
    'resumeBehavior': resumeBehavior.name,
    'pagesPerSpread': pagesPerSpread,
    'prefetch': prefetch,
    'bottomMenu': bottomMenu,
    'continuousPreviewSwipe': continuousPreviewSwipe,
    'reducedData': reducedData,
  };
  factory ReaderPreferences.fromJson(Map<String, dynamic> j) =>
      ReaderPreferences(
        readingMode:
            ReadingMode.values
                .where((v) => v.name == j['readingMode'])
                .firstOrNull ??
            ReadingMode.horizontal,
        rightToLeft: j['rightToLeft'] == true,
        showPageNumber: j['showPageNumber'] == true,
        tapNavigation: j['tapNavigation'] != false,
        keepAwake: j['keepAwake'] != false,
        originalImages: j['originalImages'] == true,
        showNotes: j['showNotes'] != false,
        autoAdvance: j['autoAdvance'] == true,
        autoSeconds: ((j['autoSeconds'] as num?)?.toInt() ?? 10).clamp(2, 120),
        dimming: ((j['dimming'] as num?)?.toDouble() ?? 0).clamp(0, 0.65),
        resumeBehavior:
            ReaderResumeBehavior.values
                .where((value) => value.name == j['resumeBehavior'])
                .firstOrNull ??
            ReaderResumeBehavior.ask,
        pagesPerSpread: ((j['pagesPerSpread'] as num?)?.toInt() ?? 1).clamp(
          1,
          4,
        ),
        prefetch: const {0, 2, 3, 5}.contains(j['prefetch'])
            ? (j['prefetch'] as num).toInt()
            : 3,
        bottomMenu: j['bottomMenu'] == true,
        continuousPreviewSwipe: j['continuousPreviewSwipe'] == true,
        reducedData: j['reducedData'] == true,
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
    ReaderResumeBehavior? resumeBehavior,
    int? pagesPerSpread,
    int? prefetch,
    bool? bottomMenu,
    bool? continuousPreviewSwipe,
    bool? reducedData,
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
    resumeBehavior: resumeBehavior ?? this.resumeBehavior,
    pagesPerSpread: pagesPerSpread ?? this.pagesPerSpread,
    prefetch: prefetch ?? this.prefetch,
    bottomMenu: bottomMenu ?? this.bottomMenu,
    continuousPreviewSwipe:
        continuousPreviewSwipe ?? this.continuousPreviewSwipe,
    reducedData: reducedData ?? this.reducedData,
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
