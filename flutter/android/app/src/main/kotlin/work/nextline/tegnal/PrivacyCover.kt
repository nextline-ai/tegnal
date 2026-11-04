package work.nextline.tegnal

import android.animation.ValueAnimator
import android.app.Activity
import android.app.ActivityManager
import android.content.Context
import android.graphics.Color
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.view.animation.AccelerateDecelerateInterpolator
import android.widget.FrameLayout
import android.widget.ImageView

/**
 * The native app's `SplashArtwork`: the brand artwork over the whole window, at launch and
 * whenever the app leaves the foreground, so the app switcher never shows what was open.
 * It is a plain view on the window, so it is in place before Activity callbacks return.
 */
class PrivacyCover(private val activity: Activity) {
    /** `SplashTiming`: how long the artwork stays, then how long it takes to slide up. */
    data class Timing(val holdMillis: Long, val slideMillis: Long) {
        companion object {
            val launch = Timing(1200, 1800)
            val resume = Timing(600, 900)
            val none = Timing(0, 0)
        }
    }

    private val handler = Handler(Looper.getMainLooper())
    private val decor: ViewGroup? get() = activity.window.decorView as? ViewGroup
    private val stored = activity.getSharedPreferences("privacy_cover", Context.MODE_PRIVATE)
    private var cover: FrameLayout? = null
    private var pendingHide: Runnable? = null
    private var hiding = false
    private var generation = 0
    private var hiddenContent: View? = null
    private var priorAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_AUTO

    /** The app's resolved appearance; remembered so the next launch starts with the right artwork. */
    var dark: Boolean = stored.getBoolean("dark", true)
        set(value) {
            if (field == value) return
            field = value
            stored.edit().putBoolean("dark", value).apply()
            updateAppearance()
            updateLaunchScreen()
        }

    /** "Play Animation When Returning": without it the cover leaves at once. */
    var resumeAnimation: Boolean = true

    val isVisible: Boolean get() = cover?.parent != null && !hiding

    /**
     * The app switcher may capture the window before lifecycle callbacks run, so its
     * thumbnail is protected separately. Android 13 and later hide only that thumbnail.
     */
    fun protectTaskSnapshot() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            activity.setRecentsScreenshotEnabled(false)
        }
        updateTaskAppearance()
        updateLaunchScreen()
    }

    /// The system launch screen of the next start takes the app's appearance, so the empty
    /// screen before the artwork is already black or white. Android 12 keeps the default black.
    private fun updateLaunchScreen() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        activity.splashScreen.setSplashScreenTheme(if (dark) R.style.LaunchTheme_Dark else R.style.LaunchTheme_Light)
    }

    /** Covers the window right away, keeping it until [hide]. */
    fun show() {
        val root = decor ?: return
        generation++
        pendingHide?.let(handler::removeCallbacks)
        pendingHide = null
        hiding = false
        val view = cover ?: makeCover().also { cover = it }
        view.animate().cancel()
        view.translationY = 0f
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

    /** Holds the artwork, then slides it up (a short fade with animations turned off). */
    fun hide(timing: Timing) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) activity.window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
        val view = cover ?: return
        if (view.parent == null || pendingHide != null || hiding) return
        val token = ++generation
        if (timing.holdMillis == 0L && timing.slideMillis == 0L) {
            remove(view)
            return
        }
        val task = Runnable {
            pendingHide = null
            if (token != generation || cover !== view) return@Runnable
            val reduceMotion = animationsOff()
            hiding = true
            view.importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
            restoreContentAccessibility()
            view.animate()
                .setDuration(if (reduceMotion) 150L else timing.slideMillis)
                .setInterpolator(AccelerateDecelerateInterpolator())
                .apply {
                    if (reduceMotion) alpha(0f) else translationY(-maxOf(view.height, decor?.height ?: 0).toFloat() - 1f)
                }
                .withEndAction { if (token == generation && cover === view) remove(view) }
                .start()
        }
        pendingHide = task
        handler.postDelayed(task, timing.holdMillis)
    }

    private fun makeCover(): FrameLayout = FrameLayout(activity).apply {
        setBackgroundColor(if (dark) Color.BLACK else Color.WHITE)
        // The cover takes every touch, so nothing under it can be pressed while it is shown.
        isClickable = true
        isFocusable = false
        contentDescription = "TEGNAL"
        setOnTouchListener { _, _ -> true }
        addView(
            ImageView(activity).apply {
                setImageResource(if (dark) R.drawable.tegnal_splash_dark else R.drawable.tegnal_splash_light)
                scaleType = ImageView.ScaleType.FIT_CENTER
                importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
            },
            FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT),
        )
    }

    private fun updateAppearance() {
        updateTaskAppearance()
        val view = cover ?: return
        view.setBackgroundColor(if (dark) Color.BLACK else Color.WHITE)
        (view.getChildAt(0) as? ImageView)?.setImageResource(if (dark) R.drawable.tegnal_splash_dark else R.drawable.tegnal_splash_light)
    }

    /** The switcher's blank card takes the app's background, as the artwork's own edges do. */
    private fun updateTaskAppearance() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        val background = if (dark) Color.BLACK else Color.WHITE
        activity.setTaskDescription(
            ActivityManager.TaskDescription.Builder()
                .setLabel("TEGNAL")
                .setBackgroundColor(background)
                .setPrimaryColor(background)
                .build(),
        )
    }

    private fun remove(view: View) {
        (view.parent as? ViewGroup)?.removeView(view)
        restoreContentAccessibility()
        if (cover === view) cover = null
        pendingHide = null
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
}
