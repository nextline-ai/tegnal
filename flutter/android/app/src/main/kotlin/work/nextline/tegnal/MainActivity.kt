package work.nextline.tegnal

import android.app.Activity
import android.app.KeyguardManager
import android.hardware.biometrics.BiometricManager
import android.hardware.biometrics.BiometricPrompt
import android.media.AudioManager
import android.net.ConnectivityManager
import android.os.CancellationSignal
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import android.view.WindowManager
import android.webkit.CookieManager
import androidx.core.view.WindowCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.UUID

class MainActivity : FlutterActivity() {
    private val privacyCover by lazy(LazyThreadSafetyMode.NONE) { PrivacyCover(this) }
    private var uiDisplayed = false
    private var resumed = false

    /// iOS's active state: in front and receiving input. The app switcher, a picker or another
    /// window on top takes it away while the activity may stay resumed behind a live preview.
    /// Systems differ in which signal they send, so losing either one covers the window.
    private var topResumed = true
    private var focused = false

    /// The launch cover (the home scene's blurred still) stays until the Dart side reports the
    /// still on screen (`launchReady`), or a safety timeout ends it, once per process.
    private var launchSplashPending = true
    private val handler = Handler(Looper.getMainLooper())
    private val launchTimeout = Runnable { launchReady() }
    private var pendingCreate: Pair<File, MethodChannel.Result>? = null
    private var pendingOpen: MethodChannel.Result? = null
    private var pendingFolder: MethodChannel.Result? = null
    private var pendingUnlock: MethodChannel.Result? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        // Edge to edge on every Android version, as Android 15 and later draw an app targeting
        // SDK 35 or above: the Flutter UI already keeps clear of the system bars by their insets.
        WindowCompat.enableEdgeToEdge(window)
        super.onCreate(savedInstanceState)
        preferHighestRefreshRate()
        privacyCover.protectTaskSnapshot()
        // The artwork covers the window from the start, as the native launch splash does.
        privacyCover.show()
    }

    override fun onResume() {
        super.onResume()
        resumed = true
        // Some systems reset the window's preference when the app returns to the front.
        preferHighestRefreshRate()
        revealContent()
    }

    override fun onFlutterUiDisplayed() {
        super.onFlutterUiDisplayed()
        if (!uiDisplayed && launchSplashPending) handler.postDelayed(launchTimeout, LAUNCH_TIMEOUT_MILLIS)
        uiDisplayed = true
        revealContent()
    }

    /// `willResignActive` / `didBecomeActive`: the app switcher shows a live preview of an app
    /// that keeps running, so the cover follows the front position rather than onPause.
    override fun onTopResumedActivityChanged(isTopResumedActivity: Boolean) {
        super.onTopResumedActivityChanged(isTopResumedActivity)
        topResumed = isTopResumedActivity
        if (isTopResumedActivity) revealContent() else privacyCover.show()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        focused = hasFocus
        if (hasFocus) revealContent() else if (uiDisplayed) privacyCover.show()
    }

    /// Home and Recents call this before onPause: the earliest moment to cover the window.
    override fun onUserLeaveHint() {
        privacyCover.show()
        super.onUserLeaveHint()
    }

    override fun onPause() {
        resumed = false
        privacyCover.show()
        super.onPause()
    }

    override fun onStop() {
        privacyCover.show()
        super.onStop()
    }

    /// While the launch cover is pending, focus and resume changes leave it alone; afterwards
    /// returning only fades, following "Play Animation When Returning".
    private fun revealContent() {
        if (!uiDisplayed || !resumed || !topResumed || !focused || launchSplashPending) return
        privacyCover.hide(if (privacyCover.resumeAnimation) PrivacyCover.RESUME_FADE else 0L)
    }

    /// The home scene's first picture is on screen (or the safety timeout ran out): the launch
    /// cover fades out once, as soon as the window is also in front and focused.
    private fun launchReady() {
        if (!launchSplashPending) return
        launchSplashPending = false
        handler.removeCallbacks(launchTimeout)
        if (!uiDisplayed || !resumed || !topResumed || !focused) return
        privacyCover.hide(PrivacyCover.LAUNCH_FADE)
    }

    /// Asks for the display's fastest mode at its current resolution, as iOS gives ProMotion
    /// to apps that animate. Some Android systems otherwise hold third-party apps at 60 Hz;
    /// the system still lowers the rate for battery saving or heat.
    private fun preferHighestRefreshRate() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
        @Suppress("DEPRECATION")
        val display = (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) display else windowManager.defaultDisplay) ?: return
        val current = display.mode
        val fastest = display.supportedModes
            .filter { it.physicalWidth == current.physicalWidth && it.physicalHeight == current.physicalHeight }
            .maxByOrNull { it.refreshRate } ?: return
        val attributes = window.attributes
        if (attributes.preferredDisplayModeId == fastest.modeId) return
        attributes.preferredDisplayModeId = fastest.modeId
        window.attributes = attributes
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Requests to sites a network filters by name, through Android's own network stack with ECH.
        EncryptedHelloTransport.register(this, flutterEngine.dartExecutor.binaryMessenger)
        // On-device image translation for the reader and the image viewer.
        ImageTranslator.register(this, flutterEngine.dartExecutor.binaryMessenger)
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
                // The image viewer shares a post's page address through the system share sheet.
                "share" -> {
                    val send = Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, call.argument<String>("text"))
                    startActivity(Intent.createChooser(send, null))
                    result.success(null)
                }
                // A Recap card goes to the system share sheet, as the native ShareLink offers it.
                "shareImage" -> shareImage(call.argument<String>("path"), call.argument<String>("title"), result)
                // `TimeZone.current.identifier`: taste statistics divide days in this zone.
                "timeZone" -> result.success(java.util.TimeZone.getDefault().id)
                // The home scene stays silent while the user is already listening to something.
                "musicActive" -> result.success((getSystemService(AUDIO_SERVICE) as AudioManager).isMusicActive)
                else -> result.notImplemented()
            }
        }
        // Flutter reports the returning-animation setting and when the launch picture is on screen.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "work.nextline.tegnal/privacy").setMethodCallHandler { call, result ->
            when (call.method) {
                "configure" -> {
                    call.argument<Boolean>("resumeAnimation")?.let { privacyCover.resumeAnimation = it }
                    result.success(null)
                }
                // "Block Screenshots and Recording": the window is left out of captures and recordings.
                "secure" -> {
                    if (call.arguments == true) window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    else window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    result.success(null)
                }
                // The HTTP proxy the current network names, which dart:io does not read on its own.
                "proxy" -> {
                    val proxy = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) getSystemService(ConnectivityManager::class.java)?.defaultProxy else null
                    result.success(proxy?.takeIf { !it.host.isNullOrEmpty() && it.port > 0 }?.let {
                        mapOf("host" to it.host, "port" to it.port, "exclusions" to (it.exclusionList?.toList() ?: emptyList<String>()))
                    })
                }
                // App lock: only offered when the device itself has a screen lock.
                "canAuthenticate" -> result.success(getSystemService(KeyguardManager::class.java)?.isKeyguardSecure == true)
                "authenticate" -> authenticate(call.argument<String>("title") ?: "", call.argument<String>("subtitle"), result)
                // The home scene's still is on screen: the launch cover fades out.
                "launchReady" -> {
                    launchReady()
                    result.success(null)
                }
                // Screen comparison runs start without the cover, as the native UI tests do.
                "skipLaunchSplash" -> {
                    if (launchSplashPending) {
                        launchSplashPending = false
                        handler.removeCallbacks(launchTimeout)
                        privacyCover.hide(0L)
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        // Backups are saved and opened through the system document picker, so the app
        // needs no storage permission and the person chooses where files go.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "work.nextline.tegnal/files").setMethodCallHandler { call, result ->
            when (call.method) {
                "createDocument" -> createDocument(call.argument<String>("name"), call.argument<String>("mimeType"), call.argument<String>("sourcePath"), result)
                "openDocument" -> openDocument(call.argument<List<String>>("mimeTypes"), result)
                // Downloads go where the Files app can open them without a storage permission.
                "downloadRoot" -> result.success(downloadRoot())
                "pickFolder" -> pickFolder(result)
                else -> result.notImplemented()
            }
        }
    }

    private fun shareImage(path: String?, title: String?, result: MethodChannel.Result) {
        val shared = File(cacheDir, "shared").canonicalFile
        val file = path?.let { File(it).canonicalFile }
        if (file == null || !file.isFile || file.parentFile != shared) {
            result.error("invalid", "Only images in the shared cache folder can be shared.", null)
            return
        }
        val uri = androidx.core.content.FileProvider.getUriForFile(this, "$packageName.share", file)
        val send = Intent(Intent.ACTION_SEND)
            .setType("image/png")
            .putExtra(Intent.EXTRA_STREAM, uri)
            .putExtra(Intent.EXTRA_TITLE, title)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        // The preview in the share sheet reads the image through this grant as well.
        send.clipData = android.content.ClipData.newRawUri(title, uri)
        startActivity(Intent.createChooser(send, title))
        result.success(null)
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

    /// Download/TEGNAL from Android 11, where an app may add files to the shared Download folder
    /// without a permission; before that, the app's own folder on shared storage, which file
    /// managers show under Android/data and which also needs no permission.
    private fun downloadRoot(): String? {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            @Suppress("DEPRECATION")
            val shared = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS), "TEGNAL")
            if (writable(shared)) return shared.absolutePath
        }
        val own = getExternalFilesDir(null)?.let { File(it, "TEGNAL") }
        return own?.takeIf(::writable)?.absolutePath
    }

    private fun writable(directory: File): Boolean = try {
        directory.mkdirs()
        val probe = File(directory, ".tegnal-" + UUID.randomUUID())
        probe.writeText("")
        probe.delete()
        true
    } catch (error: Exception) {
        false
    }

    /// The system folder picker. The folder comes back as a path on this device's shared storage,
    /// which Dart then tries writing to; other providers aren't folders the app can save into.
    private fun pickFolder(result: MethodChannel.Result) {
        if (pendingCreate != null || pendingOpen != null || pendingFolder != null) {
            result.error("busy", "Another document request is open.", null)
            return
        }
        pendingFolder = result
        startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE), PICK_FOLDER)
    }

    private fun folderPath(tree: Uri): String? {
        val id = DocumentsContract.getTreeDocumentId(tree) ?: return null
        if (id.startsWith("raw:")) return id.removePrefix("raw:")
        if (tree.authority != "com.android.externalstorage.documents") return null
        val volume = id.substringBefore(':')
        val relative = id.substringAfter(':', "")
        @Suppress("DEPRECATION")
        val base = if (volume.equals("primary", ignoreCase = true)) Environment.getExternalStorageDirectory() else File("/storage", volume)
        return if (relative.isEmpty()) base.absolutePath else File(base, relative).absolutePath
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
    /// The device's own unlock: fingerprint, face or the screen lock. Android 10 and later show the
    /// system prompt; older versions show the screen lock confirmation.
    private fun authenticate(title: String, subtitle: String?, result: MethodChannel.Result) {
        if (pendingUnlock != null) { result.success(false); return }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val builder = BiometricPrompt.Builder(this).setTitle(title)
            if (!subtitle.isNullOrEmpty()) builder.setSubtitle(subtitle)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                builder.setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_WEAK or BiometricManager.Authenticators.DEVICE_CREDENTIAL)
            } else {
                @Suppress("DEPRECATION") builder.setDeviceCredentialAllowed(true)
            }
            pendingUnlock = result
            builder.build().authenticate(CancellationSignal(), mainExecutor, object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(authResult: BiometricPrompt.AuthenticationResult) { finishUnlock(true) }
                override fun onAuthenticationError(errorCode: Int, errString: CharSequence) { finishUnlock(false) }
            })
            return
        }
        @Suppress("DEPRECATION")
        val intent = getSystemService(KeyguardManager::class.java)?.createConfirmDeviceCredentialIntent(title, subtitle)
        if (intent == null) { result.success(true); return }
        pendingUnlock = result
        @Suppress("DEPRECATION") startActivityForResult(intent, CONFIRM_CREDENTIAL)
    }

    private fun finishUnlock(passed: Boolean) {
        pendingUnlock?.success(passed)
        pendingUnlock = null
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == CONFIRM_CREDENTIAL) { finishUnlock(resultCode == Activity.RESULT_OK); return }
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
            PICK_FOLDER -> {
                val result = pendingFolder ?: return
                pendingFolder = null
                val tree = data?.data
                if (resultCode != Activity.RESULT_OK || tree == null) {
                    result.success(null)
                    return
                }
                val path = folderPath(tree)
                if (path == null) result.error("unsupported", "This folder isn't on this device's storage.", null)
                else result.success(mapOf("path" to path, "name" to File(path).name))
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
        const val PICK_FOLDER = 41003
        const val CONFIRM_CREDENTIAL = 41004

        /// The launch cover never stays longer than this after the Flutter UI is displayed.
        const val LAUNCH_TIMEOUT_MILLIS = 6000L
    }
}
