package work.nextline.tegnal

import android.app.Activity
import android.app.ActivityManager
import android.view.WindowManager
import android.graphics.Color
import android.graphics.drawable.ColorDrawable
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.View
import android.view.ViewGroup
import android.view.animation.AccelerateDecelerateInterpolator
import android.animation.ValueAnimator
import android.widget.FrameLayout
import android.widget.ImageView
import java.util.Collections
import java.util.WeakHashMap

/** Branded resume overlay and separate OS protection for task snapshots. */
class PrivacyCover(private val activity: Activity) {
    private val handler = Handler(Looper.getMainLooper())
    private val decor: ViewGroup? get() = activity.window.decorView as? ViewGroup
    private var artwork: FrameLayout? = null
    private var hiddenContent: View? = null
    private var priorContentAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_AUTO
    private var hideRunnable: Runnable? = null
    private var isHiding = false
    private var animationGeneration = 0

    companion object {
        @Volatile private var appAppearanceDark: Boolean? = null
        private val instances = Collections.newSetFromMap(
            WeakHashMap<PrivacyCover, Boolean>()
        )

        /** Called by the Flutter privacy widget when the app theme changes. */
        @JvmStatic
        fun setAppAppearance(dark: Boolean) {
            appAppearanceDark = dark
            synchronized(instances) {
                instances.toList().forEach { it.updateVisibleArtwork() }
            }
        }
    }

    init {
        synchronized(instances) { instances.add(this) }
    }

    /** Recents can snapshot before lifecycle callbacks have drawn an overlay. */
    fun protectTaskSnapshot() {
        if (Build.VERSION.SDK_INT >= 33) {
            activity.setRecentsScreenshotEnabled(false)
            updateTaskAppearance()
        } else {
            // Older Android has no Overview-only protection API. A secure
            // window also prevents screenshots/recording on those releases.
            activity.window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        }
    }

    private fun updateTaskAppearance() {
        if (Build.VERSION.SDK_INT < 33) return
        val background = if (isDarkAppearance()) Color.BLACK else Color.WHITE
        activity.setTaskDescription(
            ActivityManager.TaskDescription.Builder()
                .setLabel("TEGNAL")
                .setIcon(R.mipmap.ic_launcher)
                .setBackgroundColor(background)
                .setPrimaryColor(background)
                .build(),
        )
    }

    /** Add the cover synchronously before Activity.onPause returns. */
    fun show() {
        runOnMain {
            val root = decor ?: return@runOnMain
            animationGeneration++
            hideRunnable?.let(handler::removeCallbacks)
            hideRunnable = null
            isHiding = false

            val cover = artwork ?: createArtwork().also { artwork = it }
            cover.animate().cancel()
            cover.translationY = 0f
            cover.alpha = 1f
            cover.importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_YES
            if (cover.parent !== root) {
                (cover.parent as? ViewGroup)?.removeView(cover)
                root.addView(
                    cover,
                    ViewGroup.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT,
                        ViewGroup.LayoutParams.MATCH_PARENT,
                    ),
                )
            } else {
                cover.bringToFront()
            }
            hideUnderlyingSemantics(root)
            cover.invalidate()
            root.invalidate()
        }
    }

    /** Keep the cover opaque for 600 ms, then slide it away over 900 ms. */
    fun hide(
        holdMillis: Long = 600L,
        slideMillis: Long = 900L,
    ) {
        runOnMain {
            val cover = artwork ?: return@runOnMain
            if (hideRunnable != null || isHiding) return@runOnMain
            val token = ++animationGeneration
            val task = Runnable {
                if (token != animationGeneration || artwork !== cover) return@Runnable
                val reduceMotion = animationsDisabled()
                cover.animate().cancel()
                cover.importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
                isHiding = true
                cover.animate()
                    .setDuration(if (reduceMotion) 150L else slideMillis)
                    .setInterpolator(AccelerateDecelerateInterpolator())
                    .apply {
                        if (reduceMotion) alpha(0f)
                        else translationY(-maxOf(cover.height, decor?.height ?: 0).toFloat() - 1f)
                    }
                    .withEndAction {
                        if (token == animationGeneration && artwork === cover) {
                            removeCover(cover)
                        }
                    }
                    .start()
                hideRunnable = null
            }
            hideRunnable = task
            handler.postDelayed(task, holdMillis.coerceAtLeast(0L))
        }
    }

    /** Remove the overlay and restore the pre-cover accessibility state. */
    fun dispose() {
        runOnMain {
            animationGeneration++
            hideRunnable?.let(handler::removeCallbacks)
            hideRunnable = null
            artwork?.animate()?.cancel()
            artwork?.let(::removeCover)
            synchronized(instances) { instances.remove(this) }
        }
    }

    private fun createArtwork(): FrameLayout {
        val dark = isDarkAppearance()
        val cover = FrameLayout(activity).apply {
            setBackgroundColor(if (dark) Color.BLACK else Color.WHITE)
            isClickable = true
            isFocusable = false
            isFocusableInTouchMode = false
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_YES
            contentDescription = "TEGNAL"
            setOnTouchListener { _, _ -> true }
        }
        cover.addView(
            ImageView(activity).apply {
                setImageResource(
                    if (dark) R.drawable.tegnal_splash_dark
                    else R.drawable.tegnal_splash_light,
                )
                scaleType = ImageView.ScaleType.FIT_CENTER
                contentDescription = null
                importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
            },
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT,
            ),
        )
        return cover
    }

    private fun hideUnderlyingSemantics(root: ViewGroup) {
        val content = root.findViewById<View>(android.R.id.content) ?: return
        if (hiddenContent !== content) {
            restoreUnderlyingSemantics()
            hiddenContent = content
            priorContentAccessibility = content.importantForAccessibility
        }
        content.importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
    }

    private fun restoreUnderlyingSemantics() {
        hiddenContent?.importantForAccessibility = priorContentAccessibility
        hiddenContent = null
    }

    private fun removeCover(cover: View) {
        (cover.parent as? ViewGroup)?.removeView(cover)
        restoreUnderlyingSemantics()
        if (artwork === cover) artwork = null
        hideRunnable = null
        isHiding = false
    }

    private fun updateVisibleArtwork() {
        runOnMain {
            // Flutter supplies the saved theme, including an explicit light
            // choice. Keep uncovered window/IME transition pixels consistent.
            activity.window.setBackgroundDrawable(
                ColorDrawable(if (isDarkAppearance()) Color.BLACK else Color.WHITE),
            )
            updateTaskAppearance()
            val cover = artwork ?: return@runOnMain
            if (cover.parent == null) return@runOnMain
            val dark = isDarkAppearance()
            cover.setBackgroundColor(if (dark) Color.BLACK else Color.WHITE)
            (cover.getChildAt(0) as? ImageView)?.setImageResource(
                if (dark) R.drawable.tegnal_splash_dark
                else R.drawable.tegnal_splash_light,
            )
        }
    }

    private fun isDarkAppearance(): Boolean = appAppearanceDark ?: true

    private fun animationsDisabled(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            !ValueAnimator.areAnimatorsEnabled()
        } else {
            Settings.Global.getFloat(
                activity.contentResolver,
                Settings.Global.ANIMATOR_DURATION_SCALE,
                1f,
            ) == 0f
        }

    private fun runOnMain(action: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) action()
        else activity.runOnUiThread(action)
    }
}
