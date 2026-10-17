package dev.chirp.android

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.text.TextUtils
import android.view.Gravity
import android.view.View
import android.widget.LinearLayout
import android.widget.RelativeLayout
import com.google.android.material.button.MaterialButton

/** Shares HeliBoard's suggestion row: idle mic at the end, status replaces suggestions. */
@SuppressLint("SetTextI18n")
internal class KeyboardStrip(context: Context) : LinearLayout(context) {
    private val palette = StripColors.of(context)
    val status = context.label("Tap mic", 14f).apply {
        maxLines = 1; ellipsize = TextUtils.TruncateAt.END
        accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
    }
    val mic = control("Microphone: tap to dictate, long press for options").apply { setIconResource(R.drawable.ic_mic) }
    val cancel = control("Cancel dictation").apply { text = "✕" }
    val raw = control("Use raw dictation").apply { text = "Use raw"; visibility = GONE
        accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE }
    val style = context.label("", 12f).apply {
        maxLines = 1; ellipsize = TextUtils.TruncateAt.END
        setPadding(context.dp(8), 0, context.dp(8), 0)
        background = android.graphics.drawable.GradientDrawable().apply {
            setColor(palette.chip)
            cornerRadius = context.dp(10).toFloat()
        }
    }
    private var pulse: android.animation.ValueAnimator? = null
    private var pulsingPolish = false
    private var stage = ""
    private val meter = Waveform(context).apply { color = palette.highlight }
    private var suggestions: View? = null
    private var expanded = false
    init {
        gravity = Gravity.CENTER_VERTICAL
        // Transparent: HeliBoard's own suggestion-row background (colour or image) shows through.
        setBackgroundColor(android.graphics.Color.TRANSPARENT)
        val clear = android.content.res.ColorStateList.valueOf(android.graphics.Color.TRANSPARENT)
        cancel.backgroundTintList = clear; cancel.setTextColor(palette.ink)
        raw.backgroundTintList = android.content.res.ColorStateList.valueOf(palette.chip); raw.setTextColor(palette.ink)
        this.style.setTextColor(palette.ink)
        for (button in listOf(mic, cancel, raw)) {
            button.cornerRadius = context.dp(20)
            button.rippleColor = android.content.res.ColorStateList.valueOf(palette.ink and 0x00ffffff or 0x22000000)
        }
        addView(cancel, LayoutParams(context.dp(48), LayoutParams.MATCH_PARENT))
        addView(meter, LayoutParams(context.dp(32), LayoutParams.MATCH_PARENT))
        addView(status, LayoutParams(0, LayoutParams.MATCH_PARENT, 1f).apply { status.gravity = Gravity.CENTER_VERTICAL })
        addView(style, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT))
        addView(raw, LayoutParams(context.dp(88), LayoutParams.MATCH_PARENT))
        addView(mic, LayoutParams(context.dp(48), LayoutParams.MATCH_PARENT))
        show("Tap mic", "", false, false, false, false)
    }
    private fun control(description: String) = MaterialButton(context).apply {
        text = ""; iconPadding = 0; iconGravity = MaterialButton.ICON_GRAVITY_TEXT_START
        minWidth = 0; minimumWidth = 0; minimumHeight = 0; minHeight = 0
        insetTop = 0; insetBottom = 0; setPadding(0, 0, 0, 0)
        contentDescription = description; isSaveEnabled = false
    }
    fun mount(parent: RelativeLayout) {
        suggestions = parent.findViewById(helium314.keyboard.latin.R.id.suggestions_strip_wrapper)
        (suggestions?.layoutParams as? RelativeLayout.LayoutParams)?.apply { marginEnd = context.dp(48) }
        parent.addView(this, RelativeLayout.LayoutParams(context.dp(48), LayoutParams.MATCH_PARENT).apply { addRule(RelativeLayout.ALIGN_PARENT_END) })
    }
    fun show(message: String, @Suppress("UNUSED_PARAMETER") text: String, active: Boolean, finishing: Boolean, undo: Boolean, retention: Boolean,
             polishing: Boolean = false, style: String = "", notice: Boolean = false) {
        val error = DictationAction.forStatus(message) != null
        val full = active || undo || error || retention || notice
        if (expanded != full) {
            expanded = full
            (layoutParams as? RelativeLayout.LayoutParams)?.let { it.width = if (full) LayoutParams.MATCH_PARENT else context.dp(48); layoutParams = it }
            suggestions?.visibility = if (full) INVISIBLE else VISIBLE
            if (motionAllowed()) { alpha = .6f; animate().alpha(1f).setDuration(160).start() }
        }
        val nextStage = when { polishing -> "polishing"; active && finishing -> "finishing"; active -> "listening"; undo -> "cleaned"; full -> "notice"; else -> "idle" }
        if (nextStage != stage) {
            status.animate().cancel()
            if (motionAllowed() && full) {
                status.alpha = .65f; status.translationY = context.dp(4).toFloat()
                status.animate().alpha(1f).translationY(0f).setDuration(180)
                    .setInterpolator(android.view.animation.PathInterpolator(.2f, 0f, 0f, 1f)).start()
            } else { status.alpha = 1f; status.translationY = 0f }
            stage = nextStage
        }
        status.text = if (retention) "Debug retention on · $message" else DictationAction.forStatus(message)?.label ?: message
        status.visibility = if (full) VISIBLE else GONE
        status.setTextColor(if (retention) android.graphics.Color.WHITE else palette.ink)
        status.setBackgroundColor(if (retention) android.graphics.Color.rgb(164, 24, 24) else android.graphics.Color.TRANSPARENT)
        status.contentDescription = status.text
        cancel.visibility = if (full) VISIBLE else GONE
        cancel.isEnabled = active || undo || error
        meter.visibility = if (active && !finishing) VISIBLE else GONE
        raw.visibility = if (undo) VISIBLE else GONE
        this.style.text = style
        this.style.contentDescription = "Clean-up style: $style"
        this.style.visibility = if (polishing) VISIBLE else GONE
        val animateState = active && (!finishing || polishing)
        if (pulse != null && pulsingPolish != polishing) { pulse?.cancel(); pulse = null; status.alpha = 1f; mic.alpha = 1f }
        if (animateState && motionAllowed() && pulse == null) {
            pulsingPolish = polishing
            pulse = android.animation.ValueAnimator.ofFloat(.55f, 1f).apply {
                duration = 1000; repeatCount = android.animation.ValueAnimator.INFINITE
                repeatMode = android.animation.ValueAnimator.REVERSE
                addUpdateListener {
                    val value = it.animatedValue as Float
                    if (pulsingPolish) {
                        val ink = palette.ink
                        val highlight = palette.highlight
                        val width = status.width.coerceAtLeast(1).toFloat()
                        status.paint.shader = android.graphics.LinearGradient(-width, 0f, width, 0f,
                            intArrayOf(ink, highlight, ink), floatArrayOf(0f, .5f, 1f), android.graphics.Shader.TileMode.CLAMP).apply {
                            setLocalMatrix(android.graphics.Matrix().apply { setTranslate((value - .55f) / .45f * width * 2, 0f) })
                        }
                        status.invalidate()
                    } else mic.alpha = .75f + value * .25f
                }; start()
            }
        } else if (!animateState || !motionAllowed()) { pulse?.cancel(); pulse = null; status.alpha = 1f; mic.alpha = 1f }
        if (!polishing || !motionAllowed()) { status.paint.shader = null; status.invalidate() }
        mic.text = if (polishing) "✦" else ""
        when {
            polishing -> mic.icon = null
            active -> mic.setIconResource(R.drawable.ic_stop)
            else -> mic.setIconResource(R.drawable.ic_mic)
        }
        mic.backgroundTintList = android.content.res.ColorStateList.valueOf(
            if (active) palette.accent else android.graphics.Color.TRANSPARENT)
        mic.iconTint = android.content.res.ColorStateList.valueOf(if (active) palette.onAccent else palette.ink)
        mic.setTextColor(if (active) palette.onAccent else palette.ink)
        mic.isEnabled = !finishing
        mic.contentDescription = if (polishing) "Polishing dictation" else if (active) "Stop dictation" else "Microphone: tap to dictate, long press for options"
        if (!active || finishing) level(0.0)
    }
    private fun motionAllowed() = android.animation.ValueAnimator.areAnimatorsEnabled() &&
        android.provider.Settings.Global.getFloat(context.contentResolver, android.provider.Settings.Global.ANIMATOR_DURATION_SCALE, 1f) > 0f
    override fun onDetachedFromWindow() {
        pulse?.cancel(); pulse = null; status.alpha = 1f; mic.alpha = 1f; status.paint.shader = null
        super.onDetachedFromWindow()
    }
    fun level(value: Double) { meter.level = value.coerceIn(0.0, 1.0); meter.invalidate() }
}

private class Waveform(context: Context) : View(context) {
    var level = 0.0
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { strokeCap = Paint.Cap.ROUND }
    var color: Int
        get() = paint.color
        set(value) { paint.color = value; invalidate() }
    init { contentDescription = "Microphone level"; importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO }
    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        paint.strokeWidth = context.dp(3).toFloat()
        repeat(5) { index ->
            val x = width * (index + 1) / 6f
            val amplitude = height * (.05 + level * .30 * (if (index % 2 == 0) .65 else 1.0)).toFloat()
            canvas.drawLine(x, height / 2f - amplitude, x, height / 2f + amplitude, paint)
        }
    }
}
