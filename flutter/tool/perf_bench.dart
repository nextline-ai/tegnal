// Profile-mode device benchmark for the costs that decide Android smoothness.
// Run with: flutter run --profile -t tool/perf_bench.dart
// Results are printed as `BENCH ...` lines; nothing touches the app's library.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import 'package:tegnal/core/content.dart';
import 'package:tegnal/data/booru_source.dart';
import 'package:tegnal/data/library_store.dart';
import 'package:tegnal/ui/common.dart';
import 'package:tegnal/ui/session_image_provider.dart';

const _tiles = 240;
final _benchSite = Uri.parse('https://safebooru.org');

final _lines = <String>[];

void _report(String line) => _lines.add(line);

/// Early engine log lines can be lost, so every result is emitted at the end.
void _flush() {
  for (final line in _lines) {
    debugPrint('BENCH $line');
  }
}

String _percentiles(List<int> micros) {
  final sorted = [...micros]..sort();
  double at(double p) =>
      sorted[(sorted.length * p).floor().clamp(0, sorted.length - 1)] / 1000;
  String ms(double value) => value.toStringAsFixed(2);
  return 'n=${sorted.length} p50=${ms(at(.5))}ms p90=${ms(at(.9))}ms '
      'p99=${ms(at(.99))}ms max=${ms(sorted.last / 1000)}ms';
}

Future<void> _databaseWrites(Directory directory) async {
  final path = '${directory.path}/bench.sqlite';
  for (final suffix in ['', '-wal', '-shm', '-journal']) {
    final file = File('$path$suffix');
    if (file.existsSync()) file.deleteSync();
  }
  final database = sqlite3.open(path);
  final store = LibraryStore(database);
  void measure(String label) {
    final samples = <int>[];
    for (var i = 0; i < 300; i++) {
      final watch = Stopwatch()..start();
      store.setProgress('work-${i % 8}', i);
      samples.add(watch.elapsedMicroseconds);
    }
    _report('progress write [$label] ${_percentiles(samples)}');
  }

  final mode = database.select('PRAGMA journal_mode').first.values.first;
  measure('store journal=$mode');
  database.select('PRAGMA journal_mode = DELETE');
  database.execute('PRAGMA synchronous = FULL');
  measure('DELETE/FULL');
  database.select('PRAGMA journal_mode = WAL');
  database.execute('PRAGMA synchronous = NORMAL');
  measure('WAL/NORMAL');
  database.close();
}

void _catalogParse() {
  final body = jsonEncode([
    for (var i = 0; i < 200; i++)
      {
        'id': i,
        'md5': 'a' * 32,
        'tag_string': List.generate(60, (tag) => 'tag_$tag').join(' '),
        'file_url': 'https://media.example/original/$i.jpg',
        'preview_file_url': 'https://media.example/preview/$i.jpg',
        'image_width': 2000,
        'image_height': 3000,
      },
  ]);
  final encoded = utf8.encode(body);
  final samples = <int>[];
  for (var i = 0; i < 40; i++) {
    final watch = Stopwatch()..start();
    final buffer = <int>[];
    for (var offset = 0; offset < encoded.length; offset += 8192) {
      buffer.addAll(encoded.skip(offset).take(8192));
    }
    jsonDecode(utf8.decode(buffer, allowMalformed: true));
    samples.add(watch.elapsedMicroseconds);
  }
  _report(
    'catalog parse ${(encoded.length / 1024).round()}KiB [main isolate] '
    '${_percentiles(samples)}',
  );
}

/// Real thumbnails through the app's transport. The UI lag sample shows how long
/// platform-channel responses hold the merged Android platform/UI thread.
Future<void> _imageLoading() async {
  final source = SourceConfig(
    id: 'bench',
    name: 'bench',
    baseUrl: _benchSite,
    kind: SourceKind.gelbooru,
  );
  final client = BooruSource(source);
  Map<String, String> referer(ContentItem item) => {
    if (item.pageUrl != null) 'Referer': item.pageUrl.toString(),
  };
  Future<List<ContentItem>> items(int page) async =>
      (await client.search('scenery rating:general', page: page)).items;
  try {
    await SessionImageLoader.clearCache();
    final grid = (await items(3)).take(40).toList();
    final thumbnails = SessionImageLoader(maximumBytes: 2 * 1024 * 1024);
    var lag = 0;
    var last = Stopwatch()..start();
    final monitor = Timer.periodic(const Duration(milliseconds: 4), (_) {
      final gap = last.elapsedMicroseconds;
      if (gap > lag) lag = gap;
      last = Stopwatch()..start();
    });
    final watch = Stopwatch()..start();
    var first = 0;
    await Future.wait(
      grid.map((item) async {
        await thumbnails
            .load(item.thumbnailUrl!, headers: referer(item))
            .then((_) => first = first == 0 ? watch.elapsedMilliseconds : first)
            .catchError((Object _) => 0);
      }),
    );
    _report(
      'thumbnails ${grid.length} first=${first}ms '
      'all=${watch.elapsedMilliseconds}ms maxUiGap=${(lag / 1000).round()}ms',
    );

    final directory = await Directory.systemTemp.createTemp('tegnal-bench');
    SessionImageLoader launch() => SessionImageLoader(
      maximumBytes: 2 * 1024 * 1024,
      cache: SessionImageByteCache(
        maximumBytes: 0,
        useDisk: true,
        diskDirectory: directory,
      ),
    );
    final firstLaunch = launch();
    await Future.wait([
      for (final item in grid)
        firstLaunch
            .load(item.thumbnailUrl!, headers: referer(item))
            .catchError((Object _) => Uint8List(0)),
    ]);
    // ignore: invalid_use_of_visible_for_testing_member
    await firstLaunch.cache!.waitForDiskWrites();
    final secondLaunch = launch();
    watch.reset();
    await Future.wait([
      for (final item in grid)
        secondLaunch
            .load(item.thumbnailUrl!, headers: referer(item))
            .catchError((Object _) => Uint8List(0)),
    ]);
    _report(
      'thumbnails after restart ${grid.length} all=${watch.elapsedMilliseconds}ms',
    );
    await directory.delete(recursive: true);

    await SessionImageLoader.clearCache();
    final behind = (await items(4)).take(24).toList();
    final original = behind.removeLast();
    final queued = [
      for (final item in behind)
        thumbnails
            .load(item.thumbnailUrl!, headers: referer(item))
            .catchError((Object _) => Uint8List(0)),
    ];
    lag = 0;
    watch.reset();
    final bytes = await SessionImageLoader().load(
      original.mediaUrl!,
      headers: referer(original),
    );
    _report(
      'reader page behind ${behind.length} thumbnails '
      '${(bytes.length / 1024).round()}KiB wait=${watch.elapsedMilliseconds}ms '
      'maxUiGap=${(lag / 1000).round()}ms',
    );
    await Future.wait(queued);

    lag = 0;
    watch.reset();
    final originals = (await items(5)).take(6).toList();
    var total = 0;
    await Future.wait(
      originals.map((item) async {
        final data = await SessionImageLoader().load(
          item.mediaUrl!,
          headers: referer(item),
        );
        total += data.length;
      }),
    );
    _report(
      'originals ${originals.length} ${(total / 1024 / 1024).toStringAsFixed(1)}MiB '
      'all=${watch.elapsedMilliseconds}ms maxUiGap=${(lag / 1000).round()}ms',
    );
    monitor.cancel();
  } catch (error) {
    _report('image loading failed: $error');
  } finally {
    client.close();
    await SessionImageLoader.clearCache();
  }
}

/// Synthetic artwork with enough gradients to resemble real blur input.
Future<Uint8List> _artwork(int seed) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  const size = Rect.fromLTWH(0, 0, 512, 640);
  canvas.drawRect(
    size,
    Paint()
      ..shader = ui.Gradient.linear(Offset.zero, const Offset(512, 640), [
        HSVColor.fromAHSV(1, seed * 37 % 360.0, .7, .9).toColor(),
        HSVColor.fromAHSV(1, seed * 91 % 360.0, .8, .4).toColor(),
      ]),
  );
  final image = await recorder.endRecording().toImage(512, 640);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return bytes!.buffer.asUint8List();
}

class _Grid extends StatelessWidget {
  const _Grid({required this.images, required this.scroll, required this.blur});
  final List<Uint8List> images;
  final ScrollController scroll;
  final bool blur;

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      GridView.builder(
        controller: scroll,
        padding: const EdgeInsets.all(12),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childAspectRatio: .78,
        ),
        itemCount: _tiles,
        itemBuilder: (context, index) => ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image(
            image: ResizeImage(
              MemoryImage(images[index % images.length]),
              width: 512,
            ),
            fit: BoxFit.cover,
            gaplessPlayback: true,
          ),
        ),
      ),
      Positioned(
        left: 20,
        right: 20,
        bottom: 24,
        height: 64,
        child: ChromeSurface(
          enabled: blur,
          borderRadius: BorderRadius.circular(40),
          child: const SizedBox.expand(),
        ),
      ),
    ],
  );
}

class _Bench extends StatefulWidget {
  const _Bench({required this.images});
  final List<Uint8List> images;
  @override
  State<_Bench> createState() => _BenchState();
}

class _BenchState extends State<_Bench> {
  final _scroll = ScrollController();
  bool _blur = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<void> _pass(String label, bool blur) async {
    setState(() => _blur = blur);
    await Future<void>.delayed(const Duration(milliseconds: 800));
    final build = <int>[], raster = <int>[];
    void collect(List<ui.FrameTiming> timings) {
      for (final timing in timings) {
        build.add(timing.buildDuration.inMicroseconds);
        raster.add(timing.rasterDuration.inMicroseconds);
      }
    }

    SchedulerBinding.instance.addTimingsCallback(collect);
    final extent = _scroll.position.maxScrollExtent;
    for (var cycle = 0; cycle < 3; cycle++) {
      await _scroll.animateTo(
        extent / 2,
        duration: const Duration(seconds: 3),
        curve: Curves.linear,
      );
      await _scroll.animateTo(
        0,
        duration: const Duration(seconds: 3),
        curve: Curves.linear,
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    SchedulerBinding.instance.removeTimingsCallback(collect);
    final budget =
        1000000 /
        ui.PlatformDispatcher.instance.views.first.display.refreshRate;
    final slow = raster.where((value) => value > budget).length;
    _report('scroll [$label] build ${_percentiles(build)}');
    _report(
      'scroll [$label] raster ${_percentiles(raster)} '
      'overBudget=$slow/${raster.length} budget=${(budget / 1000).toStringAsFixed(1)}ms',
    );
  }

  Future<void> _run() async {
    // The first pass warms decoded images and pipelines for both variants.
    await _pass('warmup', true);
    for (var round = 1; round <= 3; round++) {
      await _pass('no blur $round', false);
      await _pass('blur $round', true);
    }
    _report('done');
    _flush();
    await Future<void>.delayed(const Duration(seconds: 1));
    exit(0);
  }

  @override
  Widget build(BuildContext context) =>
      _Grid(images: widget.images, scroll: _scroll, blur: _blur);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final directory = await getTemporaryDirectory();
  await _databaseWrites(directory);
  _catalogParse();
  await _imageLoading();
  final images = [for (var i = 0; i < 24; i++) await _artwork(i)];
  runApp(
    MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(body: _Bench(images: images)),
    ),
  );
}
