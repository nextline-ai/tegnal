package work.nextline.tegnal

import android.content.Context
import android.net.http.DnsOptions
import android.net.http.HttpEngine
import android.net.http.HttpException
import android.net.http.NetworkException
import android.net.http.UploadDataProvider
import android.net.http.UploadDataSink
import android.net.http.UrlRequest
import android.net.http.UrlResponseInfo
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.annotation.RequiresApi
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.util.concurrent.Executors

/**
 * Requests through Android's built-in Chromium network stack (`HttpEngine`, Android 14 and later).
 * Its own resolver reads a site's DNS HTTPS record, so a site that publishes Encrypted Client Hello
 * keys is reached with its real name encrypted: a network that filters by server name sees only
 * the site's public outer name. Certificates are still checked against the real name.
 *
 * Redirects are never followed here; the Dart transport applies its own redirect policy.
 */
object EncryptedHelloTransport {
    private const val CHANNEL = "work.nextline.tegnal/ech"
    private val executor = Executors.newFixedThreadPool(4)
    private val main = Handler(Looper.getMainLooper())
    private var engine: Any? = null

    fun register(context: Context, messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "available" -> result.success(Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
                "fetch" -> {
                    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                        result.error("unsupported", "HttpEngine needs Android 14.", null)
                    } else {
                        @Suppress("UNCHECKED_CAST")
                        fetch(context.applicationContext, call.arguments as Map<String, Any?>, result)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    @RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
    private fun engine(context: Context): HttpEngine {
        (engine as? HttpEngine)?.let { return it }
        val built = HttpEngine.Builder(context)
            .setEnableHttp2(true)
            .setEnableQuic(true)
            .setEnableBrotli(true)
            .setEnableHttpCache(HttpEngine.Builder.HTTP_CACHE_DISABLED, 0)
            // The stack's own resolver is what asks for HTTPS records and their ECH keys.
            .setDnsOptions(DnsOptions.Builder().setUseHttpStackDnsResolver(DnsOptions.DNS_OPTION_ENABLED).build())
            .build()
        engine = built
        return built
    }

    @RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
    private fun fetch(context: Context, arguments: Map<String, Any?>, result: MethodChannel.Result) {
        val url = arguments["url"] as? String
        val method = (arguments["method"] as? String) ?: "GET"
        val limit = ((arguments["limit"] as? Number)?.toLong()) ?: 0L
        val timeout = ((arguments["timeoutMs"] as? Number)?.toLong()) ?: 20_000L
        @Suppress("UNCHECKED_CAST")
        val headers = (arguments["headers"] as? Map<String, String>) ?: emptyMap()
        val body = arguments["body"] as? ByteArray
        if (url == null || !url.startsWith("https://") || limit <= 0) {
            result.error("invalid", "Only HTTPS requests with a size limit are sent.", null)
            return
        }
        val reply = Reply(result, limit)
        val builder = engine(context).newUrlRequestBuilder(url, executor, reply)
            .setHttpMethod(method)
            .setCacheDisabled(true)
        for ((name, value) in headers) builder.addHeader(name, value)
        if (body != null) builder.setUploadDataProvider(BytesUpload(body), executor)
        val request = builder.build()
        reply.request = request
        main.postDelayed({ reply.timeOut() }, timeout)
        request.start()
    }

    /** Collects one response, up to its limit, and answers Dart exactly once. */
    @RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
    private class Reply(private val result: MethodChannel.Result, private val limit: Long) : UrlRequest.Callback {
        var request: UrlRequest? = null
        private val body = ByteArrayOutputStream()
        private var answered = false
        private var timedOut = false

        private fun answer(action: (MethodChannel.Result) -> Unit) {
            main.post {
                if (answered) return@post
                answered = true
                action(result)
            }
        }

        fun timeOut() {
            if (answered) return
            timedOut = true
            request?.cancel()
            answer { it.error("timeout", "The request timed out.", null) }
        }

        private fun head(info: UrlResponseInfo): Map<String, Any?> = mapOf(
            "status" to info.httpStatusCode,
            "url" to info.url,
            "headers" to info.headers.asMap.mapKeys { it.key.lowercase() },
        )

        override fun onRedirectReceived(request: UrlRequest, info: UrlResponseInfo, newLocationUrl: String) {
            // The caller decides whether to follow; hand back the redirect itself.
            request.cancel()
            answer { it.success(head(info) + mapOf("body" to ByteArray(0))) }
        }

        override fun onResponseStarted(request: UrlRequest, info: UrlResponseInfo) {
            val length = info.headers.asMap["content-length"]?.firstOrNull()?.toLongOrNull()
            if (length != null && length > limit) {
                request.cancel()
                answer { it.error("tooLarge", "The response is larger than allowed.", null) }
                return
            }
            request.read(ByteBuffer.allocateDirect(64 * 1024))
        }

        override fun onReadCompleted(request: UrlRequest, info: UrlResponseInfo, buffer: ByteBuffer) {
            buffer.flip()
            if (body.size() + buffer.remaining() > limit) {
                request.cancel()
                answer { it.error("tooLarge", "The response is larger than allowed.", null) }
                return
            }
            val chunk = ByteArray(buffer.remaining())
            buffer.get(chunk)
            body.write(chunk)
            buffer.clear()
            request.read(buffer)
        }

        override fun onSucceeded(request: UrlRequest, info: UrlResponseInfo) {
            val bytes = body.toByteArray()
            answer { it.success(head(info) + mapOf("body" to bytes)) }
        }

        override fun onFailed(request: UrlRequest, info: UrlResponseInfo?, error: HttpException) {
            val code = when ((error as? NetworkException)?.errorCode) {
                NetworkException.ERROR_HOSTNAME_NOT_RESOLVED -> "cannotFindHost"
                NetworkException.ERROR_INTERNET_DISCONNECTED -> "notConnected"
                NetworkException.ERROR_TIMED_OUT, NetworkException.ERROR_CONNECTION_TIMED_OUT -> "timeout"
                NetworkException.ERROR_CONNECTION_REFUSED, NetworkException.ERROR_ADDRESS_UNREACHABLE -> "cannotConnect"
                null -> "secureConnection"
                else -> "connectionLost"
            }
            answer { it.error(code, error.message, null) }
        }

        override fun onCanceled(request: UrlRequest, info: UrlResponseInfo?) {
            if (!timedOut) answer { it.error("connectionLost", "The request was cancelled.", null) }
        }
    }

    @RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
    private class BytesUpload(private val data: ByteArray) : UploadDataProvider() {
        private var offset = 0
        override fun getLength(): Long = data.size.toLong()
        override fun read(sink: UploadDataSink, buffer: ByteBuffer) {
            val count = minOf(buffer.remaining(), data.size - offset)
            buffer.put(data, offset, count)
            offset += count
            sink.onReadSucceeded(false)
        }
        override fun rewind(sink: UploadDataSink) {
            offset = 0
            sink.onRewindSucceeded()
        }
    }
}
