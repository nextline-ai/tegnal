package work.nextline.tegnal

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Rect
import android.os.Build
import android.os.Handler
import android.os.Looper
import com.google.android.gms.common.api.OptionalModuleApi
import com.google.android.gms.common.moduleinstall.ModuleInstall
import com.google.android.gms.common.moduleinstall.ModuleInstallRequest
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.common.MlKitException
import com.google.mlkit.common.model.DownloadConditions
import com.google.mlkit.genai.common.FeatureStatus
import com.google.mlkit.genai.prompt.Generation
import com.google.mlkit.nl.languageid.LanguageIdentification
import com.google.mlkit.nl.translate.TranslateLanguage
import com.google.mlkit.nl.translate.Translation
import com.google.mlkit.nl.translate.TranslatorOptions
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.Text
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.TextRecognizerOptionsInterface
import com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions
import com.google.mlkit.vision.text.japanese.JapaneseTextRecognizerOptions
import com.google.mlkit.vision.text.korean.KoreanTextRecognizerOptions
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeoutOrNull

/**
 * The native app's image translation on Android: ML Kit reads the text on the device, names its
 * language, and translates it on the device. Translation models download from Google once per
 * language pair; no image or text leaves the device.
 */
object ImageTranslator {
    private const val CHANNEL = "work.nextline.tegnal/translation"
    private val executor = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var context: Context? = null

    fun register(context: Context, messenger: BinaryMessenger) {
        this.context = context.applicationContext
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                // Each language with its name in the app's language, as `Locale.localizedString` gives it.
                "languages" -> {
                    val display = java.util.Locale.forLanguageTag(call.argument<String>("display") ?: "en")
                    result.success(
                        TranslateLanguage.getAllLanguages().map { code ->
                            mapOf("code" to code, "name" to java.util.Locale.forLanguageTag(code).getDisplayName(display))
                        },
                    )
                }
                "translate" -> {
                    val path = call.argument<String>("path")
                    val target = call.argument<String>("target")
                    // Lines of the pages before, original and translated, so a page reads on from the last.
                    val context = call.argument<List<Map<String, String>>>("context").orEmpty()
                        .mapNotNull { pair -> pair["source"]?.let { source -> pair["translation"]?.let { source to it } } }
                    if (path == null || target == null) {
                        result.error("invalid", "An image and a target language are required.", null)
                    } else {
                        executor.execute {
                            val outcome = runCatching { translate(File(path), target, context) }
                            main.post {
                                outcome.fold(
                                    onSuccess = { result.success(it) },
                                    onFailure = { error ->
                                        val code = (error as? TranslationFailure)?.code ?: "failed"
                                        result.error(code, error.message, null)
                                    },
                                )
                            }
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private class TranslationFailure(val code: String, message: String) : Exception(message)

    /**
     * Gemini Nano through Android AICore translates a whole page at once, so speakers keep their
     * voice and a sentence split across balloons reads as one. It runs on the device and is used
     * only where the model is already installed; elsewhere ML Kit Translate takes over.
     */
    private object PageModel {
        fun translate(lines: List<String>, target: String, context: List<Pair<String, String>>): List<String>? {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O || lines.isEmpty()) return null
            val language = java.util.Locale.forLanguageTag(target).getDisplayLanguage(java.util.Locale.ENGLISH)
            val prompt = buildString {
                append("You translate the speech balloons of one comic page into natural, conversational $language. ")
                append("Keep each speaker's tone, keep names consistent with the earlier lines, and keep sound effects short. ")
                append("Reply with exactly one line per numbered line, in the form \"number. translation\", and nothing else.\n\n")
                if (context.isNotEmpty()) {
                    append("Earlier lines, already translated:\n")
                    context.takeLast(12).forEach { (source, translation) -> append("$source → $translation\n") }
                    append("\n")
                }
                append("Lines on this page:\n")
                lines.forEachIndexed { index, line -> append("${index + 1}. ${line.replace('\n', ' ')}\n") }
            }
            return try {
                runBlocking {
                    withTimeoutOrNull(30_000) {
                        val model = Generation.getClient()
                        try {
                            if (model.checkStatus() != FeatureStatus.AVAILABLE) {
                                null
                            } else {
                                parse(model.generateContent(prompt).candidates.firstOrNull()?.text.orEmpty(), lines.size)
                            }
                        } finally {
                            model.close()
                        }
                    }
                }
            } catch (error: Throwable) {
                null
            }
        }

        /** One translation for every numbered line, or nothing when the reply misses some. */
        fun parse(reply: String, count: Int): List<String>? {
            val found = HashMap<Int, String>()
            for (raw in reply.lines()) {
                val line = raw.trim()
                val mark = line.indexOfFirst { it == '.' || it == ')' }
                if (mark <= 0) continue
                val number = line.substring(0, mark).toIntOrNull() ?: continue
                val text = line.substring(mark + 1).trim()
                if (number in 1..count && text.isNotEmpty()) found.putIfAbsent(number, text)
            }
            return if (found.size == count) (1..count).map { found.getValue(it) } else null
        }
    }

    /** One text block with the language it is written in, and its words when it is one line. */
    private class Block(val box: Rect, val text: String, val language: String, val lines: Int, val words: List<Pair<Rect, String>> = emptyList())

    private fun translate(file: File, target: String, context: List<Pair<String, String>>): Map<String, Any?> {
        val bitmap = decode(file) ?: throw TranslationFailure("unsupported", "The image could not be read.")
        try {
            val targetLanguage = TranslateLanguage.fromLanguageTag(target)
                ?: throw TranslationFailure("unsupportedLanguage", "This translation language is not available.")
            val blocks = recognize(InputImage.fromBitmap(bitmap, 0))
            if (blocks.isEmpty()) throw TranslationFailure("noText", "No text was found in this image.")
            // Text already in the target language stays as drawn; only the rest is covered.
            val foreign = blocks.filter { it.language != targetLanguage }
            if (foreign.isEmpty()) throw TranslationFailure("alreadyTarget", "This image is already in the translation language.")
            val translated = HashMap<Block, String>()
            PageModel.translate(foreign.map { it.text }, target, context)?.let { lines ->
                foreign.zip(lines).forEach { (block, line) -> translated[block] = line }
            }
            for ((source, group) in foreign.filter { it !in translated }.groupBy { it.language }) {
                val translator = Translation.getClient(TranslatorOptions.Builder().setSourceLanguage(source).setTargetLanguage(targetLanguage).build())
                try {
                    try {
                        Tasks.await(translator.downloadModelIfNeeded(DownloadConditions.Builder().build()))
                    } catch (error: Exception) {
                        throw TranslationFailure("download", error.message ?: "The translation model could not be downloaded.")
                    }
                    for (block in group) translated[block] = Tasks.await(translator.translate(block.text))
                } finally {
                    translator.close()
                }
            }
            val width = bitmap.width.toDouble()
            val height = bitmap.height.toDouble()
            return mapOf(
                "regions" to foreign.map { block ->
                    mapOf(
                        "text" to translated[block],
                        "source" to block.text,
                        "left" to block.box.left / width,
                        "top" to block.box.top / height,
                        "width" to block.box.width() / width,
                        "height" to block.box.height() / height,
                        "vertical" to columns(block),
                        "lines" to block.lines,
                    )
                },
            )
        } finally {
            bitmap.recycle()
        }
    }

    /** Reads the image at a size the recognizer handles well, at most 4096 pixels on a side. */
    private fun decode(file: File): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.path, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        var sample = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / sample > 4096) sample *= 2
        return BitmapFactory.decodeFile(file.path, BitmapFactory.Options().apply { inSampleSize = sample })
    }

    /**
     * Japanese and Korean need their own recognizers, and a translated page often mixes both, so
     * both read the page: Korean blocks come from the Korean reading, the rest from the Japanese
     * one where no Korean block covers it. Han text with no kana anywhere is read again as Chinese.
     */
    private fun recognize(image: InputImage): List<Block> {
        val japanese = read(image, JapaneseTextRecognizerOptions.Builder().build())
        val korean = read(image, KoreanTextRecognizerOptions.Builder().build())
        val koreanBlocks = korean.textBlocks.filter { block -> block.boundingBox != null && block.text.any(::isHangul) }
        val chinese = japanese.text.none(::isKana) && japanese.text.any(::isHan) && koreanBlocks.isEmpty()
        val others = (if (chinese) read(image, ChineseTextRecognizerOptions.Builder().build()) else japanese).textBlocks
            .filter { block -> block.boundingBox != null && block.text.isNotBlank() && koreanBlocks.none { overlaps(it.boundingBox!!, block.boundingBox!!) } }
        val pieces = (koreanBlocks + others).flatMap { block ->
            val language = language(block.text, chinese)
            block.lines.flatMap { line -> segments(line, language) }
        }
        return balloons(separate(pieces).filter { it.text.isNotBlank() && it.text.any(Char::isLetter) })
    }

    /**
     * A recognized line can run across two balloons that sit side by side. A line breaks where
     * the gap between its words is wider than a word is tall, or where the next word sits
     * higher or lower by half its height; each piece is one line of one balloon.
     */
    private fun segments(line: Text.Line, language: String): List<Block> {
        val box = line.boundingBox ?: return emptyList()
        val vertical = cjk(language) && box.height() > box.width() * 1.6
        val elements = line.elements.filter { it.boundingBox != null }
            .sortedBy { if (vertical) it.boundingBox!!.top else it.boundingBox!!.left }
        if (elements.isEmpty()) return listOf(Block(Rect(box), line.text.trim(), language, 1, listOf(Rect(box) to line.text.trim())))
        val groups = mutableListOf(mutableListOf(elements[0]))
        for (element in elements.drop(1)) {
            val previous = groups.last().last().boundingBox!!
            val next = element.boundingBox!!
            // Word size, not the line's box, which grows when the line wanders across balloons.
            val thickness = if (vertical) minOf(previous.width(), next.width()) else minOf(previous.height(), next.height())
            val gap = if (vertical) next.top - previous.bottom else next.left - previous.right
            val drift = if (vertical) Math.abs(next.centerX() - previous.centerX()) else Math.abs(next.centerY() - previous.centerY())
            if (gap > thickness || drift > thickness / 2) groups.add(mutableListOf(element)) else groups.last().add(element)
        }
        return groups.map { group -> line(group.map { Rect(it.boundingBox!!) to it.text.trim() }, language) }
    }

    private fun line(words: List<Pair<Rect, String>>, language: String): Block {
        val union = Rect(words[0].first)
        for ((box, _) in words) union.union(box)
        return Block(union, words.joinToString(if (cjk(language)) "" else " ") { it.second }, language, 1, words)
    }

    /**
     * Two balloons side by side can share a line whose word gap looks like any other. Such a
     * line breaks between words that stack with different lines above or below it: the left
     * words continue one balloon and the right words another.
     */
    private fun separate(pieces: List<Block>): List<Block> = pieces.flatMap { piece ->
        if (piece.words.size < 2 || columns(piece)) return@flatMap listOf(piece)
        val others = pieces.filter { it !== piece && it.language == piece.language && !columns(it) }
        fun stacked(word: Rect): Set<Block> = others.filter { other ->
            val gap = maxOf(word.top, other.box.top) - minOf(word.bottom, other.box.bottom)
            val shared = minOf(word.right, other.box.right) - maxOf(word.left, other.box.left)
            gap <= maxOf(word.height(), other.box.height()) * 0.6 && shared >= minOf(word.width(), other.box.width()) * 0.5
        }.toSet()
        val groups = mutableListOf(mutableListOf(piece.words[0]))
        var previous = stacked(piece.words[0].first)
        for (word in piece.words.drop(1)) {
            val current = stacked(word.first)
            if (previous.isNotEmpty() && current.isNotEmpty() && previous.intersect(current).isEmpty()) groups.add(mutableListOf(word)) else groups.last().add(word)
            if (current.isNotEmpty()) previous = current
        }
        if (groups.size == 1) listOf(piece) else groups.map { line(it, piece.language) }
    }

    private fun cjk(language: String) = language == TranslateLanguage.JAPANESE || language == TranslateLanguage.CHINESE

    /** Whether a block reads in vertical columns, as Japanese and Chinese balloons often do. */
    private fun columns(block: Block) = cjk(block.language) && block.box.height() > block.box.width() * 1.6

    /** A block's line height, or column width for vertical text. */
    private fun unit(block: Block) = (if (columns(block)) block.box.width() else block.box.height()).toDouble() / maxOf(1, block.lines)

    /**
     * Hand-lettered balloons often come back one line per block. Blocks of one language that sit
     * line after line, close and overlapping along the line, are one balloon: they are translated
     * as one sentence under one label. Balloons side by side do not overlap that way and stay apart.
     */
    private fun balloons(blocks: List<Block>): List<Block> {
        val parent = IntArray(blocks.size) { it }
        fun root(i: Int): Int {
            var r = i
            while (parent[r] != r) r = parent[r]
            return r
        }
        for (i in blocks.indices) for (j in i + 1 until blocks.size) {
            val a = blocks[i]
            val b = blocks[j]
            if (a.language != b.language || columns(a) != columns(b)) continue
            // Lines of one balloon share a size, follow each other closely and overlap along the
            // line for at least half of the shorter one.
            val unit = maxOf(unit(a), unit(b))
            if (minOf(unit(a), unit(b)) * 2.2 < unit) continue
            val joins = if (columns(a)) {
                val gap = maxOf(a.box.left, b.box.left) - minOf(a.box.right, b.box.right)
                val shared = minOf(a.box.bottom, b.box.bottom) - maxOf(a.box.top, b.box.top)
                gap <= unit * 0.6 && shared >= minOf(a.box.height(), b.box.height()) * 0.5
            } else {
                val gap = maxOf(a.box.top, b.box.top) - minOf(a.box.bottom, b.box.bottom)
                val shared = minOf(a.box.right, b.box.right) - maxOf(a.box.left, b.box.left)
                gap <= unit * 0.6 && shared >= minOf(a.box.width(), b.box.width()) * 0.5
            }
            if (joins) parent[root(j)] = root(i)
        }
        return blocks.indices.groupBy(::root).values.map { members ->
            val group = members.map { blocks[it] }
            if (group.size == 1) return@map group[0]
            val vertical = columns(group[0])
            // Vertical columns read right to left; lines read top to bottom.
            val ordered = if (vertical) group.sortedByDescending { it.box.right } else group.sortedBy { it.box.top }
            val language = group[0].language
            val separator = if (cjk(language)) "" else " "
            val box = Rect(ordered[0].box)
            for (block in ordered) box.union(block.box)
            Block(box, ordered.joinToString(separator) { it.text }, language, ordered.sumOf { it.lines })
        }
    }

    private fun isKana(c: Char) = c in '\u3040'..'\u30FF'
    private fun isHan(c: Char) = c in '\u4E00'..'\u9FFF'
    private fun isHangul(c: Char) = c in '\uAC00'..'\uD7A3'

    /** Whether two blocks share at least a third of the smaller one. */
    private fun overlaps(a: Rect, b: Rect): Boolean {
        val shared = Rect()
        if (!shared.setIntersect(a, b)) return false
        val area = shared.width().toLong() * shared.height()
        val smaller = minOf(a.width().toLong() * a.height(), b.width().toLong() * b.height())
        return smaller > 0 && area * 3 >= smaller
    }

    private fun read(image: InputImage, options: TextRecognizerOptionsInterface): Text {
        val recognizer = TextRecognition.getClient(options)
        try {
            return whenInstalled(recognizer) { Tasks.await(recognizer.process(image)) }
        } catch (error: TranslationFailure) {
            throw error
        } catch (error: Exception) {
            throw TranslationFailure("recognition", error.message ?: "Text recognition is not available on this device.")
        } finally {
            recognizer.close()
        }
    }

    /**
     * Recognition models arrive through Google Play services. The manifest asks for them at install,
     * and a model still missing is requested here and waited for, up to a minute and a half.
     */
    private fun <T> whenInstalled(api: OptionalModuleApi, work: () -> T): T {
        val deadline = System.currentTimeMillis() + 90_000
        var requested = false
        while (true) {
            try {
                return work()
            } catch (error: Exception) {
                val missing = (error.cause as? MlKitException ?: error as? MlKitException)?.errorCode == MlKitException.UNAVAILABLE
                if (!missing || System.currentTimeMillis() > deadline) throw error
                if (!requested) {
                    requested = true
                    context?.let { ModuleInstall.getClient(it).installModules(ModuleInstallRequest.newBuilder().addApi(api).build()) }
                }
                Thread.sleep(1500)
            }
        }
    }

    /** A block's language: its script decides for Korean, Japanese and Chinese; other text is identified. */
    private fun language(text: String, chinese: Boolean): String {
        when {
            text.any(::isHangul) -> return TranslateLanguage.KOREAN
            text.any(::isKana) -> return TranslateLanguage.JAPANESE
            text.any(::isHan) -> return if (chinese) TranslateLanguage.CHINESE else TranslateLanguage.JAPANESE
        }
        val identifier = LanguageIdentification.getClient()
        val identified = try {
            whenInstalled(identifier) { Tasks.await(identifier.identifyLanguage(text)) }
        } catch (_: Exception) {
            "und"
        } finally {
            identifier.close()
        }
        return TranslateLanguage.fromLanguageTag(identified) ?: TranslateLanguage.ENGLISH
    }
}
