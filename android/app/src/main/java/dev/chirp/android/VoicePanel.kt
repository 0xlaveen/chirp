package dev.chirp.android

import android.animation.ValueAnimator
import android.annotation.SuppressLint
import android.content.Context
import android.content.res.ColorStateList
import android.content.res.Configuration
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.drawable.GradientDrawable
import android.text.SpannableString
import android.text.Spanned
import android.text.style.ForegroundColorSpan
import android.view.Gravity
import android.view.View
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import androidx.compose.ui.graphics.toArgb
import com.google.android.material.button.MaterialButton
import dev.chirp.android.ui.chirpColorScheme
import kotlin.math.max

internal data class VoicePalette(val background: Int, val surface: Int, val ink: Int, val muted: Int, val accent: Int, val onAccent: Int,
                                 val accentContainer: Int, val onAccentContainer: Int, val secondaryContainer: Int, val onSecondaryContainer: Int,
                                 val errorContainer: Int, val onErrorContainer: Int) {
    companion object {
        /** The app's colours: wallpaper dynamic colour unless "App colours" is Chirp green (also before first unlock). */
        fun of(context: Context): VoicePalette {
            val night = context.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES
            val dynamic = runCatching { SettingsStore(context).dynamicColor }.getOrDefault(false)
            val scheme = chirpColorScheme(context, night, dynamic)
            fun roles(base: VoicePalette) = base.copy(accentContainer = scheme.primaryContainer.toArgb(), onAccentContainer = scheme.onPrimaryContainer.toArgb(),
                secondaryContainer = scheme.secondaryContainer.toArgb(), onSecondaryContainer = scheme.onSecondaryContainer.toArgb(),
                errorContainer = scheme.errorContainer.toArgb(), onErrorContainer = scheme.onErrorContainer.toArgb())
            val none = Color.TRANSPARENT
            if (dynamic) return scheme.run {
                roles(VoicePalette(surface.toArgb(), surfaceContainer.toArgb(), onSurface.toArgb(), onSurfaceVariant.toArgb(), primary.toArgb(), onPrimary.toArgb(), none, none, none, none, none, none))
            }
            return roles(if (night) VoicePalette(Color.rgb(18, 23, 21), Color.rgb(32, 42, 37), Color.rgb(227, 235, 229), Color.rgb(164, 184, 172), Color.rgb(159, 211, 185), Color.rgb(18, 56, 42), none, none, none, none, none, none)
            else VoicePalette(Color.rgb(246, 250, 246), Color.rgb(230, 239, 232), Color.rgb(24, 45, 37), Color.rgb(83, 105, 92), Color.rgb(56, 106, 88), Color.WHITE, none, none, none, none, none, none))
        }
    }
}

/** Fills or outlines a button in the palette accent instead of the theme's fixed colorPrimary, with Material's disabled alphas. */
internal fun MaterialButton.accent(colors: VoicePalette, filled: Boolean) {
    fun states(on: Int, off: Int) = ColorStateList(arrayOf(intArrayOf(-android.R.attr.state_enabled), intArrayOf()), intArrayOf(off, on))
    val content = states(if (filled) colors.onAccent else colors.accent, colors.ink and 0x00ffffff or 0x61000000)
    if (filled) backgroundTintList = states(colors.accent, colors.ink and 0x00ffffff or 0x1F000000)
    setTextColor(content); iconTint = content
}

/** Native Material 3 surface usable from both IME and non-focusable accessibility windows. */
@SuppressLint("SetTextI18n")
internal class VoicePanel(context: Context) : LinearLayout(context) {
    private val colors = VoicePalette.of(context)
    val banner = context.label("").apply { visibility = GONE }
    val status = context.label("Ready to dictate", 14f)
    val transcript = context.label("Tap to dictate · hold to talk", 19f)
    val mic = MaterialButton(context).apply {
        text = "Tap to dictate"; setIconResource(R.drawable.ic_mic); minHeight = context.dp(72)
        contentDescription = "Microphone: tap to toggle, hold to talk"
        accent(colors, filled = true)
    }
    val raw = MaterialButton(context).apply { text = "Use raw"; visibility = GONE; accent(colors, filled = true) }
    val controls = LinearLayout(context).apply { gravity = Gravity.CENTER }
    val extras = LinearLayout(context).apply { orientation = VERTICAL }
    private val ring = LevelRing(context)
    init {
        orientation = VERTICAL
        setPadding(context.dp(16), context.dp(8), context.dp(16), context.dp(8))
        background = GradientDrawable().apply { setColor(this@VoicePanel.colors.background); cornerRadius = context.dp(28).toFloat() }
        addView(context.label("CHIRP  /  VOICE", 12f).apply { setTextColor(colors.muted); letterSpacing = .12f })
        addView(banner)
        status.setTextColor(colors.muted)
        status.accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
        addView(status)
        transcript.apply {
            minHeight = context.dp(56); maxLines = 3
            setPadding(context.dp(12), context.dp(8), context.dp(12), context.dp(8))
            background = GradientDrawable().apply { setColor(this@VoicePanel.colors.surface); cornerRadius = context.dp(16).toFloat() }
        }
        addView(transcript, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT))
        addView(FrameLayout(context).apply {
            addView(ring, FrameLayout.LayoutParams(LayoutParams.MATCH_PARENT, context.dp(88)))
            addView(mic, FrameLayout.LayoutParams(context.dp(232), context.dp(72), Gravity.CENTER))
        })
        addView(controls, LayoutParams(LayoutParams.MATCH_PARENT, context.dp(48)))
        addView(raw)
        addView(extras)
    }
    fun control(text: String, description: String, action: () -> Unit): MaterialButton = MaterialButton(context,
        null, com.google.android.material.R.attr.materialButtonOutlinedStyle).apply {
        this.text = text; contentDescription = description; minWidth = 0; minimumWidth = 0
        setPadding(0, 0, 0, 0); insetLeft = 0; insetRight = 0; accent(colors, filled = false)
        controls.addView(this, LayoutParams(0, context.dp(48), 1f))
        setOnClickListener { action() }
    }
    fun show(statusText: String, text: String, stable: String = "", active: Boolean = false, finalizing: Boolean = false) {
        status.text = statusText
        // The strip's state colours: listening tints accent, a failure or prompt tints error; idle and success stay plain.
        val (fill, ink) = when {
            active || finalizing -> colors.accentContainer to colors.onAccentContainer
            Cue.isError(statusText) || DictationAction.forStatus(statusText) != null -> colors.errorContainer to colors.onErrorContainer
            else -> null to colors.muted
        }
        status.setTextColor(ink)
        status.background = fill?.let { GradientDrawable().apply { setColor(it); cornerRadius = context.dp(12).toFloat() } }
        status.setPadding(context.dp(if (fill != null) 10 else 4), context.dp(5), context.dp(4), context.dp(5))
        val content = text.ifEmpty { "Tap to dictate · hold to talk" }
        transcript.text = SpannableString(content).apply {
            if (text.isNotEmpty()) {
                val boundary = if (text.startsWith(stable)) stable.length else 0
                if (boundary < length) setSpan(ForegroundColorSpan(colors.muted), boundary, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            }
        }
        mic.text = when { finalizing -> "Finishing…"; active -> "Stop"; else -> "Tap to dictate" }
        mic.setIconResource(if (active) R.drawable.ic_stop else R.drawable.ic_mic)
        mic.isEnabled = !finalizing
        mic.contentDescription = if (active) "Microphone: stop dictation" else "Microphone: tap to toggle, hold to talk"
        ring.listening = active && !finalizing
        if (!active) ring.level = 0.0
    }
    fun level(value: Double) { ring.level = value }
}

/** Only invalidates when a new audio level arrives; no animation or timer while idle. */
private class LevelRing(context: Context) : View(context) {
    private val accent = VoicePalette.of(context).accent
    private var animator: ValueAnimator? = null
    var listening = false
        set(value) {
            field = value
            if (!value) { animator?.cancel(); animator = null; level = 0.0 }
        }
    var level = 0.0
        set(value) {
            animator?.cancel()
            val target = value.coerceIn(0.0, 1.0)
            if (!listening || !isAttachedToWindow) { field = target; invalidate(); return }
            animator = ValueAnimator.ofFloat(field.toFloat(), target.toFloat()).apply {
                duration = 160
                addUpdateListener { field = (it.animatedValue as Float).toDouble(); invalidate() }
                start()
            }
        }
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; strokeWidth = context.dp(3).toFloat() }
    override fun onDetachedFromWindow() { animator?.cancel(); animator = null; super.onDetachedFromWindow() }
    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        paint.color = accent; paint.alpha = if (listening) 210 else 60
        val inset = context.dp(8).toFloat() - (max(0.0, level) * context.dp(5)).toFloat()
        canvas.drawRoundRect(width / 2f - context.dp(122) - level.toFloat() * context.dp(8), inset,
            width / 2f + context.dp(122) + level.toFloat() * context.dp(8), height - inset,
            context.dp(44).toFloat(), context.dp(44).toFloat(), paint)
    }
}
