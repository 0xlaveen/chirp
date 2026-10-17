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
    val status = context.label("Tap mic", 14f).apply {
        maxLines = 1; ellipsize = TextUtils.TruncateAt.END
        accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
    }
    val mic = control("Microphone: tap to dictate, long press for options").apply { setIconResource(R.drawable.ic_mic) }
    val cancel = control("Cancel dictation").apply { text = "✕" }
    val raw = control("Use raw dictation").apply { text = "Use raw"; visibility = GONE }
    private val meter = Waveform(context)
    private var suggestions: View? = null
    private var expanded = false
    init {
        gravity = Gravity.CENTER_VERTICAL
        setBackgroundColor(VoicePalette.of(context).background)
        addView(cancel, LayoutParams(context.dp(48), LayoutParams.MATCH_PARENT))
        addView(meter, LayoutParams(context.dp(32), LayoutParams.MATCH_PARENT))
        addView(status, LayoutParams(0, LayoutParams.MATCH_PARENT, 1f).apply { status.gravity = Gravity.CENTER_VERTICAL })
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
    fun show(message: String, @Suppress("UNUSED_PARAMETER") text: String, active: Boolean, finishing: Boolean, undo: Boolean, retention: Boolean) {
        val error = DictationAction.forStatus(message) != null
        val full = active || undo || error || retention
        if (expanded != full) {
            expanded = full
            (layoutParams as? RelativeLayout.LayoutParams)?.let { it.width = if (full) LayoutParams.MATCH_PARENT else context.dp(48); layoutParams = it }
            suggestions?.visibility = if (full) INVISIBLE else VISIBLE
            alpha = .6f; animate().alpha(1f).setDuration(160).start()
        }
        status.text = if (retention) "Debug retention on · $message" else DictationAction.forStatus(message)?.label ?: message
        status.visibility = if (full) VISIBLE else GONE
        status.setTextColor(if (retention) android.graphics.Color.WHITE else VoicePalette.of(context).ink)
        status.setBackgroundColor(if (retention) android.graphics.Color.rgb(164, 24, 24) else android.graphics.Color.TRANSPARENT)
        status.contentDescription = status.text
        cancel.visibility = if (full) VISIBLE else GONE
        cancel.isEnabled = active || undo || error
        meter.visibility = if (active && !finishing) VISIBLE else GONE
        raw.visibility = if (undo) VISIBLE else GONE
        mic.text = if (active) "✓" else ""
        if (active) mic.icon = null else mic.setIconResource(R.drawable.ic_mic)
        mic.isEnabled = !finishing
        mic.contentDescription = if (active) "Stop dictation" else "Microphone: tap to dictate, long press for options"
        if (!active || finishing) level(0.0)
    }
    fun level(value: Double) { meter.level = value.coerceIn(0.0, 1.0); meter.invalidate() }
}

private class Waveform(context: Context) : View(context) {
    var level = 0.0
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = VoicePalette.of(context).accent; strokeCap = Paint.Cap.ROUND }
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
