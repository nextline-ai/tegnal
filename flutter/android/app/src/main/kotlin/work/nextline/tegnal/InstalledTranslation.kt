package work.nextline.tegnal

import android.app.Activity
import android.content.ClipData
import android.content.ComponentName
import android.content.ContentValues
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.BitmapFactory
import android.os.Build
import android.provider.MediaStore
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.UUID
import java.util.concurrent.Executors

/** Hands an image to an installed app; this does not implement translation or OCR. */
class TranslationFileProvider : FileProvider()

object InstalledTranslation {
    private const val PACKAGE = "com.google.android.apps.translate"
    private val io = Executors.newSingleThreadExecutor()

    private fun imageIntent() = Intent(Intent.ACTION_SEND).apply {
        type = "image/png"
        setPackage(PACKAGE)
    }

    private fun imageTarget(activity: Activity): ComponentName? {
        val target = activity.packageManager.resolveActivity(imageIntent(), PackageManager.MATCH_DEFAULT_ONLY)?.activityInfo
        return target?.takeIf { it.exported && it.enabled && it.packageName == PACKAGE }
            ?.let { ComponentName(it.packageName, it.name) }
    }

    private fun installed(activity: Activity): Boolean = try {
        activity.packageManager.getApplicationInfo(PACKAGE, 0).enabled
    } catch (_: PackageManager.NameNotFoundException) {
        false
    }

    private fun capability(activity: Activity): String = when {
        !installed(activity) -> "missing"
        imageTarget(activity) != null -> "direct"
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && activity.packageManager.getLaunchIntentForPackage(PACKAGE) != null -> "manual"
        else -> "unsupported"
    }

    private fun validatedPNG(bytes: ByteArray?): ByteArray {
        require(bytes != null && bytes.size in 8..(32 * 1024 * 1024))
        require(bytes.take(8).map { it.toInt() and 255 } == listOf(137, 80, 78, 71, 13, 10, 26, 10))
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        require(bounds.outWidth in 1..4096 && bounds.outHeight in 1..4096)
        return bytes
    }

    fun register(activity: Activity, engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, "work.nextline.tegnal/installed_translation")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "capability" -> result.success(capability(activity))
                    "shareImage" -> {
                        val target = imageTarget(activity)
                        if (!installed(activity) || target == null) {
                            result.error("unavailable", "Google Translate cannot receive images on this device.", null)
                            return@setMethodCallHandler
                        }
                        val bytes = try { validatedPNG(call.argument<ByteArray>("png")) }
                            catch (_: Exception) {
                                result.error("invalid_image", "Unable to prepare the visible image.", null)
                                return@setMethodCallHandler
                            }
                        io.execute {
                            try {
                                val directory = File(activity.cacheDir, "translation-images").apply { mkdirs() }
                                val cutoff = System.currentTimeMillis() - 24L * 60 * 60 * 1000
                                directory.listFiles()?.filter { it.isFile && it.lastModified() < cutoff }?.forEach { it.delete() }
                                val file = File(directory, "${UUID.randomUUID()}.png")
                                file.outputStream().use { it.write(bytes) }
                                val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.translation_files", file)
                                activity.runOnUiThread {
                                    try {
                                        val intent = imageIntent().apply {
                                            component = target
                                            putExtra(Intent.EXTRA_STREAM, uri)
                                            clipData = ClipData.newUri(activity.contentResolver, "TEGNAL image", uri)
                                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                        }
                                        activity.startActivity(intent)
                                        result.success(null)
                                    } catch (_: Exception) {
                                        file.delete()
                                        result.error("unavailable", "Google Translate could not open this image.", null)
                                    }
                                }
                            } catch (_: Exception) {
                                activity.runOnUiThread { result.error("image_failed", "Unable to prepare the visible image.", null) }
                            }
                        }
                    }
                    "saveImageAndOpen" -> {
                        val launcher = activity.packageManager.getLaunchIntentForPackage(PACKAGE)
                        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q || launcher == null || !installed(activity)) {
                            result.error("unavailable", "Google Translate cannot import this image on this device.", null)
                            return@setMethodCallHandler
                        }
                        val bytes = try { validatedPNG(call.argument<ByteArray>("png")) }
                            catch (_: Exception) {
                                result.error("invalid_image", "Unable to prepare the visible image.", null)
                                return@setMethodCallHandler
                            }
                        io.execute {
                            var saved: android.net.Uri? = null
                            try {
                                val values = ContentValues().apply {
                                    put(MediaStore.Images.Media.DISPLAY_NAME, "TEGNAL-translation-${System.currentTimeMillis()}.png")
                                    put(MediaStore.Images.Media.MIME_TYPE, "image/png")
                                    put(MediaStore.Images.Media.RELATIVE_PATH, "Pictures/TEGNAL")
                                    put(MediaStore.Images.Media.IS_PENDING, 1)
                                }
                                val image = activity.contentResolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)
                                    ?: error("Unable to create the image")
                                saved = image
                                activity.contentResolver.openOutputStream(image)?.use { it.write(bytes) }
                                    ?: error("Unable to save the image")
                                activity.contentResolver.update(image, ContentValues().apply { put(MediaStore.Images.Media.IS_PENDING, 0) }, null, null)
                                activity.runOnUiThread {
                                    try {
                                        activity.startActivity(launcher)
                                        result.success(null)
                                    } catch (_: Exception) {
                                        activity.contentResolver.delete(image, null, null)
                                        result.error("unavailable", "Google Translate could not open.", null)
                                    }
                                }
                            } catch (_: Exception) {
                                saved?.let { activity.contentResolver.delete(it, null, null) }
                                activity.runOnUiThread { result.error("image_failed", "Unable to save the visible image.", null) }
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
