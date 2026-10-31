package work.nextline.tegnal

import android.os.Build
import android.os.Handler
import android.os.Looper
import java.security.cert.CertPathValidatorException
import java.security.cert.CertificateException
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.net.URI
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import okhttp3.Call
import okhttp3.Callback
import okhttp3.Dispatcher
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.android.AndroidDns
import javax.net.ssl.SSLPeerUnverifiedException

/** Bounded, source-owned OkHttp transport for manga catalog requests. */
class MangaHttpTransport private constructor(
    engine: FlutterEngine,
) {
    private val channel = MethodChannel(
        engine.dartExecutor.binaryMessenger,
        CHANNEL_NAME,
    )
    private val mainHandler = Handler(Looper.getMainLooper())
    private val pending = ConcurrentHashMap<String, PendingRequest>()
    private val client: OkHttpClient = OkHttpClient.Builder()
        .apply {
            if (Build.VERSION.SDK_INT >= ECH_API) dns(AndroidDns())
        }
        .connectTimeout(TIMEOUT_SECONDS, TimeUnit.SECONDS)
        .readTimeout(TIMEOUT_SECONDS, TimeUnit.SECONDS)
        .writeTimeout(TIMEOUT_SECONDS, TimeUnit.SECONDS)
        .callTimeout(TIMEOUT_SECONDS, TimeUnit.SECONDS)
        .followRedirects(false)
        .followSslRedirects(false)
        .dispatcher(Dispatcher().apply { maxRequestsPerHost = MAX_REQUESTS_PER_HOST })
        .build()
    private val disposed = AtomicBoolean(false)

    init { channel.setMethodCallHandler(::handleCall) }

    private fun handleCall(call: MethodCall, result: MethodChannel.Result) {
        if (disposed.get()) {
            result.error("closed", "The manga transport is closed.", null)
            return
        }
        when (call.method) {
            "get" -> startGet(call, result)
            "cancel" -> cancel(call, result)
            else -> result.notImplemented()
        }
    }

    private fun startGet(call: MethodCall, result: MethodChannel.Result) {
        val requestId = call.argument<String>("requestId")
        val rawUrl = call.argument<String>("url")
        val maxBytes = call.argument<Number>("maxBytes")?.toLong()
        val headers = call.argument<Map<String, String>>("headers")
        if (requestId.isNullOrBlank() || requestId.length > MAX_REQUEST_ID_LENGTH ||
            rawUrl == null || maxBytes == null || maxBytes <= 0 ||
            maxBytes > MAX_RESPONSE_BYTES || headers == null
        ) {
            result.error("invalid_request", "Invalid manga request.", null)
            return
        }

        val uri = try {
            URI(rawUrl)
        } catch (_: Exception) {
            result.error("invalid_url", "Only valid HTTPS URLs are supported.", null)
            return
        }
        if (uri.scheme != "https" || uri.host.isNullOrBlank() ||
            uri.rawUserInfo != null ||
            (uri.port != -1 && uri.port !in 1..65_535)
        ) {
            result.error("invalid_url", "Only HTTPS URLs without user information are supported.", null)
            return
        }

        val requestBuilder = try {
            Request.Builder().url(rawUrl).get().apply {
                for ((name, value) in headers) {
                    if (!isHopByHop(name) && !name.startsWith("proxy-", ignoreCase = true)) {
                        addHeader(name, value)
                    }
                }
            }
        } catch (_: Exception) {
            result.error("invalid_request", "Invalid manga request headers.", null)
            return
        }

        val okCall = client.newCall(requestBuilder.build())
        val pendingRequest = PendingRequest(okCall, result, requestId, maxBytes)
        if (pending.putIfAbsent(requestId, pendingRequest) != null) {
            result.error("duplicate_request", "Duplicate manga request.", null)
            return
        }
        if (disposed.get()) {
            finishError(pendingRequest, "closed", "The manga transport is closed.")
            return
        }
        okCall.enqueue(object : Callback {
            override fun onFailure(call: Call, error: java.io.IOException) {
                val errorCode = when {
                    call.isCanceled() -> "aborted"
                    isCertificateFailure(error) -> "certificate_error"
                    else -> "network_error"
                }
                finishError(
                    pendingRequest,
                    errorCode,
                    when (errorCode) {
                        "aborted" -> "The manga request was cancelled."
                        "certificate_error" -> "The manga server certificate could not be verified."
                        else -> "The manga server could not be reached."
                    },
                )
            }

            override fun onResponse(call: Call, response: Response) {
                response.use {
                    try {
                        val body = response.body
                        if (body != null && body.contentLength() > pendingRequest.maxBytes) {
                            throw ResponseTooLarge()
                        }
                        val bytes = ByteArrayOutputStream()
                        body?.byteStream()?.use { input ->
                            val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                            while (true) {
                                val count = input.read(buffer)
                                if (count < 0) break
                                if (bytes.size().toLong() + count > pendingRequest.maxBytes) {
                                    throw ResponseTooLarge()
                                }
                                bytes.write(buffer, 0, count)
                            }
                        }
                        val responseHeaders = linkedMapOf<String, String>()
                        for (name in response.headers.names()) {
                            if (isHopByHop(name)) continue
                            responseHeaders[name.lowercase()] =
                                response.headers.values(name).joinToString(", ")
                        }
                        finishSuccess(
                            pendingRequest,
                            mapOf(
                                "statusCode" to response.code,
                                "headers" to responseHeaders,
                                "body" to bytes.toByteArray(),
                            ),
                        )
                    } catch (_: ResponseTooLarge) {
                        finishError(
                            pendingRequest,
                            "response_too_large",
                            "The manga response exceeded the size limit.",
                        )
                    } catch (_: Exception) {
                        finishError(
                            pendingRequest,
                            "network_error",
                            "The manga response could not be read.",
                        )
                    }
                }
            }
        })
    }

    private fun cancel(call: MethodCall, result: MethodChannel.Result) {
        val requestId = call.argument<String>("requestId")
        if (requestId.isNullOrBlank()) {
            result.error("invalid_request", "Invalid cancellation request.", null)
            return
        }
        val request = pending[requestId]
        if (request != null) {
            request.call.cancel()
            finishError(request, "aborted", "The manga request was cancelled.")
        }
        result.success(null)
    }

    private fun finishSuccess(request: PendingRequest, value: Any) {
        if (!request.completed.compareAndSet(false, true)) return
        pending.remove(request.requestId, request)
        // Encoding copies the whole body. Flutter runs Dart on the Android main
        // thread, so encode on this network thread rather than delaying frames.
        request.result.success(value)
    }

    private fun finishError(request: PendingRequest, code: String, message: String) {
        if (!request.completed.compareAndSet(false, true)) return
        pending.remove(request.requestId, request)
        request.call.cancel()
        mainHandler.post { request.result.error(code, message, null) }
    }

    private fun isCertificateFailure(error: Throwable): Boolean {
        val visited = java.util.Collections.newSetFromMap(
            java.util.IdentityHashMap<Throwable, Boolean>(),
        )
        var current: Throwable? = error
        while (current != null && visited.add(current)) {
            if (current is SSLPeerUnverifiedException ||
                current is CertPathValidatorException ||
                current is CertificateException
            ) {
                return true
            }
            current = current.cause
        }
        return false
    }

    /** Cancels only calls owned by this bridge; OkHttp is not shared globally. */
    fun dispose() {
        if (!disposed.compareAndSet(false, true)) return
        channel.setMethodCallHandler(null)
        for (request in pending.values.toList()) {
            finishError(request, "closed", "The manga transport is closed.")
        }
        client.dispatcher.cancelAll()
        client.connectionPool.evictAll()
    }

    private data class PendingRequest(
        val call: Call,
        val result: MethodChannel.Result,
        val requestId: String,
        val maxBytes: Long,
        val completed: AtomicBoolean = AtomicBoolean(false),
    )

    private class ResponseTooLarge : Exception()

    companion object {
        const val CHANNEL_NAME = "work.nextline.tegnal/manga-http"
        const val ECH_API = 37
        const val TIMEOUT_SECONDS = 20L
        const val MAX_REQUESTS_PER_HOST = 6
        const val MAX_REQUEST_ID_LENGTH = 80
        const val MAX_RESPONSE_BYTES = 32L * 1024 * 1024

        val HOP_BY_HOP_HEADERS = setOf(
            "connection",
            "content-length",
            "keep-alive",
            "proxy-authenticate",
            "proxy-authorization",
            "te",
            "trailer",
            "transfer-encoding",
            "upgrade",
        )

        fun isHopByHop(name: String): Boolean =
            name.lowercase() in HOP_BY_HOP_HEADERS

        /** Keep this instance and call [dispose] when its Flutter engine is torn down. */
        @JvmStatic
        fun register(engine: FlutterEngine): MangaHttpTransport = MangaHttpTransport(engine)
    }
}
