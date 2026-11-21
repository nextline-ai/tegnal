import 'dart:convert';
import 'dart:math' as math;

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../../core/booru/booru_models.dart';

/// A video the browser's own player streams, as iOS plays every image-mode video. Used when the
/// server refuses the app's player: the web view carries the validated browser's connection and
/// cookies, reads only the ranges it needs and starts as soon as the first ones arrive.
class BooruWebVideo extends StatefulWidget {
  const BooruWebVideo({
    super.key,
    required this.url,
    required this.server,
    required this.post,
    required this.active,
    required this.muted,
    required this.onStatus,
    required this.onSize,
    required this.onMuted,
  });

  final String url;
  final BooruServer server;
  final BooruPost post;
  final bool active;
  final bool muted;

  /// `loading`, `ready`, `playing`, `ended` or `error`, as the viewer's statuses read.
  final ValueChanged<String> onStatus;
  final ValueChanged<Size> onSize;
  final ValueChanged<bool> onMuted;

  @override
  State<BooruWebVideo> createState() => _BooruWebVideoState();

  static String _escape(String text) =>
      text.replaceAll('&', '&amp;').replaceAll('"', '&quot;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll("'", '&#39;');

  /// The page: one video and the script that reports its state through [channel].
  static String document({required String url, required bool active, required bool muted, required bool loop, required String nonce}) {
    final options = '${muted ? ' muted' : ''}${loop ? ' loop' : ''}';
    return '''
<!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; media-src https: blob:; style-src 'unsafe-inline'; script-src 'nonce-$nonce'; base-uri 'none'; form-action 'none'">
<meta name="referrer" content="origin"><style>
html,body{margin:0;width:100%;height:100%;background:#000;overflow:hidden}
video{display:block;width:100%;height:100%;object-fit:contain;background:#000}
</style></head><body><video id="media" src="${_escape(url)}" controls playsinline preload="metadata"$options></video>
<script nonce="$nonce">
const media=document.getElementById('media');
const send=value=>$channel.postMessage(JSON.stringify(value));
let allowed=$active,muted=$muted,retries=0,attempts=0,playTimer=null;
const play=()=>{
  if(!allowed||document.hidden)return;
  clearTimeout(playTimer);
  const result=media.play();
  result?.catch(()=>{if(++attempts<5)playTimer=setTimeout(play,400*attempts);});
};
media.addEventListener('loadedmetadata',()=>send({width:media.videoWidth,height:media.videoHeight}));
media.addEventListener('loadeddata',()=>{retries=0;send({status:media.ended?'ended':media.paused?'ready':'playing'});play();});
media.addEventListener('canplay',play);
media.addEventListener('playing',()=>send({status:'playing'}));
media.addEventListener('pause',()=>{if(!media.ended)send({status:'ready'});});
media.addEventListener('ended',()=>send({status:'ended'}));
media.addEventListener('volumechange',()=>{if(media.muted!==muted){muted=media.muted;send({muted});}});
// Two quiet retries, as the viewer makes for images, before failing.
media.addEventListener('error',()=>{
  if(retries>=2){send({status:'error'});return;}
  send({status:'loading'});
  const attempt=++retries;
  setTimeout(()=>media.load(),attempt*500);
});
window.setActive=value=>{allowed=value;attempts=0;if(value)play();else{clearTimeout(playTimer);media.pause();}};
window.setMuted=value=>{muted=value;media.muted=value;};
document.addEventListener('visibilitychange',()=>{if(document.hidden)media.pause();else play();});
send({status:'loading'});
</script></body></html>''';
  }

  static const channel = 'TegnalVideo';
}

class _BooruWebVideoState extends State<BooruWebVideo> {
  late final WebViewController _controller;

  @override
  void initState() {
    super.initState();
    final controller = _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFF000000))
      ..addJavaScriptChannel(BooruWebVideo.channel, onMessageReceived: _received);
    final platform = controller.platform;
    // The viewer starts the video itself, with sound when the person turned it on.
    if (platform is AndroidWebViewController) platform.setMediaPlaybackRequiresUserGesture(false);
    final random = math.Random.secure();
    final nonce = base64Url.encode(List<int>.generate(16, (_) => random.nextInt(256)));
    controller.loadHtmlString(
      BooruWebVideo.document(url: widget.url, active: widget.active, muted: widget.muted, loop: widget.post.isUgoira, nonce: nonce),
      baseUrl: widget.server.baseURL,
    );
  }

  @override
  void didUpdateWidget(BooruWebVideo old) {
    super.didUpdateWidget(old);
    if (old.active != widget.active) _run('window.setActive?.(${widget.active})');
    if (old.muted != widget.muted) _run('window.setMuted?.(${widget.muted})');
  }

  @override
  void dispose() {
    // Stops the sound at once; the view itself goes with the widget.
    _run('window.setActive?.(false)');
    super.dispose();
  }

  void _run(String script) => _controller.runJavaScript(script).then((_) {}, onError: (_) {});

  void _received(JavaScriptMessage message) {
    if (!mounted) return;
    final Object? value;
    try {
      value = jsonDecode(message.message);
    } on FormatException {
      return;
    }
    if (value is! Map) return;
    if (value['status'] case final String status) widget.onStatus(status);
    if (value['muted'] case final bool muted) widget.onMuted(muted);
    if ((value['width'], value['height']) case (final num width, final num height) when width > 0 && height > 0) {
      widget.onSize(Size(width.toDouble(), height.toDouble()));
    }
  }

  @override
  Widget build(BuildContext context) => WebViewWidget(controller: _controller);
}
