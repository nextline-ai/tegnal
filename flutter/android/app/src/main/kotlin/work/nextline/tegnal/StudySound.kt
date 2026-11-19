package work.nextline.tegnal

import android.content.Context
import android.media.AudioAttributes
import android.media.SoundPool
import io.flutter.FlutterInjector
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Learning mode's sounds. They play on the media volume (the volume buttons turn them up and down, the ringer
 * and silent mode do not mute them) and no audio focus is requested, so the learner's own music keeps playing
 * underneath. The WAV files are Flutter assets, `assets/study/sounds/StudySound-<name>.wav`.
 */
object StudySound {
    private const val CHANNEL = "work.nextline.tegnal/study_sound"
    private var context: Context? = null
    private var pool: SoundPool? = null
    /** Sound name to the id the pool gave it. */
    private val ids = HashMap<String, Int>()
    /** Ids whose data has finished loading. */
    private val ready = HashSet<Int>()
    /** Ids asked to play before they finished loading. */
    private val waiting = HashSet<Int>()

    fun register(context: Context, messenger: BinaryMessenger) {
        this.context = context.applicationContext
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "warm" -> {
                    call.argument<List<String>>("names")?.forEach { load(it) }
                    result.success(null)
                }
                "play" -> {
                    call.argument<String>("name")?.let { play(it) }
                    result.success(null)
                }
                "rest" -> {
                    release()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    @Synchronized
    private fun soundPool(): SoundPool = pool ?: run {
        val attributes = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_GAME)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
            .build()
        val created = SoundPool.Builder().setMaxStreams(4).setAudioAttributes(attributes).build()
        created.setOnLoadCompleteListener { player, id, status ->
            if (status != 0) return@setOnLoadCompleteListener
            synchronized(this) {
                ready.add(id)
                if (waiting.remove(id)) player.play(id, 1f, 1f, 1, 0, 1f)
            }
        }
        pool = created
        created
    }

    @Synchronized
    private fun load(name: String): Int? {
        ids[name]?.let { return it }
        val context = context ?: return null
        // Names come from the app's own enum; refuse anything that could leave the sounds folder.
        if (!name.all { it.isLetterOrDigit() }) return null
        val key = FlutterInjector.instance().flutterLoader().getLookupKeyForAsset("assets/study/sounds/StudySound-$name.wav")
        val player = soundPool()
        val id = try {
            context.assets.openFd(key).use { player.load(it, 1) }
        } catch (error: Exception) {
            // An asset the package compressed cannot be opened as a file descriptor; copy it out once instead.
            try {
                val file = File(context.cacheDir, "StudySound-$name.wav")
                if (!file.exists()) context.assets.open(key).use { input -> file.outputStream().use { input.copyTo(it) } }
                player.load(file.absolutePath, 1)
            } catch (error: Exception) {
                return null
            }
        }
        ids[name] = id
        return id
    }

    @Synchronized
    private fun play(name: String) {
        val id = load(name) ?: return
        if (ready.contains(id)) soundPool().play(id, 1f, 1f, 1, 0, 1f) else waiting.add(id)
    }

    @Synchronized
    private fun release() {
        pool?.release()
        pool = null
        ids.clear()
        ready.clear()
        waiting.clear()
    }
}
