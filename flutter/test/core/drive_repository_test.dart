import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tegnal/data/drive_auth.dart';
import 'package:tegnal/data/drive_repository.dart';

class _Auth implements DriveAuth {
  @override
  DriveIdentity? identity = const DriveIdentity(
    id: 'account-a',
    email: 'a@example.test',
  );
  void Function()? onToken;
  @override
  bool get configured => true;
  @override
  String? get configurationMessage => null;
  @override
  Future<String> accessToken({bool interactive = false}) async {
    onToken?.call();
    return 'fixture-private-token';
  }

  @override
  Future<DriveIdentity> connect() async => identity!;
  @override
  Future<bool> restore() async => true;
  @override
  Future<void> disconnect() async {
    identity = null;
  }

  @override
  void dispose() {}
}

Map<String, dynamic> _file(
  String id,
  String content, {
  List<String> parents = const [],
}) => {
  'id': id,
  'size': '${utf8.encode(content).length}',
  'modifiedTime': '2026-10-27T00:00:00Z',
  'description': jsonEncode({
    'tegnalSync': 1,
    'parents': parents,
    'sha256': sha256.convert(utf8.encode(content)).toString(),
  }),
};

void main() {
  test('immutable publication uses resumable upload, native bytes and revision parents', () async {
    const content = '{"format":"tegnal-library","title":"보관함"}';
    final seen = <http.Request>[];
    final auth = _Auth();
    final repository = GoogleDriveRepository(
      auth,
      client: MockClient((request) async {
        seen.add(request);
        expect(
          request.headers['authorization'],
          'Bearer fixture-private-token',
        );
        expect(request.followRedirects, isFalse);
        switch (seen.length) {
          case 1:
            expect(
              request.url.queryParameters['q'],
              contains("value='folder'"),
            );
            return http.Response('{"files":[]}', 200);
          case 2:
            expect(jsonDecode(request.body)['name'], 'TEGNAL');
            return http.Response('{"id":"folder-1"}', 200);
          case 3:
            expect(request.method, 'POST');
            expect(request.url.queryParameters['uploadType'], 'resumable');
            final metadata = jsonDecode(request.body);
            expect(metadata['parents'], ['folder-1']);
            expect(jsonDecode(metadata['description'])['parents'], [
              'parent-1',
              'parent-2',
            ]);
            expect(
              request.headers['x-upload-content-length'],
              '${utf8.encode(content).length}',
            );
            return http.Response(
              '',
              200,
              headers: {
                'location': 'https://www.googleapis.com/upload/drive/v3/files?upload_id=fixture',
              },
            );
          case 4:
            expect(request.method, 'PUT');
            expect(utf8.decode(request.bodyBytes), content);
            return http.Response(
              jsonEncode(
                _file('revision-3', content, parents: ['parent-1', 'parent-2']),
              ),
              200,
            );
          default:
            fail('Unexpected request');
        }
      }),
    );
    addTearDown(repository.dispose);
    final revision = await repository.publish(content, [
      'parent-1',
      'parent-2',
    ]);
    expect(revision.id, 'revision-3');
    expect(seen, hasLength(4));
    expect(seen.where((request) => request.method == 'PATCH'), isEmpty);
  });

  test(
    'snapshot listing follows all pages and keeps only app-marked file query',
    () async {
      var calls = 0;
      final repository = GoogleDriveRepository(
        _Auth(),
        client: MockClient((request) async {
          calls++;
          expect(
            request.url.queryParameters['q'],
            contains("key='tegnalSync'"),
          );
          expect(
            request.url.queryParameters['q'],
            contains("value='snapshot'"),
          );
          expect(request.url.queryParameters['spaces'], 'drive');
          if (calls == 1) {
            return http.Response(
              jsonEncode({
                'files': [_file('first', '{}')],
                'nextPageToken': 'page-two',
              }),
              200,
            );
          }
          expect(request.url.queryParameters['pageToken'], 'page-two');
          return http.Response(
            jsonEncode({
              'files': [
                _file('second', '{}', parents: ['first']),
              ],
            }),
            200,
          );
        }),
      );
      addTearDown(repository.dispose);
      expect((await repository.revisions()).map((r) => r.id), [
        'first',
        'second',
      ]);
    },
  );

  test('read verifies both declared size and checksum', () async {
    final revision = DriveRevision.fromFile(_file('r1', '{"saved":true}'));
    final repository = GoogleDriveRepository(
      _Auth(),
      client: MockClient((_) async => http.Response('{"saved":fals}', 200)),
    );
    addTearDown(repository.dispose);
    await expectLater(
      repository.read(revision),
      throwsA(isA<DriveSyncException>()),
    );
  });

  test(
    'upload location cannot redirect bearer credentials outside Google API',
    () async {
      var requests = 0;
      final repository = GoogleDriveRepository(
        _Auth(),
        client: MockClient((request) async {
          requests++;
          expect(request.url.host, 'www.googleapis.com');
          if (requests == 1) {
            return http.Response('{"files":[{"id":"folder"}]}', 200);
          }
          return http.Response(
            '',
            200,
            headers: {'location': 'https://attacker.invalid/upload'},
          );
        }),
      );
      addTearDown(repository.dispose);
      await expectLater(
        repository.publish('{}', []),
        throwsA(isA<DriveSyncException>()),
      );
      expect(requests, 2);
    },
  );

  test('account changes while obtaining token never send a request', () async {
    var sent = false;
    final auth = _Auth();
    final repository = GoogleDriveRepository(
      auth,
      client: MockClient((_) async {
        sent = true;
        return http.Response('{}', 200);
      }),
    );
    auth.onToken = () => auth.identity = const DriveIdentity(
      id: 'account-b',
      email: 'b@example.test',
    );
    addTearDown(repository.dispose);
    await expectLater(
      repository.revisions(),
      throwsA(isA<DriveSyncException>()),
    );
    expect(sent, isFalse);
  });

  test(
    'HTTP failures do not reveal provider response or access token',
    () async {
      final repository = GoogleDriveRepository(
        _Auth(),
        client: MockClient(
          (_) async =>
              http.Response('private-file-name fixture-private-token', 403),
        ),
      );
      addTearDown(repository.dispose);
      try {
        await repository.revisions();
        fail('Expected rejection');
      } on DriveSyncException catch (error) {
        expect(error.toString(), isNot(contains('private-file-name')));
        expect(error.toString(), isNot(contains('fixture-private-token')));
        expect(error.toString(), contains('denied access'));
      }
    },
  );

  test('invalid graph metadata and repeated pagination fail closed', () async {
    expect(
      () => DriveRevision.fromFile(_file('self', '{}', parents: ['self'])),
      throwsA(isA<DriveSyncException>()),
    );
    expect(
      () => DriveRevision.fromFile(_file('r2', '{}', parents: ['r1', 'r1'])),
      throwsA(isA<DriveSyncException>()),
    );
    final repository = GoogleDriveRepository(
      _Auth(),
      client: MockClient(
        (_) async =>
            http.Response('{"files":[],"nextPageToken":"repeat"}', 200),
      ),
    );
    addTearDown(repository.dispose);
    await expectLater(
      repository.revisions(),
      throwsA(isA<DriveSyncException>()),
    );
  });

  test('metadata response is bounded even without content length', () async {
    final repository = GoogleDriveRepository(
      _Auth(),
      client: MockClient(
        (_) async => http.Response(' ' * (4 * 1024 * 1024 + 1), 200),
      ),
    );
    addTearDown(repository.dispose);
    await expectLater(
      repository.revisions(),
      throwsA(isA<DriveSyncException>()),
    );
  });
}
