package work.nextline.tegnal

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.webkit.CookieManager
import android.webkit.WebSettings
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** CookieManager is the only cookie store. Nothing is logged or exported. */
object BrowserSession {
    const val REQUEST_CODE = 7102
    private var pending: MethodChannel.Result? = null
    private var pendingUrl: String? = null
    private var verifiedFetch: VerifiedWebFetch? = null

    fun secureUri(raw: String?): Uri? {
        if (raw.isNullOrBlank()) return null
        return runCatching { Uri.parse(raw) }.getOrNull()?.takeIf {
            it.scheme == "https" && !it.host.isNullOrBlank() && it.userInfo == null
        }
    }

    fun register(activity: Activity, engine: FlutterEngine) {
        verifiedFetch?.dispose()
        verifiedFetch = VerifiedWebFetch(activity)
        MethodChannel(engine.dartExecutor.binaryMessenger, "work.nextline.tegnal/browser")
            .setMethodCallHandler { call, result ->
                if (call.method == "invalidateStoredDomains") {
                    verifiedFetch?.invalidateStoredDomains(call.argument<List<String>>("domains") ?: emptyList())
                    result.success(null)
                    return@setMethodCallHandler
                }
                if (call.method == "cancelVerifiedGet") {
                    verifiedFetch?.cancel(call.argument<String>("requestId"))
                    result.success(null)
                    return@setMethodCallHandler
                }
                if (call.method == "verifiedGet") {
                    verifiedFetch?.get(call, result) ?: result.error("unavailable", "Browser-session retry is unavailable.", null)
                    return@setMethodCallHandler
                }
                val uri = secureUri(call.argument<String>("url"))
                if (uri == null) {
                    result.error("invalid_url", "Only HTTPS websites can be opened.", null)
                    return@setMethodCallHandler
                }
                when (call.method) {
                    "hasVerifiedRoute" -> result.success(verifiedFetch?.isPersisted(uri.toString()) == true)
                    "open" -> {
                        if (pending != null) {
                            result.error("busy", "A browser is already open.", null)
                        } else {
                            verifiedFetch?.invalidate(uri.toString())
                            pending = result
                            pendingUrl = uri.toString()
                            try {
                                val browserIntent = Intent(activity, BrowserActivity::class.java)
                                    .putExtra("url", uri.toString())
                                val labels = call.argument<Map<String, String>>("labels") ?: emptyMap()
                                for (key in listOf("close", "back", "retry", "connectionError", "certificateError")) {
                                    labels[key]?.takeIf { it.length <= 1000 }?.let { browserIntent.putExtra(key, it) }
                                }
                                activity.startActivityForResult(
                                    browserIntent, REQUEST_CODE
                                )
                            } catch (error: Exception) {
                                pending = null
                                pendingUrl = null
                                result.error("unavailable", "Unable to open the browser.", null)
                            }
                        }
                    }
                    "headersFor" -> {
                        val headers = mutableMapOf("User-Agent" to WebSettings.getDefaultUserAgent(activity))
                        CookieManager.getInstance().getCookie(uri.toString())
                            ?.takeIf { it.isNotBlank() }?.let { headers["Cookie"] = it }
                        result.success(headers)
                    }
                    "shareLink" -> {
                        try {
                            val intent = Intent(Intent.ACTION_SEND).apply {
                                type = "text/plain"
                                putExtra(Intent.EXTRA_TEXT, uri.toString())
                                putExtra(Intent.EXTRA_SUBJECT, call.argument<String>("title").orEmpty().take(500))
                            }
                            activity.startActivity(Intent.createChooser(intent, null))
                            result.success(null)
                        } catch (error: Exception) {
                            result.error("share_unavailable", "Unable to open the sharing menu.", null)
                        }
                    }
                    "cookiesFor" -> {
                        val cookies = CookieManager.getInstance().getCookie(uri.toString())
                            ?.split(";")?.map { it.trim() }?.filter { it.isNotBlank() } ?: emptyList()
                        result.success(cookies)
                    }
                    "resetCookies" -> {
                        val manager = CookieManager.getInstance()
                        val names = manager.getCookie(uri.toString())?.split(";")
                            ?.map { it.trim().substringBefore("=") }?.filter { it.isNotBlank() } ?: emptyList()
                        // Android exposes cookies for a URL, not the full cookie
                        // database. Expire matching names at each parent path.
                        val paths = mutableSetOf("/")
                        var path = uri.path.orEmpty()
                        while (path.isNotEmpty()) {
                            paths.add(path)
                            path = path.substringBeforeLast("/", "")
                        }
                        val expirations = names.flatMap { name -> paths.flatMap { cookiePath ->
                            listOf("$name=; Max-Age=0; Path=$cookiePath; Secure",
                                "$name=; Max-Age=0; Domain=${uri.host}; Path=$cookiePath; Secure")
                        } }
                        fun completeReset() {
                            manager.flush()
                            verifiedFetch?.reset()
                            android.webkit.WebStorage.getInstance().deleteOrigin("https://${uri.authority}")
                            result.success(null)
                        }
                        if (expirations.isEmpty()) {
                            completeReset()
                        } else {
                            var remaining = expirations.size
                            for (cookie in expirations) manager.setCookie(uri.toString(), cookie) {
                                remaining--
                                if (remaining == 0) completeReset()
                            }
                        }
                    }

                    "receiveCookies" -> {
                        val cookies = (call.argument<List<String>>("cookies") ?: emptyList())
                            .take(64).filter { it.length <= 16384 }
                        val manager = CookieManager.getInstance()
                        if (cookies.isEmpty()) {
                            result.success(null)
                        } else {
                            var remaining = cookies.size
                            for (cookie in cookies) {
                                manager.setCookie(uri.toString(), cookie) {
                                    remaining--
                                    if (remaining == 0) {
                                        manager.flush()
                                        result.success(null)
                                    }
                                }
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    fun dispose() {
        verifiedFetch?.dispose()
        verifiedFetch = null
        pending?.error("unavailable", "The browser activity was closed.", null)
        pending = null
        pendingUrl = null
    }

    fun complete(requestCode: Int): Boolean {
        if (requestCode != REQUEST_CODE) return false
        CookieManager.getInstance().flush()
        verifiedFetch?.allowBrowserOrigin(pendingUrl)
        pendingUrl = null
        pending?.success(null)
        pending = null
        return true
    }
}
