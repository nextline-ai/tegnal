package work.nextline.tegnal

import android.app.Activity
import android.graphics.Color
import android.graphics.Typeface
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.webkit.WebResourceError
import android.net.http.SslError
import android.os.Build
import android.os.Bundle
import android.webkit.CookieManager
import android.webkit.SslErrorHandler
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import android.window.OnBackInvokedCallback
import android.window.OnBackInvokedDispatcher

/** A normal browser page for user-directed verification and sign in.
 * It has no JavaScript bridge, file/content access, custom certificate trust,
 * page-directed external intent navigation, or cookie serialization.
 */
class BrowserActivity : Activity() {
    private lateinit var webView: WebView
    private lateinit var address: TextView
    private lateinit var errorPanel: LinearLayout
    private lateinit var errorMessage: TextView
    private var currentUrl: String? = null
    private val privacyCover by lazy(LazyThreadSafetyMode.NONE) { PrivacyCover(this) }
    private val appFont by lazy(LazyThreadSafetyMode.NONE) {
        runCatching {
            Typeface.createFromAsset(assets, "flutter_assets/assets/fonts/PretendardVariable.ttf")
        }.getOrDefault(Typeface.DEFAULT)
    }
    private fun label(key: String, fallback: String) = intent.getStringExtra(key) ?: fallback
    private var backCallback: OnBackInvokedCallback? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        privacyCover.protectTaskSnapshot()
        val uri = BrowserSession.secureUri(intent.getStringExtra("url"))
        if (uri == null) { finish(); return }
        currentUrl = uri.toString()
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.rgb(24, 24, 26))
            setPadding(0, 0, 0, 0)
        }
        val toolbar = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        fun button(title: String, action: () -> Unit) = Button(this).apply {
            text = title
            typeface = appFont
            contentDescription = title
            setTextColor(Color.WHITE)
            setOnClickListener { action() }
        }
        toolbar.addView(button(label("close", "Close")) { finish() })
        toolbar.addView(button(label("back", "Back")) { backOrFinish() })
        toolbar.addView(button(label("retry", "Retry")) { retry() })
        root.addView(toolbar)
        address = TextView(this).apply {
            typeface = appFont
            setTextColor(Color.LTGRAY)
            setPadding(20, 8, 20, 12)
            maxLines = 2
            text = uri.host
        }
        root.addView(address)
        val content = FrameLayout(this)
        errorMessage = TextView(this).apply {
            typeface = appFont
            setTextColor(Color.WHITE)
            textSize = 16f
        }
        errorPanel = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = android.view.Gravity.CENTER
            setPadding(32, 32, 32, 32)
            setBackgroundColor(Color.rgb(24, 24, 26))
            visibility = View.GONE
            addView(errorMessage)
            addView(button(label("retry", "Retry")) { retry() })
        }
        webView = WebView(this).apply {
            settings.javaScriptEnabled = true
            settings.domStorageEnabled = true
            settings.allowFileAccess = false
            settings.allowContentAccess = false
            settings.mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
            settings.javaScriptCanOpenWindowsAutomatically = false
            settings.setSupportMultipleWindows(false)
            settings.setGeolocationEnabled(false)
            if (Build.VERSION.SDK_INT >= 26) settings.safeBrowsingEnabled = true
            webChromeClient = WebChromeClient()
            webViewClient = object : WebViewClient() {
                override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
                    return BrowserSession.secureUri(request.url.toString()) == null
                }
                @Deprecated("Required for older Android WebView versions")
                override fun shouldOverrideUrlLoading(view: WebView, url: String): Boolean {
                    return BrowserSession.secureUri(url) == null
                }
                override fun onPageStarted(view: WebView, url: String, favicon: android.graphics.Bitmap?) {
                    if (BrowserSession.secureUri(url) == null) {
                        view.stopLoading()
                        return
                    }
                    currentUrl = url
                    errorPanel.visibility = View.GONE
                    webView.visibility = View.VISIBLE
                    address.text = BrowserSession.secureUri(url)?.host
                }
                override fun onReceivedError(view: WebView, request: WebResourceRequest, error: WebResourceError) {
                    if (!request.isForMainFrame) return
                    showFailure(label("connectionError", "This website could not connect inside the app."))
                }
                override fun onReceivedSslError(view: WebView, handler: SslErrorHandler, error: SslError) {
                    handler.cancel()
                    showFailure(label("certificateError", "The secure connection could not be verified."))
                }
            }
        }
        CookieManager.getInstance().apply {
            setAcceptCookie(true)
            setAcceptThirdPartyCookies(webView, false)
        }
        content.addView(webView, FrameLayout.LayoutParams(-1, -1))
        content.addView(errorPanel, FrameLayout.LayoutParams(-1, -1))
        root.addView(content, LinearLayout.LayoutParams(-1, 0, 1f))
        setContentView(root)
        if (Build.VERSION.SDK_INT >= 30) {
            root.setOnApplyWindowInsetsListener { view, insets ->
                val bars = insets.getInsets(android.view.WindowInsets.Type.systemBars())
                view.setPadding(bars.left, bars.top, bars.right, bars.bottom)
                insets
            }
            root.requestApplyInsets()
        }
        if (Build.VERSION.SDK_INT >= 33) {
            val callback = OnBackInvokedCallback { backOrFinish() }
            backCallback = callback
            onBackInvokedDispatcher.registerOnBackInvokedCallback(OnBackInvokedDispatcher.PRIORITY_DEFAULT, callback)
        }
        if (savedInstanceState == null || webView.restoreState(savedInstanceState) == null) {
            webView.loadUrl(uri.toString())
        }
    }

    private fun showFailure(message: String) {
        errorMessage.text = message
        webView.visibility = View.GONE
        errorPanel.visibility = View.VISIBLE
    }

    private fun retry() {
        val uri = BrowserSession.secureUri(currentUrl) ?: return
        errorPanel.visibility = View.GONE
        webView.visibility = View.VISIBLE
        webView.loadUrl(uri.toString())
    }

    private fun backOrFinish() {
        if (::webView.isInitialized && webView.canGoBack()) webView.goBack() else finish()
    }

    @Deprecated("Compatibility with Android before predictive back")
    override fun onBackPressed() { backOrFinish() }

    override fun onSaveInstanceState(outState: Bundle) {
        if (::webView.isInitialized) webView.saveState(outState)
        super.onSaveInstanceState(outState)
    }

    override fun onPause() {
        privacyCover.show()
        if (::webView.isInitialized) webView.onPause()
        CookieManager.getInstance().flush()
        super.onPause()
    }

    override fun onUserLeaveHint() {
        privacyCover.show()
        super.onUserLeaveHint()
    }

    override fun onResume() {
        super.onResume()
        if (::webView.isInitialized) webView.onResume()
        privacyCover.hide()
    }

    override fun onStop() {
        privacyCover.show()
        super.onStop()
    }

    override fun onDestroy() {
        privacyCover.dispose()
        if (Build.VERSION.SDK_INT >= 33) backCallback?.let { onBackInvokedDispatcher.unregisterOnBackInvokedCallback(it) }
        if (::webView.isInitialized) {
            (webView.parent as? ViewGroup)?.removeView(webView)
            webView.stopLoading()
            webView.destroy()
        }
        super.onDestroy()
    }
}
