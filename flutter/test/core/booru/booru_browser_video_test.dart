import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/booru/booru_browser.dart';
import 'package:tegnal/core/booru/booru_models.dart';
import 'package:tegnal/presentation/booru/booru_web_video.dart';

final server = BooruServer(id: 'test-video', name: 'Test', baseURL: 'https://example.com/booru', engine: BooruEngine.danbooru);

/// Serves one file through the stream scripts, in pieces, and can lose its stream once.
class _StreamPage implements BooruBrowserPage {
  _StreamPage(this.file, {this.loseAfter});
  final Uint8List file;

  /// Forgets the open stream after this many reads, as a navigation would.
  int? loseAfter;
  final offsets = <int>[];
  int _position = 0, _reads = 0;
  bool _open = false;

  @override
  Uri? get url => Uri.parse('https://example.com/booru/robots.txt');
  @override
  bool get isolatesScripts => false;
  @override
  Future<void> ready() async {}
  @override
  Future<int> navigate(Uri url) async => 200;
  @override
  void stop() {}

  @override
  Future<String> evaluate(String script, Map<String, Object?> arguments) async {
    if (script == BooruBrowserScripts.streamOpen) {
      final offset = arguments['offset'] as int;
      offsets.add(offset);
      _position = offset;
      _open = true;
      return jsonEncode({'status': offset > 0 ? 206 : 200, 'length': file.length, 'type': 'video/mp4'});
    }
    if (script == BooruBrowserScripts.streamRead) {
      if (!_open) return jsonEncode({'missing': true});
      if (loseAfter != null && ++_reads > loseAfter!) {
        loseAfter = null;
        _open = false;
        return jsonEncode({'missing': true});
      }
      // Smaller pieces than the limit, so a file takes several reads.
      final end = (_position + 3).clamp(0, file.length);
      final piece = file.sublist(_position, end);
      _position = end;
      final done = end == file.length;
      if (done) _open = false;
      return jsonEncode({'data': base64Encode(piece), 'done': done});
    }
    return '{}';
  }
}

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('browser-video-'));
  tearDown(() {
    BooruWebTransport.reset(server);
    BooruWebTransport.factory = null;
    root.deleteSync(recursive: true);
  });

  test('a video streams into a file in pieces with progress, of any size', () async {
    final file = Uint8List.fromList(List.generate(20, (index) => index));
    BooruWebTransport.factory = (_) => _StreamPage(file);
    final target = File('${root.path}/video');
    final progress = <double>[];
    final type = await BooruWebTransport.download('https://cdn.example.com/a.mp4', server, target, progress: progress.add);
    expect(type, 'video/mp4');
    expect(target.readAsBytesSync(), file);
    expect(progress.last, 1);
    expect(progress.length, greaterThan(1));
  });

  test('a stream the page lost resumes from the bytes already written', () async {
    final file = Uint8List.fromList(List.generate(20, (index) => 100 + index));
    final page = _StreamPage(file, loseAfter: 2);
    BooruWebTransport.factory = (_) => page;
    final target = File('${root.path}/video');
    await BooruWebTransport.download('https://cdn.example.com/a.mp4', server, target);
    expect(target.readAsBytesSync(), file);
    expect(page.offsets, [0, 6]);
  });

  test('the browser player page escapes the address and follows the viewer', () {
    final page = BooruWebVideo.document(url: "https://cdn.example.com/a.mp4?x='1'&y=<2>", active: false, muted: true, loop: true, nonce: 'n');
    expect(page, contains('src="https://cdn.example.com/a.mp4?x=&#39;1&#39;&amp;y=&lt;2&gt;"'));
    expect(page, contains(' muted loop>'));
    expect(page, contains('let allowed=false,muted=true'));
    expect(page, isNot(contains('autoplay')), reason: 'Only the viewer starts playback');
  });
}
