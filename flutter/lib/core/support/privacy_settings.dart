import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../content/manga_urls.dart';
import 'l10n.dart';

/// `PrivacySettings`: app-wide privacy choices, kept on this device only (never synced or
/// backed up). The keys match the native app's where the choice is the same.
abstract final class PrivacySettings {
  static const incognitoKey = 'privacy.incognito';

  /// Android: `FLAG_SECURE`, which blocks screenshots and screen recording. The native app's
  /// matching choice covers the screen while it is recorded, since iOS cannot block either.
  static const screenProtectionKey = 'privacy.captureProtection';
  static const appLockKey = 'privacy.appLock';

  /// Seconds the app may stay in the background before it locks again.
  static const lockAfterKey = 'privacy.lockAfter';
  static const encryptedDNSKey = 'privacy.encryptedDNS';

  static const lockAfterChoices = [0, 60, 300, 900];

  /// Root titles show a mark while incognito is on.
  static final incognito = ValueNotifier<bool>(false);

  /// While on, works opened, searches and viewing time are not recorded: no recent works, no
  /// search history, no taste learning from browsing. Saving a work still reaches the library.
  static bool get isIncognito => ContentPreferences.defaults.boolean(incognitoKey) ?? false;

  static bool get protectsScreen => ContentPreferences.defaults.boolean(screenProtectionKey) ?? false;
  static bool get locksApp => ContentPreferences.defaults.boolean(appLockKey) ?? false;
  static int get lockAfter => ContentPreferences.defaults.integerOrNull(lockAfterKey) ?? 0;

  static void load() => incognito.value = isIncognito;

  static void setIncognito(bool on) {
    ContentPreferences.defaults.set(incognitoKey, on);
    incognito.value = on;
  }
}

/// The app's own trips to another screen (the document picker, the share sheet) are not the
/// person leaving the app, so they never lock it.
abstract final class AppAway {
  static int _count = 0;
  static bool get isOnPurpose => _count > 0;

  static Future<T> run<T>(Future<T> Function() body) async {
    _count += 1;
    try {
      return await body();
    } finally {
      // The return to the app is reported a moment after the result arrives.
      Timer(const Duration(seconds: 1), () => _count -= 1);
    }
  }
}

/// `EncryptedDNS`: the app's own encrypted DNS. Website names are looked up over HTTPS (RFC 8484),
/// so a network that reads or rewrites DNS answers can neither see nor redirect them. It covers
/// the app's own connections; web pages and the encrypted-hello route use the system's resolver.
enum EncryptedDNS {
  off,
  cloudflare,
  google,
  quad9;

  String get title => switch (this) {
    off => L10n.text('Off'),
    cloudflare => 'Cloudflare',
    google => 'Google',
    quad9 => 'Quad9',
  };

  /// The resolver by its own address, so reaching it needs no plain DNS lookup.
  Uri? get endpoint => switch (this) {
    off => null,
    cloudflare => Uri.parse('https://1.1.1.1/dns-query'),
    google => Uri.parse('https://8.8.8.8/dns-query'),
    quad9 => Uri.parse('https://9.9.9.9/dns-query'),
  };

  static EncryptedDNS get current {
    final stored = ContentPreferences.defaults.string(PrivacySettings.encryptedDNSKey);
    return values.where((choice) => choice.name == stored).firstOrNull ?? off;
  }
}

/// A small RFC 8484 resolver with a cache that honors each answer's lifetime.
class DnsOverHttps {
  DnsOverHttps({HttpClient? client}) : _client = client ?? (HttpClient()..connectionTimeout = const Duration(seconds: 5));
  final HttpClient _client;
  final _cache = <String, ({InternetAddress address, DateTime expires})>{};

  /// The first address for [host], or null when the resolver had none (the caller then uses
  /// the system's resolver, so a broken resolver never stops the app).
  Future<InternetAddress?> lookup(String host, EncryptedDNS choice) async {
    final endpoint = choice.endpoint;
    if (endpoint == null || InternetAddress.tryParse(host) != null) return null;
    final key = '${choice.name}:$host';
    final cached = _cache[key];
    if (cached != null && cached.expires.isAfter(DateTime.now())) return cached.address;
    for (final type in const [1, 28]) {
      try {
        final request = await _client.getUrl(endpoint.replace(queryParameters: {'dns': query(host, type)})).timeout(const Duration(seconds: 5));
        request.headers.set(HttpHeaders.acceptHeader, 'application/dns-message');
        final response = await request.close().timeout(const Duration(seconds: 5));
        final bytes = await response.fold<BytesBuilder>(BytesBuilder(copy: false), (builder, chunk) => builder..add(chunk));
        if (response.statusCode != 200) continue;
        final answer = parse(bytes.takeBytes(), type);
        if (answer == null) continue;
        _cache[key] = (address: answer.address, expires: DateTime.now().add(Duration(seconds: answer.ttl.clamp(30, 3600))));
        return answer.address;
      } on Object {
        continue;
      }
    }
    return null;
  }

  /// A DNS question for [host] of record [type] (1 = A, 28 = AAAA), base64url without padding.
  static String query(String host, int type) {
    final message = BytesBuilder()
      ..add([0, 0, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0]); // id 0 (RFC 8484 cache-friendly), recursion desired, one question
    for (final label in host.split('.').where((label) => label.isNotEmpty)) {
      final bytes = label.codeUnits;
      message
        ..addByte(bytes.length)
        ..add(bytes);
    }
    message.add([0, type >> 8, type & 0xFF, 0, 1]);
    return base64Url.encode(message.takeBytes()).replaceAll('=', '');
  }

  /// The first answer of [type] in a DNS response, with its lifetime in seconds.
  static ({InternetAddress address, int ttl})? parse(Uint8List data, int type) {
    if (data.length < 12 || data[3] & 0x0F != 0) return null;
    final questions = data[4] << 8 | data[5], answers = data[6] << 8 | data[7];
    var index = 12;
    int skipName(int at) {
      var position = at;
      while (position < data.length) {
        final length = data[position];
        if (length == 0) return position + 1;
        if (length & 0xC0 == 0xC0) return position + 2;
        position += length + 1;
      }
      return data.length;
    }

    for (var i = 0; i < questions; i++) {
      index = skipName(index) + 4;
    }
    for (var i = 0; i < answers && index + 10 <= data.length; i++) {
      index = skipName(index);
      if (index + 10 > data.length) return null;
      final recordType = data[index] << 8 | data[index + 1];
      final ttl = data[index + 4] << 24 | data[index + 5] << 16 | data[index + 6] << 8 | data[index + 7];
      final length = data[index + 8] << 8 | data[index + 9];
      index += 10;
      if (index + length > data.length) return null;
      if (recordType == type && ((type == 1 && length == 4) || (type == 28 && length == 16))) {
        return (address: InternetAddress.fromRawAddress(Uint8List.sublistView(data, index, index + length)), ttl: max(0, ttl));
      }
      index += length;
    }
    return null;
  }
}

/// `SystemProxy`: the HTTP proxy the device's network names (Wi-Fi settings or a profile), which
/// `dart:io` would otherwise ignore. iOS's URLSession follows it on its own.
class SystemProxy {
  const SystemProxy({required this.host, required this.port, this.exclusions = const []});
  final String host;
  final int port;
  final List<String> exclusions;

  static const _channel = MethodChannel('work.nextline.tegnal/privacy');
  static SystemProxy? current;

  /// Reads the proxy again; the app calls this at launch and whenever it returns to the front.
  static Future<void> refresh() async {
    if (!Platform.isAndroid) return;
    try {
      final value = await _channel.invokeMapMethod<String, Object?>('proxy');
      final host = value?['host'], port = value?['port'];
      current = host is String && host.isNotEmpty && port is int && port > 0
          ? SystemProxy(host: host, port: port, exclusions: [for (final item in (value?['exclusions'] as List?) ?? const []) ?(item is String ? item : null)])
          : null;
    } on Object {
      current = null;
    }
  }

  /// `findProxy`'s answer for [url].
  String directive(Uri url) {
    final host = url.host.toLowerCase();
    for (final rule in exclusions) {
      final pattern = rule.trim().toLowerCase();
      if (pattern.isEmpty) continue;
      if (pattern.startsWith('*') ? host.endsWith(pattern.substring(1)) : host == pattern) return 'DIRECT';
    }
    return 'PROXY ${this.host}:$port';
  }
}

/// `NetworkPrivacy`: sets up the app's own HTTP clients for the system proxy and encrypted DNS.
abstract final class NetworkPrivacy {
  static final resolver = DnsOverHttps();

  static void configure(HttpClient client) {
    client.findProxy = (url) => SystemProxy.current?.directive(url) ?? 'DIRECT';
    client.connectionFactory = (url, proxyHost, proxyPort) async {
      if (proxyHost != null && proxyPort != null) return Socket.startConnect(proxyHost, proxyPort);
      final address = await resolver.lookup(url.host, EncryptedDNS.current);
      final port = url.hasPort ? url.port : (url.scheme == 'https' ? 443 : 80);
      if (url.scheme != 'https') return Socket.startConnect(address ?? url.host, port);
      if (address == null) return SecureSocket.startConnect(url.host, port);
      // Connected by the resolved address; the server name and certificate stay the website's own.
      final task = await Socket.startConnect(address, port);
      return ConnectionTask.fromSocket(task.socket.then((socket) => SecureSocket.secure(socket, host: url.host)), task.cancel);
    };
  }
}
