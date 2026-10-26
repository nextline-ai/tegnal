package work.nextline.tegnal

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val privacyCover by lazy(LazyThreadSafetyMode.NONE) { PrivacyCover(this) }
    private var mangaTransport: MangaHttpTransport? = null
    private var pendingExport: MethodChannel.Result? = null
    private var exportFile: File? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        privacyCover.protectTaskSnapshot()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        BrowserSession.register(this, flutterEngine)
        mangaTransport?.dispose()
        mangaTransport = MangaHttpTransport.register(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "work.nextline.tegnal/privacy")
            .setMethodCallHandler { call, result ->
                if (call.method != "setAppearance") {
                    result.notImplemented()
                } else {
                    val dark = call.argument<Boolean>("dark")
                    if (dark == null) {
                        result.error("invalid_appearance", "Expected a dark appearance flag.", null)
                    } else {
                        PrivacyCover.setAppAppearance(dark)
                        result.success(null)
                    }
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "work.nextline.tegnal/files")
            .setMethodCallHandler { call, result ->
                if (call.method != "exportBackup") {
                    result.notImplemented()
                } else if (pendingExport != null) {
                    result.error("busy", "Another export is already open.", null)
                } else {
                    val path = call.argument<String>("path")
                    val file = path?.let { File(it).canonicalFile }
                    if (file == null || !file.isFile || !file.path.startsWith(cacheDir.canonicalPath + File.separator)) {
                        result.error("invalid_file", "Backup file is unavailable.", null)
                    } else {
                        pendingExport = result
                        exportFile = file
                        try {
                            val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                                addCategory(Intent.CATEGORY_OPENABLE)
                                type = "application/json"
                                putExtra(Intent.EXTRA_TITLE, "tegnal-backup.json")
                            }
                            startActivityForResult(intent, 7101)
                        } catch (error: Exception) {
                            pendingExport = null
                            exportFile = null
                            result.error("export_unavailable", "Unable to open the file picker.", null)
                        }
                    }
                }
            }
    }

    override fun onPause() {
        // Keep the branded resume cover ready. Recents protection is configured
        // separately because its snapshot can precede lifecycle callbacks.
        privacyCover.show()
        super.onPause()
    }

    override fun onUserLeaveHint() {
        // Home and Recents invoke this before onPause. Cover here as well so
        // the branded frame has the earliest opportunity to reach the window.
        privacyCover.show()
        super.onUserLeaveHint()
    }

    override fun onStop() {
        privacyCover.show()
        super.onStop()
    }

    override fun onResume() {
        super.onResume()
        privacyCover.hide()
    }

    override fun onDestroy() {
        privacyCover.dispose()
        mangaTransport?.dispose()
        mangaTransport = null
        super.onDestroy()
    }

    @Deprecated("Android activity result used by Flutter plugins")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (BrowserSession.complete(requestCode)) return
        if (requestCode != 7101) return
        val result = pendingExport ?: return
        val file = exportFile
        pendingExport = null
        exportFile = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null || file == null) {
            result.success(false)
            return
        }
        Thread {
            try {
                contentResolver.openOutputStream(uri, "wt").use { output ->
                    requireNotNull(output) { "No output stream" }
                    file.inputStream().use { it.copyTo(output) }
                }
                runOnUiThread { result.success(true) }
            } catch (error: Exception) {
                runOnUiThread { result.error("write_failed", "Unable to save the backup.", null) }
            }
        }.start()
    }
}
