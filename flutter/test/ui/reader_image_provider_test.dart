import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/content.dart';
import 'package:tegnal/ui/reader_image_provider.dart';
import 'package:tegnal/ui/thumbnail_image_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'bounded reader decoding preserves portrait and landscape ratios',
    () async {
      final directory = await Directory.systemTemp.createTemp('reader-ratio-');
      try {
        for (final size in [
          const ui.Size(8, 16),
          const ui.Size(16, 8),
          const ui.Size(40, 160),
        ]) {
          final recorder = ui.PictureRecorder();
          ui.Canvas(recorder)
              .drawColor(const ui.Color(0xff2288aa), ui.BlendMode.src);
          final picture = recorder.endRecording();
          final image = await picture.toImage(
            size.width.toInt(),
            size.height.toInt(),
          );
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File('${directory.path}/${size.width}.png');
          await file.writeAsBytes(png!.buffer.asUint8List());
          image.dispose();
          picture.dispose();
          for (final provider in [
            readerImageProvider(ReaderPage(url: file.uri), {}, 4),
            thumbnailImageProvider(file.uri, {}, 4),
          ]) {
            final stream = provider.resolve(ImageConfiguration.empty);
            final complete = Completer<ui.Size>();
            final listener = ImageStreamListener((info, _) {
              complete.complete(
                ui.Size(
                  info.image.width.toDouble(),
                  info.image.height.toDouble(),
                ),
              );
              info.dispose();
            }, onError: complete.completeError);
            stream.addListener(listener);
            final decoded = await complete.future;
            stream.removeListener(listener);
            expect(decoded.longestSide, 4);
            expect(decoded.aspectRatio, size.aspectRatio);
            await provider.evict();
          }
        }
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );
  test('thumbnail decode sizes are display-aware, quantized and capped', () {
    expect(thumbnailDecodeLimit(const ui.Size(100, 150), 1), 192);
    expect(thumbnailDecodeLimit(const ui.Size(100, 150), 2), 320);
    expect(thumbnailDecodeLimit(const ui.Size(1000, 2000), 3), 768);
    expect(thumbnailDecodeLimit(const ui.Size(100, double.infinity), 3), 600);
  });
}
