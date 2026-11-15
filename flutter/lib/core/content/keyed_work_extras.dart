import 'gallery_content.dart';

/// A comment under a work on a catalog that keeps them.
class WorkComment {
  const WorkComment({required this.id, required this.author, required this.text, this.posted, this.score});
  final int id;
  final String author;
  final DateTime? posted;
  final int? score;
  final String text;

  /// The uploader's own note, shown first and never scored.
  bool get isUploader => id == 0;
}

/// A torrent a catalog offers for a work.
class WorkTorrent {
  const WorkTorrent({required this.name, required this.url, this.size, this.seeds, this.peers, this.downloads, this.posted, this.uploader, this.hash});
  final String name;
  final Uri url;
  final String? size;
  final int? seeds;
  final int? peers;
  final int? downloads;
  final String? posted;
  final String? uploader;
  final String? hash;

  Uri? get magnet {
    final hash = this.hash;
    if (hash == null) return null;
    return Uri(scheme: 'magnet', queryParameters: {'xt': 'urn:btih:$hash', 'dn': name});
  }
}

/// One of the account's favorites categories on a catalog that keeps them.
class FavoriteCategory {
  const FavoriteCategory({required this.id, required this.name, required this.count});
  final int id;
  final String name;
  final int count;
}

/// A work's tag on an account-based catalog, as the website spells it, with the account's vote.
class WorkTagVote {
  const WorkTagVote(this.tag, this.vote);

  /// `namespace:name` as the website writes it, with spaces.
  final String tag;

  /// 1 voted up, -1 voted down, 0 not voted.
  final int vote;

  String get namespace => tag.contains(':') ? tag.substring(0, tag.indexOf(':')) : '';
  String get name => tag.contains(':') ? tag.substring(tag.indexOf(':') + 1) : tag;

  /// The namespace as the app's searches write it.
  String get localNamespace => switch (namespace) {
    'parody' => 'series',
    'other' => 'tag',
    _ => namespace,
  };

  @override
  bool operator ==(Object other) => other is WorkTagVote && other.tag == tag && other.vote == vote;
  @override
  int get hashCode => Object.hash(tag, vote);
  @override
  String toString() => 'WorkTagVote($tag, $vote)';
}

/// One archive an account-based catalog offers for a work.
class WorkArchiveOption {
  const WorkArchiveOption({required this.kind, required this.button, required this.cost, required this.size, required this.available});

  /// The website's name for the kind of archive: the original files or resized ones.
  final String kind;

  /// The label of the website's own button, sent back with the request.
  final String button;
  final String cost;
  final String size;
  final bool available;
  bool get isOriginal => kind == 'org';

  @override
  bool operator ==(Object other) =>
      other is WorkArchiveOption && other.kind == kind && other.button == button && other.cost == cost && other.size == size && other.available == available;
  @override
  int get hashCode => Object.hash(kind, button, cost, size, available);
}

/// What an account-based catalog asks for a work's archives, and what the account holds.
class WorkArchiveOffer {
  WorkArchiveOffer({this.funds, List<WorkArchiveOption>? options}) : options = options ?? [];
  String? funds;
  final List<WorkArchiveOption> options;
}

/// One of the account's settings profiles on a website that keeps several.
class SiteSettingsProfile {
  const SiteSettingsProfile(this.id, this.name, {this.selected = false});
  final int id;
  final String name;
  final bool selected;
  @override
  bool operator ==(Object other) => other is SiteSettingsProfile && other.id == id && other.name == name && other.selected == selected;
  @override
  int get hashCode => Object.hash(id, name, selected);
}

/// An answer the website gave in its own words, shown as it is.
class SiteMessage implements Exception {
  const SiteMessage(this.text);
  final String text;
  @override
  bool operator ==(Object other) => other is SiteMessage && other.text == text;
  @override
  int get hashCode => text.hashCode;
  @override
  String toString() => text;
}

/// What a work's page on an account-based catalog says besides its pages: how it is rated, how
/// often it is kept, who uploaded it, and the conversation under it.
class WorkExtras {
  WorkExtras({
    this.rating,
    this.ratingCount,
    this.favorited,
    this.posted,
    this.uploader,
    this.fileSize,
    this.length,
    this.parentID,
    this.favoriteCategory,
    this.favoriteName,
    this.torrentCount = 0,
    this.torrentsURL,
    this.comments = const [],
    this.hasMoreComments = false,
    this.canRate = false,
    this.tagVotes = const [],
    this.canComment = false,
    this.archiveURL,
  });
  double? rating;
  int? ratingCount;
  int? favorited;
  DateTime? posted;
  String? uploader;
  String? fileSize;
  int? length;
  int? parentID;

  /// The account's favorites category holding this work, from 0, when it is a favorite.
  int? favoriteCategory;
  String? favoriteName;
  int torrentCount;
  Uri? torrentsURL;
  List<WorkComment> comments;

  /// The page shows only the newest comments until asked for all of them.
  bool hasMoreComments;

  /// The signed-in account's key for rating, kept only in memory.
  bool canRate;

  /// The work's tags with the account's votes, when the page lets the account vote.
  List<WorkTagVote> tagVotes;

  /// Whether the page offers the account a comment form.
  bool canComment;

  /// The work's archive page, when the page links one.
  Uri? archiveURL;

  bool get hasContent => rating != null || favorited != null || uploader != null || fileSize != null || comments.isNotEmpty || torrentCount > 0;
}

/// The signed-in account's id and key the page hands its own scripts for rating.
class WorkAPIKey {
  const WorkAPIKey(this.uid, this.key);
  final int uid;
  final String key;
  @override
  bool operator ==(Object other) => other is WorkAPIKey && other.uid == uid && other.key == key;
  @override
  int get hashCode => Object.hash(uid, key);
}

/// Reads the shapes these pages share. Only page structure is matched, never a site's name.
abstract final class KeyedWorkPage {
  static WorkExtras extras(String html) {
    final extras = WorkExtras();
    for (final (label, value) in _detailRows(html)) {
      final text = plain(value);
      switch (label.toLowerCase()) {
        case 'posted':
          extras.posted = postedDate(text);
        case 'parent':
          extras.parentID = int.tryParse(firstCapture(r'/g/([0-9]{1,10})/', value) ?? '');
        case 'file size':
          extras.fileSize = text.isEmpty ? null : text;
        case 'length':
          extras.length = int.tryParse((firstCapture(r'([0-9][0-9,]*)', text) ?? '').replaceAll(',', ''));
        case 'favorited':
          extras.favorited = _favoritedCount(text);
      }
    }
    final label = firstCapture(r'id="rating_label"[^>]*>([^<]*)<', html);
    final rating = label == null ? null : double.tryParse(firstCapture(r'([0-9]+(?:\.[0-9]+)?)', label) ?? '');
    if (rating != null && rating >= 0 && rating <= 5) extras.rating = rating;
    final count = firstCapture(r'id="rating_count"[^>]*>([0-9,]+)<', html);
    if (count != null) extras.ratingCount = int.tryParse(count.replaceAll(',', ''));
    final uploader = firstCapture(r'<div id="gdn"[^>]*>(.*?)</div>', html);
    if (uploader != null) {
      final name = plain(uploader);
      extras.uploader = name.isEmpty ? null : name;
    }
    final torrents = firstCapture(r'>\s*Torrent Download\s*\(\s*([0-9]+)\s*\)', html);
    if (torrents != null) extras.torrentCount = int.tryParse(torrents) ?? 0;
    final address = firstCapture(r'''['"]([^'"]*gallerytorrents\.php\?[^'"]*)['"]''', html);
    if (address != null) extras.torrentsURL = Uri.tryParse(NativeGallery.decodeEntities(address));
    final favorite = favoriteState(html);
    extras.favoriteCategory = favorite.$1;
    extras.favoriteName = favorite.$2;
    extras.comments = comments(html);
    extras.hasMoreComments = RegExp(r'[?&]hc=1').hasMatch(html);
    extras.canRate = apiKey(html) != null;
    extras.tagVotes = tagVotes(html);
    extras.canComment = html.contains('name="commenttext_new"');
    final archive = firstCapture(r"""['"]([^'"]*archiver\.php\?[^'"]*)['"]""", html);
    if (archive != null) extras.archiveURL = Uri.tryParse(NativeGallery.decodeEntities(archive));
    return extras;
  }

  /// The tags of a work's tag pane, each with the account's vote: the page marks a tag voted up
  /// or down on its link.
  static List<WorkTagVote> tagVotes(String html) {
    final seen = <String>{};
    final result = <WorkTagVote>[];
    for (final match in RegExp(r'<a\b[^>]*\bid="ta_([^"]+)"[^>]*>').allMatches(html)) {
      final link = match[0]!;
      // The menu call names the tag with its spaces; the link's own id writes them as underscores.
      final named = firstCapture(r"toggle_tagmenu\(\s*[0-9]+\s*,\s*'([^']+)'", link);
      final tag = (named == null ? match[1]!.replaceAll('_', ' ') : NativeGallery.decodeEntities(named)).trim();
      if (tag.isEmpty || tag.length > 200 || !seen.add(tag)) continue;
      final classes = (firstCapture(r'\bclass="([^"]*)"', link) ?? '').split(' ');
      result.add(WorkTagVote(tag, classes.contains('tup') ? 1 : (classes.contains('tdn') ? -1 : 0)));
    }
    return result;
  }

  /// The archives a work's archive page offers for download, with their cost and size, and the
  /// account's funds. A greyed-out offer the page marks unavailable.
  static WorkArchiveOffer archiveOffer(String html) {
    final offer = WorkArchiveOffer();
    final funds = firstCapture(r'Current Funds:\s*</p>\s*<p>(.*?)</p>', html);
    if (funds != null) {
      final text = plain(funds).replaceAll('[?]', '');
      final match = RegExp(r'([0-9][0-9,]*)\s*GP.*?([0-9][0-9,]*)\s*Credits', dotAll: true).firstMatch(text);
      if (match != null) offer.funds = '${match[1]} GP · ${match[2]} Credits';
    }
    final pattern = RegExp(r'Download Cost:(.*?)</div>\s*<form\b[^>]*>(.*?)</form>\s*<p>\s*Estimated Size:(.*?)</p>', caseSensitive: false, dotAll: true);
    for (final match in pattern.allMatches(html)) {
      final form = match[2]!;
      final kind = firstCapture(r'name="dltype"[^>]*value="([a-z]+)"', form);
      final button = firstCapture(r'name="dlcheck"[^>]*value="([^"]+)"', form);
      if (kind == null || button == null) continue;
      final cost = plain(match[1]!), size = plain(match[3]!);
      offer.options.add(
        WorkArchiveOption(
          kind: kind,
          button: NativeGallery.decodeEntities(button),
          cost: cost,
          size: size,
          available: cost.isNotEmpty && cost.toUpperCase() != 'N/A' && !form.contains('disabled'),
        ),
      );
    }
    return offer;
  }

  /// Where the archive the page just prepared downloads from.
  static Uri? archiveDownloadURL(String html) {
    final address = firstCapture(r'document\.location\s*=\s*"([^"]+)"', html);
    final url = address == null ? null : Uri.tryParse(NativeGallery.decodeEntities(address));
    if (url == null) return null;
    return url.replace(queryParameters: {...url.queryParameters, 'start': '1'});
  }

  /// A page's own short message, as an answer that took no action gives it.
  static String? message(String html) {
    final body = firstCapture(r'<div id="db"[^>]*>(.*)</div>', html) ?? firstCapture(r'<body[^>]*>(.*)</body>', html) ?? html;
    final text = plain(body.replaceAll(RegExp(r'<h1\b.*?</h1>', caseSensitive: false, dotAll: true), ''));
    return text.isNotEmpty && text.length <= 400 ? text : null;
  }

  /// The account's settings profiles from the website's settings page.
  static List<SiteSettingsProfile> settingsProfiles(String html) {
    final select = firstCapture(r'<select\b[^>]*name="profile_set"[^>]*>(.*?)</select>', html);
    if (select == null) return [];
    return [
      for (final match in RegExp(r'<option\b([^>]*)>([^<]*)</option>', caseSensitive: false).allMatches(select))
        if (int.tryParse(firstCapture(r'value="([0-9]{1,4})"', match[1]!) ?? '') case final value?)
          SiteSettingsProfile(value, plain(match[2]!).isEmpty ? '$value' : plain(match[2]!), selected: match[1]!.contains('selected')),
    ];
  }

  static WorkAPIKey? apiKey(String html) {
    final uid = int.tryParse(firstCapture(r'\bvar\s+apiuid\s*=\s*([0-9]{1,12})\s*;', html) ?? '');
    final key = firstCapture(r'\bvar\s+apikey\s*=\s*"([0-9a-f]{8,64})"\s*;', html);
    if (uid == null || uid <= 0 || key == null) return null;
    return WorkAPIKey(uid, key);
  }

  /// The favorites category shown on the page: its number from the icon, and its name from the link.
  static (int?, String?) favoriteState(String html) {
    final link = firstCapture(r'<a\b[^>]*\bid="favoritelink"[^>]*>(.*?)</a>', html);
    if (link == null) return (null, null);
    final name = plain(link);
    final block = firstCapture(r'<div id="fav"[^>]*>(.*?)</div>\s*</div>', html) ?? firstCapture(r'<div id="fav"[^>]*>(.*?)</div>', html);
    final offset = int.tryParse(block == null ? '' : firstCapture(r'background-position\s*:\s*0(?:px)?\s+-([0-9]+)px', block) ?? '');
    if (offset == null || offset < 2 || (offset - 2) % 19 != 0 || (offset - 2) ~/ 19 > 9) return (null, null);
    return ((offset - 2) ~/ 19, name.isEmpty ? null : name);
  }

  static List<WorkComment> comments(String html) {
    final result = <WorkComment>[];
    final seen = <int>{};
    for (final block in html.split('<div class="c1">').skip(1)) {
      final id = int.tryParse(firstCapture(r'<div class="c6"[^>]*\bid="comment_([0-9]{1,10})"', block) ?? '');
      final body = firstCapture(r'<div class="c6"[^>]*>(.*?)</div>', block);
      if (id == null || body == null || !seen.add(id)) continue;
      final header = firstCapture(r'<div class="c3"[^>]*>(.*?)</div>', block) ?? '';
      final linked = firstCapture(r'<a\b[^>]*>([^<]+)</a>', header);
      final author = linked != null ? plain(linked) : plain(header.split('by:').last);
      final postedText = firstCapture(r'Posted on\s+(.+?)\s+by', plain(header));
      final scoreText = firstCapture(r'id="comment_score_[0-9]+"[^>]*>\s*([+-]?[0-9]+)\s*<', block);
      final text = plain(body, keepsLines: true);
      if (text.isEmpty) continue;
      result.add(
        WorkComment(
          id: id,
          author: author.isEmpty ? '?' : author,
          posted: postedText == null ? null : commentDate(postedText),
          score: id == 0 || scoreText == null ? null : int.tryParse(scoreText.replaceAll('+', '')),
          text: text,
        ),
      );
    }
    return result;
  }

  static List<WorkTorrent> torrents(String html) {
    final result = <WorkTorrent>[];
    final seen = <String>{};
    for (final form in html.split('<form').skip(1)) {
      final match = RegExp(r'<a\b[^>]*\bhref="([^"]+\.torrent[^"]*)"[^>]*>([^<]+)</a>', caseSensitive: false, dotAll: true).firstMatch(form);
      final url = match == null ? null : Uri.tryParse(NativeGallery.decodeEntities(match.group(1)!));
      if (url == null || url.scheme != 'https' || !seen.add(url.toString())) continue;
      String? field(String name) {
        final value = firstCapture('$name:\\s*</span>\\s*(?:<span[^>]*>)?\\s*([^<]+?)\\s*<', form);
        final text = value == null ? '' : plain(value);
        return text.isEmpty ? null : text;
      }

      result.add(
        WorkTorrent(
          name: plain(match!.group(2)!),
          url: url,
          size: field('Size'),
          seeds: int.tryParse(field('Seeds') ?? ''),
          peers: int.tryParse(field('Peers') ?? ''),
          downloads: int.tryParse(field('Downloads') ?? ''),
          posted: field('Posted'),
          uploader: field('Uploader'),
          hash: firstCapture(r'([0-9a-fA-F]{40})', url.path)?.toLowerCase(),
        ),
      );
    }
    return result;
  }

  /// The text of each innermost `div`, in order.
  static List<String> textsInDivs(String html) => [
    for (final match in RegExp(r'<div\b[^>]*>([^<]*)</div>', caseSensitive: false).allMatches(html)) plain(match.group(1)!),
  ];

  static Iterable<(String, String)> _detailRows(String html) => RegExp(
    r'<td class="gdt1"[^>]*>\s*([^<:]+?)\s*:\s*</td>\s*<td class="gdt2"[^>]*>(.*?)</td>',
    caseSensitive: false,
    dotAll: true,
  ).allMatches(html).map((match) => (match.group(1)!, match.group(2)!));

  static int? _favoritedCount(String text) {
    final lowered = text.toLowerCase();
    if (lowered.startsWith('never')) return 0;
    if (lowered.startsWith('once')) return 1;
    return int.tryParse((firstCapture(r'([0-9][0-9,]*)', text) ?? '').replaceAll(',', ''));
  }

  static DateTime? postedDate(String text) {
    final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2})$').firstMatch(text.trim());
    if (match == null) return null;
    final parts = [for (var index = 1; index <= 5; index++) int.parse(match.group(index)!)];
    return DateTime.utc(parts[0], parts[1], parts[2], parts[3], parts[4]);
  }

  static const _months = ['january', 'february', 'march', 'april', 'may', 'june', 'july', 'august', 'september', 'october', 'november', 'december'];

  static DateTime? commentDate(String text) {
    final value = text.replaceAll(' UTC', '').trim();
    final match = RegExp(r'^(\d{1,2}) ([A-Za-z]+) (\d{4}), (\d{2}):(\d{2})$').firstMatch(value);
    if (match == null) return null;
    final month = _months.indexOf(match.group(2)!.toLowerCase());
    if (month < 0) return null;
    return DateTime.utc(int.parse(match.group(3)!), month + 1, int.parse(match.group(1)!), int.parse(match.group(4)!), int.parse(match.group(5)!));
  }

  /// Text without markup; line breaks stay when asked, other whitespace runs fold to one space.
  static String plain(String html, {bool keepsLines = false}) {
    var text = html;
    if (keepsLines) text = text.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
    text = text.replaceAll(RegExp(r'<[^>]+>'), '');
    text = NativeGallery.decodeEntities(text).replaceAll(' ', ' ');
    if (keepsLines) {
      return text.split('\n').map((line) => line.replaceAll(RegExp(r'[ \t]+'), ' ').trim()).join('\n').replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
    }
    return text.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static String? firstCapture(String pattern, String text) => RegExp(pattern, caseSensitive: false, dotAll: true).firstMatch(text)?.group(1);
}

/// Catalogs that keep ratings, comments and torrents for their works.
abstract interface class WorkExtrasProviding {
  /// Null when the website keeps none of this for its works.
  Future<WorkExtras?> extras(int id);
  Future<List<WorkComment>> allComments(int id);
  Future<List<WorkTorrent>> torrents(int id);

  /// Rates a work from 1 to 10 half-stars; returns the new average and count.
  Future<(double, int)> rate(int id, int halfStars);

  /// Votes a tag of a work up (1) or down (-1); voting against the account's vote withdraws it.
  /// Returns the work's tags with the votes as they now stand.
  Future<List<WorkTagVote>> voteTag(int id, {required String tag, required int vote});

  /// Posts a comment under a work and returns the comments as they now stand.
  Future<List<WorkComment>> postComment(int id, String text);

  /// What the website asks for the work's archives.
  Future<WorkArchiveOffer> archiveOffer(int id);

  /// Has the website prepare an archive, charging what the offer showed; returns where it downloads from.
  Future<Uri> archiveDownloadURL(int id, WorkArchiveOption option);
}
