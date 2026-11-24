package work.nextline.tegnal

import android.animation.ValueAnimator
import android.app.Activity
import android.app.ActivityManager
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.os.Build
import android.provider.Settings
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.view.animation.LinearInterpolator
import android.widget.FrameLayout
import android.widget.ImageView
import androidx.core.content.ContextCompat
import org.json.JSONObject
import java.io.File

/**
 * The native app's `PrivacyCoverManager`: the home scene's blurred still over the whole window,
 * at launch and whenever the app leaves the foreground, so the app switcher never shows what
 * was open. It is a plain view on the window, so it is in place before Activity callbacks
 * return. The picture is the same in light and dark appearance, on the dusk colour.
 */
class PrivacyCover(private val activity: Activity) {
    private val decor: ViewGroup? get() = activity.window.decorView as? ViewGroup
    private val dusk: Int get() = ContextCompat.getColor(activity, R.color.home_dusk)
    private var cover: FrameLayout? = null
    private var picture: ImageView? = null
    private var stillKey: String? = null
    private var hiding = false
    private var generation = 0
    private var hiddenContent: View? = null
    private var priorAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_AUTO

    val isVisible: Boolean get() = cover?.parent != null && !hiding

    /**
     * The app switcher may capture the window before lifecycle callbacks run, so its
     * thumbnail is protected separately. Android 13 and later hide only that thumbnail.
     */
    fun protectTaskSnapshot() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            activity.setRecentsScreenshotEnabled(false)
            // The switcher's blank card takes the dusk colour, as the still's own edges do.
            activity.setTaskDescription(
                ActivityManager.TaskDescription.Builder()
                    .setLabel("TEGNAL")
                    .setBackgroundColor(dusk)
                    .setPrimaryColor(dusk)
                    .build(),
            )
        }
    }

    /**
     * Covers the window right away, keeping it until [hide]. At [launch] the cover is plain black, as the system launch screen
     * is, so every home scene can fade in from it; later it is the chosen home scene's blurred still.
     */
    fun show(launch: Boolean = false) {
        val root = decor ?: return
        generation++
        hiding = false
        val view = cover ?: makeCover().also { cover = it }
        view.setBackgroundColor(if (launch) ContextCompat.getColor(activity, R.color.launch_black) else dusk)
        picture?.let { image ->
            image.visibility = if (launch) View.GONE else View.VISIBLE
            if (!launch) showStill(image)
        }
        view.animate().cancel()
        view.alpha = 1f
        view.importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_YES
        if (view.parent !== root) {
            (view.parent as? ViewGroup)?.removeView(view)
            root.addView(view, ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        } else {
            view.bringToFront()
        }
        hideContentFromAccessibility(root)
        // Older systems have no thumbnail-only protection; a secure window keeps the
        // switcher blank only while the app is away, so screenshots still work in it.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) activity.window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
    }

    /**
     * Fades the cover out over [fadeMillis] (`PrivacyCoverManager.hide(animated:)`); zero
     * removes it at once. With system animations turned off the fade is short, or skipped.
     */
    fun hide(fadeMillis: Long) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) activity.window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
        val view = cover ?: return
        if (view.parent == null || hiding) return
        val token = ++generation
        if (fadeMillis <= 0L || animationsOff()) {
            remove(view)
            return
        }
        hiding = true
        view.importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
        restoreContentAccessibility()
        view.animate()
            .alpha(0f)
            .setDuration(fadeMillis)
            .setInterpolator(LinearInterpolator())
            .withEndAction { if (token == generation && cover === view) remove(view) }
            .start()
    }

    /** The dusk colour with the still over it, framed as the home scene frames it (black alone at launch). */
    private fun makeCover(): FrameLayout = FrameLayout(activity).apply {
        setBackgroundColor(dusk)
        // The cover takes every touch, so nothing under it can be pressed while it is shown.
        isClickable = true
        isFocusable = false
        contentDescription = "TEGNAL"
        setOnTouchListener { _, _ -> true }
        val image = ImageView(activity).apply {
            setImageResource(R.drawable.home_blur)
            scaleType = ImageView.ScaleType.MATRIX
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
        }
        picture = image
        // The matrix follows every layout change: rotation, split screen, a resized window.
        image.addOnLayoutChangeListener { v, _, _, _, _, _, _, _, _ -> frame(v as ImageView) }
        addView(image, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
    }

    /** The still of the home scene chosen in the shop (`HomeScenes` in `lab_goods.dart`), else the app's own. */
    private fun showStill(image: ImageView) {
        val chosen = try {
            val root = File(activity.filesDir, "HomeScenes")
            val item = File(root, "chosen.txt").takeIf { it.isFile }?.readText()?.trim().orEmpty()
            if (item.isEmpty()) {
                null
            } else {
                val scene = JSONObject(File(root, "$item/scene.json").readText())
                val name = scene.getJSONObject("files").getJSONArray("still").getString(0)
                File(root, "$item/$name").takeIf { it.isFile }
            }
        } catch (_: Exception) {
            null
        }
        // Decoded once per file: the cover goes up as the app leaves, when there is no time to spare.
        val key = chosen?.let { "${it.path}:${it.lastModified()}" }
        if (key == stillKey) return
        stillKey = key
        val bitmap = chosen?.let { BitmapFactory.decodeFile(it.path) }
        if (bitmap != null) image.setImageBitmap(bitmap) else image.setImageResource(R.drawable.home_blur)
        frame(image)
    }

    /**
     * `HomeFraming.frame(in:)`: the picture scaled to cover the window, its focus point
     * (x 0.5, y 0.388 of the picture) at the window's centre, clamped so no edge shows.
     */
    private fun frame(picture: ImageView) {
        val drawable = picture.drawable ?: return
        val viewW = picture.width.toFloat()
        val viewH = picture.height.toFloat()
        val imageW = drawable.intrinsicWidth.toFloat()
        val imageH = drawable.intrinsicHeight.toFloat()
        if (viewW <= 0f || viewH <= 0f || imageW <= 0f || imageH <= 0f) return
        val scale = maxOf(viewW / imageW, viewH / imageH)
        val w = imageW * scale
        val h = imageH * scale
        val x = minOf(0f, maxOf(viewW - w, viewW / 2f - w * FOCUS_X))
        val y = minOf(0f, maxOf(viewH - h, viewH / 2f - h * FOCUS_Y))
        picture.imageMatrix = Matrix().apply {
            setScale(scale, scale)
            postTranslate(x, y)
        }
    }

    private fun remove(view: View) {
        (view.parent as? ViewGroup)?.removeView(view)
        restoreContentAccessibility()
        if (cover === view) cover = null
        hiding = false
    }

    private fun hideContentFromAccessibility(root: ViewGroup) {
        val content = root.findViewById<View>(android.R.id.content) ?: return
        if (hiddenContent !== content) {
            restoreContentAccessibility()
            hiddenContent = content
            priorAccessibility = content.importantForAccessibility
        }
        content.importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
    }

    private fun restoreContentAccessibility() {
        hiddenContent?.importantForAccessibility = priorAccessibility
        hiddenContent = null
    }

    /** `UIAccessibility.isReduceMotionEnabled`: Android's "Remove animations". */
    private fun animationsOff(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            !ValueAnimator.areAnimatorsEnabled()
        } else {
            Settings.Global.getFloat(activity.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f
        }

    companion object {
        /** `PrivacyCoverManager.fade`: how long the cover takes to leave when returning. */
        const val RESUME_FADE = 300L

        /** The launch cover's fade once the home scene's first picture is on screen. */
        const val LAUNCH_FADE = 180L

        /** `HomeFraming`: the point of the picture kept at the window's centre. */
        private const val FOCUS_X = 0.5f
        private const val FOCUS_Y = 0.388f
    }
}
