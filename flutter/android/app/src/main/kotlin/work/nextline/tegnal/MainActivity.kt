package work.nextline.tegnal

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import android.view.WindowManager
import android.webkit.CookieManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.UUID

class MainActivity : FlutterActivity() {
    private var pendingCreate: Pair<File, MethodChannel.Result>? = null
    private var pendingOpen: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // The reader keeps the screen on while a work is open, as the native app does.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "work.nextline.tegnal/screen").setMethodCallHandler { call, result ->
            when (call.method) {
                "keepAwake" -> {
                    if (call.arguments == true) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    else window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    result.success(null)
                }
                // Settings shows the installed version name, as the native app shows its bundle version.
                "version" -> result.success(packageManager.getPackageInfo(packageName, 0).versionName)
                // Website sign-in reads the identity cookies the page set, then clears the web session,
                // as the native sign-in uses a private, non-persistent store.
                "cookies" -> result.success(CookieManager.getInstance().getCookie(call.argument<String>("url")))
                "clearCookies" -> CookieManager.getInstance().removeAllCookies { result.success(it) }
                else -> result.notImplemented()
            }
        }
        // Backups are saved and opened through the system document picker, so the app
        // needs no storage permission and the person chooses where files go.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "work.nextline.tegnal/files").setMethodCallHandler { call, result ->
            when (call.method) {
                "createDocument" -> createDocument(call.argument<String>("name"), call.argument<String>("mimeType"), call.argument<String>("sourcePath"), result)
                "openDocument" -> openDocument(call.argument<List<String>>("mimeTypes"), result)
                else -> result.notImplemented()
            }
        }
    }

    private fun createDocument(name: String?, mimeType: String?, sourcePath: String?, result: MethodChannel.Result) {
        val source = sourcePath?.let(::File)
        if (name == null || source == null || !source.isFile) {
            result.error("invalid", "A file to save is required.", null)
            return
        }
        if (pendingCreate != null || pendingOpen != null) {
            result.error("busy", "Another document request is open.", null)
            return
        }
        pendingCreate = source to result
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT)
            .addCategory(Intent.CATEGORY_OPENABLE)
            .setType(mimeType ?: "application/json")
            .putExtra(Intent.EXTRA_TITLE, name)
        startActivityForResult(intent, CREATE_DOCUMENT)
    }

    private fun openDocument(mimeTypes: List<String>?, result: MethodChannel.Result) {
        if (pendingCreate != null || pendingOpen != null) {
            result.error("busy", "Another document request is open.", null)
            return
        }
        pendingOpen = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("*/*")
        if (!mimeTypes.isNullOrEmpty()) intent.putExtra(Intent.EXTRA_MIME_TYPES, mimeTypes.toTypedArray())
        startActivityForResult(intent, OPEN_DOCUMENT)
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        when (requestCode) {
            CREATE_DOCUMENT -> {
                val (source, result) = pendingCreate ?: return
                pendingCreate = null
                val target = data?.data
                if (resultCode != Activity.RESULT_OK || target == null) {
                    result.success(false)
                    return
                }
                copyInBackground(result, { copy(source, target); true })
            }
            OPEN_DOCUMENT -> {
                val result = pendingOpen ?: return
                pendingOpen = null
                val uri = data?.data
                if (resultCode != Activity.RESULT_OK || uri == null) {
                    result.success(null)
                    return
                }
                copyInBackground(result, { copyToCache(uri) })
            }
            else -> super.onActivityResult(requestCode, resultCode, data)
        }
    }

    private fun copyInBackground(result: MethodChannel.Result, work: () -> Any?) {
        Thread {
            try {
                val value = work()
                runOnUiThread { result.success(value) }
            } catch (error: Exception) {
                runOnUiThread { result.error("io", error.localizedMessage ?: error.toString(), null) }
            }
        }.start()
    }

    private fun copy(source: File, target: Uri) {
        val output = contentResolver.openOutputStream(target, "wt") ?: throw IllegalStateException("Unable to write the document.")
        output.use { stream -> source.inputStream().use { it.copyTo(stream) } }
    }

    /// The picked document, copied into the cache so Dart reads an ordinary file.
    private fun copyToCache(uri: Uri): String {
        val name = contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) cursor.getString(0) else null
        }?.replace(Regex("[^A-Za-z0-9._-]"), "_") ?: "document"
        val directory = File(cacheDir, "documents").apply { mkdirs() }
        val file = File(directory, UUID.randomUUID().toString() + "-" + name)
        val input = contentResolver.openInputStream(uri) ?: throw IllegalStateException("Unable to read the document.")
        input.use { stream -> file.outputStream().use { stream.copyTo(it) } }
        return file.absolutePath
    }

    private companion object {
        const val CREATE_DOCUMENT = 41001
        const val OPEN_DOCUMENT = 41002
    }
}
