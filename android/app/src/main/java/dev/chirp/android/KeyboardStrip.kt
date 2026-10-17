package dev.chirp.android

import android.annotation.SuppressLint
import android.content.Context
import android.text.TextUtils
import android.view.Gravity
import android.view.View
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView
import com.google.android.material.button.MaterialButton

/** Compact native strip above the real HeliBoard keys. No transcript survives input finish. */
@SuppressLint("SetTextI18n")
internal class KeyboardStrip(context: Context) : LinearLayout(context) {
    val banner = context.label("").apply { visibility = GONE }
    val status = context.label("Tap mic · hold to talk", 12f).apply {
        accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
        setTextColor(VoicePalette.of(context).muted)
    }
    val partial = context.label("", 15f).apply { maxLines = 1; ellipsize = TextUtils.TruncateAt.END }
    val mic = MaterialButton(context).apply {
        text = ""; setIconResource(R.drawable.ic_mic); iconPadding = 0
        iconGravity = MaterialButton.ICON_GRAVITY_TEXT_START
        minWidth = 0; minimumWidth = 0; insetTop = 0; insetBottom = 0
        setPadding(0, 0, 0, 0)
        contentDescription = "Microphone: tap to toggle, hold to talk"
    }
    val cancel = MaterialButton(context, null, com.google.android.material.R.attr.materialButtonOutlinedStyle).apply {
        text = "✕"; contentDescription = "Cancel dictation"; minWidth = 0; minimumWidth = 0
        setPadding(0, 0, 0, 0)
    }
    val raw = MaterialButton(context, null, com.google.android.material.R.attr.materialButtonOutlinedStyle).apply {
        text = "Use raw"; visibility = GONE
    }
    private val meter = ProgressBar(context, null, android.R.attr.progressBarStyleHorizontal).apply {
        max = 100; contentDescription = "Microphone level"
    }
    init {
        orientation = VERTICAL; setPadding(context.dp(8), context.dp(2), context.dp(8), 0)
        setBackgroundColor(VoicePalette.of(context).background)
        addView(banner)
        addView(LinearLayout(context).apply {
            gravity = Gravity.CENTER_VERTICAL
            addView(mic, LayoutParams(context.dp(48), context.dp(48)))
            addView(LinearLayout(context).apply {
                orientation = VERTICAL; addView(status); addView(partial)
            }, LayoutParams(0, LayoutParams.WRAP_CONTENT, 1f))
            addView(raw, LayoutParams(LayoutParams.WRAP_CONTENT, context.dp(48)))
            addView(cancel, LayoutParams(context.dp(48), context.dp(48)))
        })
        addView(meter, LayoutParams(LayoutParams.MATCH_PARENT, context.dp(3)))
    }
    fun show(message: String, text: String, active: Boolean, finishing: Boolean, undo: Boolean, retention: Boolean) {
        status.text = message; partial.text = text
        partial.visibility = if (text.isEmpty()) GONE else VISIBLE
        mic.setIconResource(if (active) R.drawable.ic_stop else R.drawable.ic_mic)
        mic.isEnabled = !finishing
        mic.contentDescription = if (active) "Microphone: stop dictation" else "Microphone: tap to toggle, hold to talk"
        raw.visibility = if (undo) VISIBLE else GONE
        cancel.isEnabled = active || undo
        banner.retention(retention)
        if (!active || finishing) level(0.0)
    }
    fun level(value: Double) { meter.progress = (value.coerceIn(0.0, 1.0) * 100).toInt() }
}
