package dev.chirp.android

import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

internal enum class BubbleEdge { LEFT, RIGHT }

/** Where the user left the bubble on one screen posture: an edge and a fraction of the usable height. */
internal data class BubbleSpot(val edge: BubbleEdge, val yFraction: Float)

/** A screen rectangle in pixels; kept free of android.graphics so placement stays a pure function. */
internal data class Area(val left: Int, val top: Int, val right: Int, val bottom: Int) {
    val centerX get() = (left + right) / 2
    val centerY get() = (top + bottom) / 2
    val width get() = right - left
    val height get() = bottom - top
}

/**
 * Screen geometry for one placement, in pixels. [safeTop]/[safeBottom] exclude the status and navigation
 * bars; [imeTop] is the soft keyboard's top edge when the overlay can see it, else null (#167 IME spike).
 */
internal data class BubbleMetrics(
    val width: Int, val height: Int, val safeTop: Int, val safeBottom: Int,
    val size: Int, val gap: Int, val margin: Int, val imeTop: Int? = null,
)

internal data class BubbleAt(val x: Int, val y: Int, val edge: BubbleEdge)

/**
 * The floating mic's placement rules (#167): edge-docked, a remembered height per screen posture, never over
 * the focused field's text, and clear of the soft keyboard. The 56 dp touch box sits flush with the screen
 * edge so the 48 dp disc shows a 4 dp inset.
 */
internal object BubblePlacement {
    /** "cover"/"inner" by the smallest width (600 dp), then orientation: one saved spot each, so fold/unfold keep their own. */
    fun posture(widthPx: Int, heightPx: Int, density: Float): String =
        (if (min(widthPx, heightPx) / density >= 600f) "inner" else "cover") + "-" + (if (widthPx > heightPx) "landscape" else "portrait")

    fun nearestEdge(centerX: Int, width: Int) = if (centerX < width / 2) BubbleEdge.LEFT else BubbleEdge.RIGHT

    fun edgeX(edge: BubbleEdge, m: BubbleMetrics) = if (edge == BubbleEdge.LEFT) 0 else m.width - m.size

    private fun range(m: BubbleMetrics) = max(1, m.safeBottom - m.safeTop - m.size)

    /** The height to save on drop, as a fraction of the usable range so it survives a keyboard or a resize. */
    fun fraction(y: Int, m: BubbleMetrics): Float = ((y - m.safeTop).toFloat() / range(m)).coerceIn(0f, 1f)

    fun bubble(m: BubbleMetrics, field: Area?, spot: BubbleSpot?): BubbleAt {
        val edge = spot?.edge ?: BubbleEdge.RIGHT
        val x = edgeX(edge, m)
        val minY = m.safeTop + m.gap
        val maxY = max(minY, (m.imeTop ?: m.safeBottom) - m.size - m.gap)
        // Default: the right edge, just above the focused field's vertical centre.
        val wanted = spot?.let { m.safeTop + (it.yFraction * range(m)).roundToInt() }
            ?: field?.let { it.centerY - m.size } ?: (m.safeTop + m.safeBottom - m.size) / 2
        var y = wanted.coerceIn(minY, maxY)
        // No IME insets: a field in the lower half likely has the keyboard under it, so stay above the field.
        if (m.imeTop == null && field != null && field.centerY > m.height / 2) {
            val above = field.top - m.size - m.gap
            if (above >= minY) y = min(y, above)
        }
        return BubbleAt(x, clear(y, x, m, field, minY, maxY), edge)
    }

    /** Nudges the bubble vertically off the field's text: the nearer of just above or just below that fits. */
    private fun clear(y: Int, x: Int, m: BubbleMetrics, field: Area?, minY: Int, maxY: Int): Int {
        if (field == null || !overlaps(Area(x, y, x + m.size, y + m.size), field)) return y
        val above = field.top - m.size - m.gap
        val below = field.bottom + m.gap
        val options = listOf(above, below).filter { it in minY..maxY }
        return options.minByOrNull { kotlin.math.abs(it - y) } ?: y
    }

    fun overlaps(a: Area, b: Area) = a.left < b.right && b.left < a.right && a.top < b.bottom && b.top < a.bottom

    /**
     * The panel: anchored to the bubble's edge, at most [maxWidth] and [BubbleMetrics.margin] from the edges, above
     * the field when there is room, otherwise below it.
     */
    fun panel(m: BubbleMetrics, field: Area?, edge: BubbleEdge, bubbleY: Int, maxWidth: Int, height: Int): Area {
        val width = min(maxWidth, m.width - 2 * m.margin)
        val left = if (edge == BubbleEdge.LEFT) m.margin else m.width - width - m.margin
        val minY = m.safeTop + m.gap
        val maxY = max(minY, m.safeBottom - height - m.gap)
        val top = when {
            field == null -> bubbleY + m.size / 2 - height / 2
            field.top - height - m.gap >= minY -> field.top - height - m.gap
            field.bottom + m.gap <= maxY -> field.bottom + m.gap
            else -> maxY
        }.coerceIn(minY, maxY)
        return Area(left, top, left + width, top + height)
    }

    /** The drag's "Hide here" target at bottom centre. */
    fun hideTarget(m: BubbleMetrics, size: Int): Area {
        val left = (m.width - size) / 2
        val top = m.safeBottom - size - 3 * m.margin
        return Area(left, top, left + size, top + size)
    }

    fun overTarget(centerX: Int, centerY: Int, target: Area): Boolean =
        hypot((centerX - target.centerX).toFloat(), (centerY - target.centerY).toFloat()) <= target.width

    /** Where a drag puts the bubble: under the finger, kept on screen. */
    fun dragged(m: BubbleMetrics, x: Int, y: Int) = BubbleAt(x.coerceIn(0, m.width - m.size),
        y.coerceIn(m.safeTop, max(m.safeTop, m.safeBottom - m.size)), nearestEdge(x + m.size / 2, m.width))
}
