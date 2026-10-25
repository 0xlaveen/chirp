package dev.chirp.android.ui

import android.provider.Settings
import androidx.compose.foundation.Canvas
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import kotlin.math.max

/** Seconds per ring cycle at silence and at peak level (spec §C: 1.6 s → 0.6 s). */
internal const val RIPPLE_PERIOD_SILENCE = 1.6f
internal const val RIPPLE_PERIOD_PEAK = 0.6f

/** The Ripple's cycle length for an input level: linear from silence to peak, clamped. */
internal fun ripplePeriod(level: Float): Float =
    (RIPPLE_PERIOD_SILENCE - (RIPPLE_PERIOD_SILENCE - RIPPLE_PERIOD_PEAK) * level.coerceIn(0f, 1f))

/**
 * The Pond motif (spec §C): three concentric koi rings expanding out of the mic — *the* "Chirp is
 * listening" sign. Each ring scales 1 → 1.8 while its opacity goes 0.5 → 0, staggered by a third,
 * and the level-driven period shortens as speech peaks. With the system's animator duration scale
 * at 0 (and in tests) it draws one static ring whose stroke weight follows the level instead.
 */
@Composable
internal fun Ripple(
    level: Float,
    modifier: Modifier = Modifier,
    color: Color = LocalChirpRoles.current.koiDecor,
    animate: Boolean = animatorScale() > 0f,
) {
    if (animate) {
        var phase by remember { mutableFloatStateOf(0f) }
        LaunchedEffect(level) {
            var last = 0L
            while (true) {
                withFrameNanos { now ->
                    if (last != 0L) phase = (phase + (now - last) / (ripplePeriod(level) * 1_000_000_000f)) % 1f
                    last = now
                }
            }
        }
        Canvas(modifier) {
            val side = size.minDimension
            val base = side / 1.8f          // the outermost ring (scale 1.8) just fits
            val stroke = max(side / 12f, 1f)
            repeat(3) { index ->
                val p = (phase + index / 3f) % 1f
                drawCircle(
                    color = color.copy(alpha = 0.5f * (1f - p)),
                    radius = base / 2f * (1f + 0.8f * p),
                    center = Offset(size.width / 2f, size.height / 2f),
                    style = Stroke(stroke * (1f - 0.35f * p)),
                )
            }
        }
    } else {
        Canvas(modifier) {
            val side = size.minDimension
            val stroke = max(side / 14f, 1.2f) + side / 8f * level.coerceIn(0f, 1f)
            drawCircle(
                color = color,
                radius = side * 0.36f - stroke / 2f,
                center = Offset(size.width / 2f, size.height / 2f),
                style = Stroke(stroke),
            )
        }
    }
}

/** The system's animator duration scale: 0 means the user asked for no animation (or a test). */
@Composable
private fun animatorScale(): Float {
    val resolver = LocalContext.current.contentResolver
    return Settings.Global.getFloat(resolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f)
}
