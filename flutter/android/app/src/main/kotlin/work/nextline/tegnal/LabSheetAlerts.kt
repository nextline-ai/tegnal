package work.nextline.tegnal

import android.Manifest
import android.app.Activity
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import android.util.Base64
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.math.BigInteger
import java.net.HttpURLConnection
import java.net.URL
import java.security.AlgorithmParameters
import java.security.KeyFactory
import java.security.PublicKey
import java.security.Signature
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECParameterSpec
import java.security.spec.ECPoint
import java.security.spec.ECPublicKeySpec

/// Tells the learner when a new cheat-sheet edition is published, if they asked for it at the foot of the sheet
/// (iOS `LabSheetAlerts`). There is no push server: while the switch is on, a periodic job (`LabSheetJob`, about every
/// eight hours, when a network is there) fetches the signed edition, keeps it where the app reads its last download, and
/// an edition dated after the newest one already known becomes one notification. A tap opens the lab on the cheat sheet.
object LabSheetAlerts {
    const val CHANNEL = "work.nextline.tegnal/labAlerts"
    const val EXTRA_OPEN = "work.nextline.tegnal.open"
    const val OPEN_SHEET = "lab.sheet"
    private const val JOB_ID = 46_201
    private const val PREFS = "lab_sheet_alerts"
    private const val NOTIFICATION_CHANNEL = "lab.sheet"
    private const val INTERVAL_MILLIS = 8 * 60 * 60 * 1000L
    private const val MAXIMUM_BYTES = 512 * 1024
    private const val FORMAT = "tegnal-lab-cheatsheet"
    const val PERMISSION_REQUEST = 4_620

    private var pendingEnable: MethodChannel.Result? = null
    /// Set when the app is opened from an alert, until the Dart side takes it.
    @Volatile var openRequested = false

    fun register(activity: Activity, messenger: BinaryMessenger) {
        val context = activity.applicationContext
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                // What the job needs to work without the app: where to fetch, the key that signs, and the words, in the app's language.
                "configure" -> {
                    prefs(context).edit()
                        .putString("url", call.argument<String>("url"))
                        .putString("key", call.argument<String>("key"))
                        .putString("title", call.argument<String>("title"))
                        .putString("body", call.argument<String>("body"))
                        .putString("channel", call.argument<String>("channel"))
                        .apply()
                    result.success(null)
                }
                "enable" -> {
                    remember(context, call.argument<String>("known"))
                    if (Build.VERSION.SDK_INT >= 33 &&
                        activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                        pendingEnable?.success(false)
                        pendingEnable = result
                        activity.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), PERMISSION_REQUEST)
                    } else {
                        finishEnable(context, result)
                    }
                }
                "disable" -> { prefs(context).edit().putBoolean("on", false).apply(); cancel(context); result.success(null) }
                "isOn" -> result.success(prefs(context).getBoolean("on", false))
                "allowed" -> result.success(allowed(context))
                "remember" -> { remember(context, call.argument<String>("date")); result.success(null) }
                "openSettings" -> {
                    val intent = Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
                    runCatching { activity.startActivity(intent) }
                    result.success(null)
                }
                "takeOpen" -> { result.success(openRequested); openRequested = false }
                else -> result.notImplemented()
            }
        }
    }

    /// The answer to the notification permission asked for by `enable`.
    fun permissionResult(context: Context) {
        val result = pendingEnable ?: return
        pendingEnable = null
        finishEnable(context, result)
    }

    private fun finishEnable(context: Context, result: MethodChannel.Result) {
        val granted = allowed(context)
        prefs(context).edit().putBoolean("on", granted).apply()
        if (granted) schedule(context) else cancel(context)
        result.success(granted)
    }

    /// Notes an intent that came from an alert.
    fun take(intent: Intent?) {
        if (intent?.getStringExtra(EXTRA_OPEN) == OPEN_SHEET) {
            openRequested = true
            intent.removeExtra(EXTRA_OPEN)
        }
    }

    private fun prefs(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun allowed(context: Context): Boolean {
        val manager = context.getSystemService(NotificationManager::class.java) ?: return false
        if (!manager.areNotificationsEnabled()) return false
        return Build.VERSION.SDK_INT < 33 ||
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
    }

    /// Remembers the newest edition date already on the device or already told, so each edition is told once.
    fun remember(context: Context, date: String?) {
        if (date.isNullOrEmpty()) return
        val known = prefs(context).getString("known", "") ?: ""
        if (date > known) prefs(context).edit().putString("known", date).apply()
    }

    private fun schedule(context: Context) {
        val scheduler = context.getSystemService(JobScheduler::class.java) ?: return
        val job = JobInfo.Builder(JOB_ID, ComponentName(context, LabSheetJob::class.java))
            .setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY)
            .setPeriodic(INTERVAL_MILLIS)
            .setPersisted(true)
            .build()
        runCatching { scheduler.schedule(job) }
    }

    private fun cancel(context: Context) {
        context.getSystemService(JobScheduler::class.java)?.cancel(JOB_ID)
    }

    /// One check, off the main thread: fetch, verify, keep, and tell when the edition is news.
    fun check(context: Context) {
        val settings = prefs(context)
        if (!settings.getBoolean("on", false)) return
        val url = settings.getString("url", null) ?: return
        val key = settings.getString("key", null)?.let { runCatching { publicKey(Base64.decode(it, Base64.DEFAULT)) }.getOrNull() } ?: return
        val saved = savedFile(context)
        val known = maxOf(settings.getString("known", "") ?: "", savedDate(saved) ?: "")
        val payload = fetch(url, key) ?: return
        val edition = runCatching { JSONObject(String(payload, Charsets.UTF_8)) }.getOrNull() ?: return
        val date = edition.optString("date")
        if (edition.optString("format") != FORMAT || edition.optString("id").isEmpty() || date.length != 10 ||
            (edition.optJSONArray("sections")?.length() ?: 0) == 0) return
        // Kept where the app reads its last download (`LabSheetSource.saved`), so the sheet shows it at once.
        if (date >= (savedDate(saved) ?: "")) runCatching { saved.parentFile?.mkdirs(); saved.writeBytes(payload) }
        if (date <= known || !allowed(context)) return
        remember(context, date)
        post(context, date)
    }

    private fun savedFile(context: Context) = File(context.filesDir, "AILab/cheatsheet.json")

    private fun savedDate(file: File): String? =
        runCatching { if (file.exists()) JSONObject(file.readText()).optString("date").ifEmpty { null } else null }.getOrNull()

    private fun fetch(address: String, key: PublicKey): ByteArray? = runCatching {
        val connection = URL(address).openConnection() as HttpURLConnection
        connection.connectTimeout = 15_000
        connection.readTimeout = 20_000
        connection.setRequestProperty("Cache-Control", "no-cache")
        try {
            if (connection.responseCode != 200) return null
            val out = ByteArrayOutputStream()
            connection.inputStream.use { input ->
                val buffer = ByteArray(16 * 1024)
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    out.write(buffer, 0, count)
                    if (out.size() > MAXIMUM_BYTES) return null
                }
            }
            val envelope = JSONObject(out.toString("UTF-8"))
            val payload = Base64.decode(envelope.getString("payload"), Base64.DEFAULT)
            val signature = Base64.decode(envelope.getString("signature"), Base64.DEFAULT)
            val verifier = Signature.getInstance("SHA256withECDSA")
            verifier.initVerify(key)
            verifier.update(payload)
            if (verifier.verify(signature)) payload else null
        } finally {
            connection.disconnect()
        }
    }.getOrNull()

    /// A P-256 public key from its uncompressed X9.63 bytes (`04 || x || y`), as the add-on market publishes it.
    private fun publicKey(x963: ByteArray): PublicKey {
        require(x963.size == 65 && x963[0] == 4.toByte())
        val parameters = AlgorithmParameters.getInstance("EC").apply { init(ECGenParameterSpec("secp256r1")) }
            .getParameterSpec(ECParameterSpec::class.java)
        val point = ECPoint(BigInteger(1, x963.copyOfRange(1, 33)), BigInteger(1, x963.copyOfRange(33, 65)))
        return KeyFactory.getInstance("EC").generatePublic(ECPublicKeySpec(point, parameters))
    }

    private fun post(context: Context, date: String) {
        val settings = prefs(context)
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        if (Build.VERSION.SDK_INT >= 26) {
            val name = settings.getString("channel", null) ?: "Cheat sheet"
            manager.createNotificationChannel(NotificationChannel(NOTIFICATION_CHANNEL, name, NotificationManager.IMPORTANCE_DEFAULT))
        }
        val open = Intent(context, MainActivity::class.java)
            .putExtra(EXTRA_OPEN, OPEN_SHEET)
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        val tap = PendingIntent.getActivity(context, JOB_ID, open, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val stamp = date.replace('-', '.')
        val builder = if (Build.VERSION.SDK_INT >= 26) android.app.Notification.Builder(context, NOTIFICATION_CHANNEL)
        else @Suppress("DEPRECATION") android.app.Notification.Builder(context)
        val notification = builder
            .setSmallIcon(R.drawable.ic_stat_tegnal)
            .setContentTitle(settings.getString("title", null) ?: "A New Cheat Sheet Is Out")
            .setContentText((settings.getString("body", null) ?: "Freshly curated as of %@.").replace("%@", stamp))
            .setContentIntent(tap)
            .setAutoCancel(true)
            .build()
        runCatching { manager.notify("$NOTIFICATION_CHANNEL.$date", JOB_ID, notification) }
    }
}

/// The periodic check `LabSheetAlerts` schedules while its switch is on.
class LabSheetJob : JobService() {
    override fun onStartJob(params: JobParameters): Boolean {
        Thread {
            runCatching { LabSheetAlerts.check(applicationContext) }
            jobFinished(params, false)
        }.start()
        return true
    }

    override fun onStopJob(params: JobParameters): Boolean = true
}
