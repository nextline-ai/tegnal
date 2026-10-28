package work.nextline.tegnal

import android.app.Activity
import android.graphics.Color
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.view.View
import android.view.ViewGroup
import android.webkit.CookieManager
import android.webkit.SslErrorHandler
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import android.net.http.SslError
import android.widget.FrameLayout
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import org.json.JSONTokener
import java.nio.charset.StandardCharsets

/** One-shot same-origin browser-session GET. No account/API headers cross into JS. */
internal class VerifiedWebFetch(private val activity: Activity) {
    private val handler = Handler(Looper.getMainLooper())
    private val requests = mutableMapOf<String, Job>()
    private val preferences = activity.getSharedPreferences("verified_browser_routes", Activity.MODE_PRIVATE)
    private val persistedOrigins = preferences.getStringSet("origins", emptySet())?.toMutableSet() ?: mutableSetOf()
    private val verifiedOrigins = persistedOrigins.toMutableSet()
    private val maxResponseBytes = 12 * 1024 * 1024

    private fun origin(uri: Uri): String? {
        if (BrowserSession.secureUri(uri.toString()) == null) return null
        val port = if (uri.port == -1) 443 else uri.port
        return "https://${uri.host!!.lowercase()}:$port"
    }

    private fun persist() { preferences.edit().putStringSet("origins", persistedOrigins.toSet()).apply() }
    fun isPersisted(url: String?): Boolean {
        val uri = BrowserSession.secureUri(url) ?: return false
        return origin(uri) in persistedOrigins
    }
    fun invalidate(url: String?) {
        val uri = BrowserSession.secureUri(url) ?: return
        val key = origin(uri) ?: return
        persistedOrigins.remove(key)
        verifiedOrigins.remove(key)
        persist()
    }
    fun invalidateStoredDomains(domains: List<String>) {
        val safe = domains.take(64).map { it.lowercase() }.filter { it.isNotBlank() && it.length <= 253 }
        persistedOrigins.removeAll { value ->
            val host = Uri.parse(value).host?.lowercase() ?: return@removeAll false
            safe.any { domain -> host == domain || host.endsWith(".$domain") }
        }
        persist()
    }
    private fun invalidate(uri: Uri) = invalidate(uri.toString())

    fun allowBrowserOrigin(url: String?) {
        val uri = BrowserSession.secureUri(url) ?: return
        origin(uri)?.let(verifiedOrigins::add)
    }

    fun get(call: io.flutter.plugin.common.MethodCall, result: MethodChannel.Result) {
        val id = call.argument<String>("requestId")
        val url = call.argument<String>("url")
        val uri = BrowserSession.secureUri(url)
        val path = uri?.path.orEmpty()
        val listRequest = path.endsWith("/posts.json") &&
            uri?.queryParameterNames?.all { it.lowercase() in setOf("tags", "limit", "page") } == true
        val detailRequest = Regex("/posts/[0-9]+\\.json$").containsMatchIn(path) && uri?.encodedQuery == null
        if (id.isNullOrBlank() || id.length > 80 || uri == null ||
            !(listRequest || detailRequest) ||
            origin(uri) !in verifiedOrigins || requests.size >= 2 || requests.containsKey(id)) {
            result.error("unavailable", "Browser-session retry is unavailable.", null)
            return
        }
        try {
            val job = Job(id, uri, result)
            requests[id] = job
            try { job.start() } catch (_: Exception) { job.finish("unavailable", "Browser-session retry is unavailable.") }
        } catch (_: Exception) {
            result.error("unavailable", "Browser-session retry is unavailable.", null)
        }
    }

    fun cancel(id: String?) { id?.let { requests[it]?.finish("aborted", "Request cancelled.") } }
    fun reset() {
        requests.values.toList().forEach { it.finish("aborted", "Browser session reset.") }
        verifiedOrigins.clear()
        persistedOrigins.clear()
        persist()
    }
    fun dispose() { requests.values.toList().forEach { it.finish("closed", "Browser session closed.") }; verifiedOrigins.clear() }

    private inner class Job(val id: String, val uri: Uri, val result: MethodChannel.Result) {
        private var done = false
        private var fetching = false
        private val cookieBefore = CookieManager.getInstance().getCookie(uri.toString())
        private val root = activity.window.decorView as ViewGroup
        private val webView = WebView(activity)
        private val deadline = Runnable { finish("timeout", "Browser-session request timed out.") }
        private val poll = object : Runnable {
            override fun run() {
                if (done) return
                webView.evaluateJavascript("JSON.stringify(window.__tegnalResult || null)") { raw ->
                    if (done) return@evaluateJavascript
                    try {
                        val decoded = JSONTokener(raw).nextValue()
                        if (decoded is String && decoded != "null") {
                            val obj = JSONObject(decoded)
                            if (obj.optString("error").isNotEmpty()) {
                                finish("network_error", "The browser-session request failed.")
                            } else {
                                val status = obj.getInt("status")
                                val bytes = obj.getString("body").toByteArray(StandardCharsets.UTF_8)
                                if (bytes.size > maxResponseBytes) { finish("too_large", "Response is too large."); return@evaluateJavascript }
                                finishSuccess(status, bytes)
                            }
                        } else handler.postDelayed(this, 100)
                    } catch (_: Exception) { finish("network_error", "The browser-session response was invalid.") }
                }
            }
        }

        fun start() {
            webView.apply {
                settings.javaScriptEnabled = true
                settings.domStorageEnabled = false
                settings.allowFileAccess = false
                settings.allowContentAccess = false
                settings.mixedContentMode = android.webkit.WebSettings.MIXED_CONTENT_NEVER_ALLOW
                CookieManager.getInstance().setAcceptThirdPartyCookies(this, false)
                importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
                isClickable = false
                isFocusable = false
                isFocusableInTouchMode = false
                alpha = 0f
                setBackgroundColor(Color.TRANSPARENT)
                webViewClient = object : WebViewClient() {
                    override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean =
                        request.isForMainFrame && origin(request.url) != origin(uri)
                    override fun onReceivedSslError(view: WebView, handler: SslErrorHandler, error: SslError) {
                        handler.cancel(); finish("certificate_error", "The secure connection could not be verified.")
                    }
                    override fun onReceivedError(view: WebView, request: WebResourceRequest, error: WebResourceError) {
                        if (request.isForMainFrame) finish("network_error", "The website could not connect.")
                    }
                    override fun onPageFinished(view: WebView, url: String?) {
                        if (done || fetching || url == null || origin(Uri.parse(url)) != origin(uri)) return
                        fetching = true
                        val target = JSONObject.quote(uri.toString())
                        val script = """(function(){
                            window.__tegnalResult=null;
                            fetch($target,{credentials:'same-origin',redirect:'error',headers:{'Accept':'application/json, application/xml;q=0.9, text/html;q=0.8'}})
                            .then(async function(r){
                              const reader=r.body && r.body.getReader(); if(!reader) throw Error('body');
                              let total=0, chunks=[], decoder=new TextDecoder();
                              while(true){const part=await reader.read(); if(part.done) break;
                                total+=part.value.length; if(total>$maxResponseBytes){await reader.cancel();throw Error('size');}
                                chunks.push(decoder.decode(part.value,{stream:true}));}
                              chunks.push(decoder.decode()); window.__tegnalResult={status:r.status,body:chunks.join('')};
                            }).catch(function(){window.__tegnalResult={error:'request'};});
                          })();""".trimIndent()
                        view.evaluateJavascript(script, null)
                        handler.post(poll)
                    }
                }
            }
            root.addView(webView, FrameLayout.LayoutParams(1, 1))
            handler.postDelayed(deadline, 30_000)
            val base = uri.buildUpon().path("/").clearQuery().fragment(null).build().toString()
            // An app-owned blank document avoids executing the site's page
            // scripts. Its HTTPS base URL gives fetch the verified origin.
            val html = "<html><head><meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; connect-src 'self'\"></head><body></body></html>"
            webView.loadDataWithBaseURL(base, html, "text/html", "UTF-8", null)
        }

        fun finish(code: String, message: String) {
            if (done) return
            if (code != "aborted" && code != "closed") invalidate(uri)
            cleanup()
            result.error(code, message, null)
        }
        private fun finishSuccess(status: Int, body: ByteArray) {
            if (done) return
            val prefix = body.take(4096).toByteArray().toString(StandardCharsets.UTF_8).trimStart { it.isWhitespace() || it == '\uFEFF' }
            val expected = if (uri.path.orEmpty().endsWith("/posts.json")) '[' else '{'
            val success = status in 200..299 && prefix.startsWith(expected)
            if (success) {
                origin(uri)?.let { persistedOrigins.add(it); persist() }
            } else invalidate(uri)
            val cookieChanged = cookieBefore != CookieManager.getInstance().getCookie(uri.toString())
            cleanup()
            result.success(mapOf("statusCode" to status, "body" to body, "cookieChanged" to cookieChanged))
        }
        private fun cleanup() {
            done = true
            handler.removeCallbacks(deadline)
            handler.removeCallbacks(poll)
            requests.remove(id)
            webView.stopLoading()
            root.removeView(webView)
            webView.destroy()
        }
    }
}
