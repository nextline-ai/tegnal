import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:tegnal/data/android_manga_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AndroidMangaClient', () {
    late MethodChannel channel;

    setUp(() {
      channel = const MethodChannel('test.manga-http');
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test(
      'sends HTTPS GET without redirects and returns bounded bytes',
      () async {
        MethodCall? received;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              if (call.method == 'get') {
                received = call;
                return {
                  'statusCode': 206,
                  'headers': {'content-range': 'bytes 0-2/3'},
                  'body': Uint8List.fromList([1, 2, 3]),
                };
              }
              return null;
            });

        final client = AndroidMangaClient(channel: channel);
        final request =
            http.Request('GET', Uri.https('manga.example', '/index-all.nozomi'))
              ..headers.addAll({
                'Range': 'bytes=0-2',
                'Connection': 'close',
                'Cookie': 'session=example',
              });
        final response = await client.send(request);

        expect(request.followRedirects, isFalse);
        expect(await response.stream.toBytes(), [1, 2, 3]);
        final arguments = received!.arguments as Map<Object?, Object?>;
        expect(arguments['url'], 'https://manga.example/index-all.nozomi');
        expect(arguments['maxBytes'], 32 * 1024 * 1024);
        expect(arguments['headers'], {
          'Range': 'bytes=0-2',
          'Cookie': 'session=example',
        });
        client.close();
      },
    );

    test(
      'rejects non-HTTPS and non-GET requests before invoking native code',
      () async {
        var calls = 0;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              calls++;
              return null;
            });
        final client = AndroidMangaClient(channel: channel);

        await expectLater(
          client.send(http.Request('GET', Uri.http('manga.example', '/'))),
          throwsA(isA<http.ClientException>()),
        );
        await expectLater(
          client.send(http.Request('POST', Uri.https('manga.example', '/'))),
          throwsA(isA<http.ClientException>()),
        );
        expect(calls, 0);
        client.close();
      },
    );

    test(
      'abort trigger cancels the native request and completes with abort error',
      () async {
        final nativeCall = Completer<void>();
        var cancelled = false;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              if (call.method == 'get') {
                await nativeCall.future;
              } else if (call.method == 'cancel') {
                cancelled = true;
                throw PlatformException(code: 'aborted');
              }
              return null;
            });

        final client = AndroidMangaClient(channel: channel);
        final abort = Completer<void>();
        final request = http.AbortableRequest(
          'GET',
          Uri.https('manga.example', '/'),
          abortTrigger: abort.future,
        );
        final send = client.send(request);
        await Future<void>.delayed(Duration.zero);
        abort.complete();

        await expectLater(send, throwsA(isA<http.RequestAbortedException>()));
        nativeCall.complete();
        await Future<void>.delayed(Duration.zero);
        expect(cancelled, isTrue);
        client.close();
      },
    );

    test('preserves native certificate failures as non-retryable', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            throw PlatformException(
              code: 'certificate_error',
              message: 'The manga server certificate could not be verified.',
            );
          });
      final client = AndroidMangaClient(channel: channel);

      await expectLater(
        client.send(http.Request('GET', Uri.https('manga.example', '/'))),
        throwsA(isA<AndroidMangaCertificateException>()),
      );
      client.close();
    });

    test(
      'marks only transport network failures as fallback-eligible',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              throw PlatformException(code: 'network_error');
            });
        final client = AndroidMangaClient(channel: channel);

        await expectLater(
          client.send(http.Request('GET', Uri.https('manga.example', '/'))),
          throwsA(isA<AndroidMangaNetworkException>()),
        );
        client.close();
      },
    );

    test('close cancels outstanding native calls', () async {
      final nativeCall = Completer<void>();
      final cancelSeen = Completer<void>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'get') {
              await nativeCall.future;
            } else if (call.method == 'cancel') {
              if (!cancelSeen.isCompleted) cancelSeen.complete();
              throw PlatformException(code: 'aborted');
            }
            return null;
          });

      final client = AndroidMangaClient(channel: channel);
      final send = client.send(
        http.Request('GET', Uri.https('manga.example', '/')),
      );
      await Future<void>.delayed(Duration.zero);
      client.close();

      nativeCall.complete();
      await cancelSeen.future.timeout(const Duration(seconds: 1));
      await expectLater(send, throwsA(isA<http.ClientException>()));
    });
  });
}
