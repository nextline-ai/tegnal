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

    fun secureUri(raw: String?): Uri? {
        if (raw.isNullOrBlank()) return null
        return runCatching { Uri.parse(raw) }.getOrNull()?.takeIf {
            it.scheme == "https" && !it.host.isNullOrBlank() && it.userInfo == null
        }
    }

    fun register(activity: Activity, engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, "work.nextline.tegnal/browser")
            .setMethodCallHandler { call, result ->
                val uri = secureUri(call.argument<String>("url"))
                if (uri == null) {
                    result.error("invalid_url", "Only HTTPS websites can be opened.", null)
                    return@setMethodCallHandler
                }
                when (call.method) {
                    "open" -> {
                        if (pending != null) {
                            result.error("busy", "A browser is already open.", null)
                        } else {
                            pending = result
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

    fun complete(requestCode: Int): Boolean {
        if (requestCode != REQUEST_CODE) return false
        CookieManager.getInstance().flush()
        pending?.success(null)
        pending = null
        return true
    }
}
