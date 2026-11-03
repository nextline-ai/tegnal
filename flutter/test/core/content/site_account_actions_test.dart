import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/content/content_environment.dart';
import 'package:tegnal/core/content/gallery_content.dart';
import 'package:tegnal/core/content/site_account.dart';
import 'package:tegnal/core/content/site_account_actions.dart';
import 'package:tegnal/core/storage/app_database.dart';
import 'package:tegnal/core/support/secure_secret_store.dart';

import 'content_test_support.dart';

void main() {
  const identity = 'ipb_member_id=42; ipb_pass_hash=abc123; tracking=1';

  test('the secure store reads everything once and writes in order', () async {
    final storage = MemorySecureStorage()..values['unrelated'] = 'kept';
    final store = await SecureSecretStore.load(storage);
    expect(store.read('site-account'), isNull);
    store.write('site-account', 'first');
    store.write('site-account', 'second');
    expect(store.read('site-account'), 'second');
    await store.flush();
    expect(storage.values['tegnal.secret.site-account'], 'second');
    expect(storage.values['unrelated'], 'kept');
    final reloaded = await SecureSecretStore.load(storage);
    expect(reloaded.read('site-account'), 'second');
    reloaded.write('site-account', null);
    await reloaded.flush();
    expect(storage.values.containsKey('tegnal.secret.site-account'), isFalse);
  });

  test('a sign-in keeps only the identity cookies, across a restart', () async {
    resetContent(site: 'https://comics.example');
    final storage = MemorySecureStorage();
    SiteAccount.store = await SecureSecretStore.load(storage);
    final content = ContentEnvironment.fixture();
    final cookies = SiteAccountActions.parseCookieHeader(identity);
    expect(cookies.map((cookie) => cookie.name), ['ipb_member_id', 'ipb_pass_hash', 'tracking']);
    expect(SiteAccountActions.finishSignIn([const SiteCookie(name: 'tracking', value: '1')], content), isFalse);
    expect(SiteAccountActions.finishSignIn(cookies, content), isTrue);
    expect(content.siteAccountSignedIn, isTrue);
    await (SiteAccount.store as SecureSecretStore).flush();
    expect(storage.values.values.single, isNot(contains('tracking')));

    SiteAccount.store = await SecureSecretStore.load(storage);
    expect(SiteAccount.isSignedIn, isTrue);
    content.syncsAccountFavorites = true;
    SiteAccountActions.signOut(content);
    expect(SiteAccount.isSignedIn, isFalse);
    expect(content.siteAccountSignedIn, isFalse);
    expect(content.syncsAccountFavorites, isFalse);
  });

  test('the sign-in page stays on https', () {
    expect(SiteAccountActions.allowsSignInNavigation(Uri.parse('https://comics.example/login')), isTrue);
    expect(SiteAccountActions.allowsSignInNavigation(Uri.parse('about:blank')), isTrue);
    expect(SiteAccountActions.allowsSignInNavigation(Uri.parse('http://comics.example/login')), isFalse);
    expect(SiteAccountActions.allowsSignInNavigation(Uri.parse('intent://open')), isFalse);
  });

  test('importing account favorites adds only missing works, page by page', () async {
    final database = AppDatabase.inMemory();
    database.upsertWork(galleryId: 1, title: 'Already saved');
    final pages = {
      null: ([1, 2], 'next'),
      'next': ([3], null),
    };
    var covers = 0;
    final added = await SiteAccountActions.importAccountFavorites(
      database: database,
      favorites: ({String? after}) async => pages[after]!,
      preview: (id) => id == 2
          ? const NativeGallery(id: 2, title: 'Preview', artists: ['someone'], language: 'english', type: 'manga', tags: ['tag:sample'], pages: [])
          : null,
      startCoverQueue: () => covers += 1,
    );
    expect(added, 2);
    expect(covers, 1);
    expect(database.getWork(1)?.title, 'Already saved');
    expect(database.getWork(2)?.title, 'Preview');
    expect(database.getWork(2)?.artists, 'someone');
    expect(database.getWork(3), isNotNull);
    expect(database.getWork(3)?.folders.single.name, '미분류');
  });
}
