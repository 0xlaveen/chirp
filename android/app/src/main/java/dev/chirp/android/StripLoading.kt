package dev.chirp.android

import android.animation.ValueAnimator
import android.content.res.ColorStateList
import android.graphics.Canvas
import android.graphics.ColorFilter
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PixelFormat
import android.graphics.drawable.Drawable
import android.view.animation.LinearInterpolator
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin

/**
 * A contained loading indicator in the Material 3 Expressive style: a rounded seven-lobed shape that turns and
 * breathes. Static (still drawn, nothing running) unless [running] is set, which the strip does only when animations are on.
 */
internal class LoadingDrawable(private val size: Int, color: Int) : Drawable() {
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { this.color = color }
    private val path = Path()
    private var animator: ValueAnimator? = null
    private var phase = 0f
    var color: Int
        get() = paint.color
        set(value) { paint.color = value; invalidateSelf() }
    var running: Boolean
        get() = animator != null
        set(value) {
            if (value == running) return
            if (!value) { animator?.cancel(); animator = null; phase = 0f; invalidateSelf(); return }
            animator = ValueAnimator.ofFloat(0f, 1f).apply {
                duration = 2400; repeatCount = ValueAnimator.INFINITE; interpolator = LinearInterpolator()
                addUpdateListener { phase = it.animatedValue as Float; invalidateSelf() }
                start()
            }
        }
    override fun getIntrinsicWidth() = size
    override fun getIntrinsicHeight() = size
    override fun draw(canvas: Canvas) {
        val r = minOf(bounds.width(), bounds.height()) / 2f * .86f
        val cx = bounds.exactCenterX(); val cy = bounds.exactCenterY()
        val turn = phase * 2 * PI.toFloat()
        val depth = .10f + .08f * sin(phase * 4 * PI.toFloat())
        path.rewind()
        val steps = 72
        for (i in 0..steps) {
            val angle = i * 2 * PI.toFloat() / steps
            val radius = r * (1f - depth + depth * cos(LOBES * angle + turn))
            val x = cx + radius * cos(angle + turn / 2); val y = cy + radius * sin(angle + turn / 2)
            if (i == 0) path.moveTo(x, y) else path.lineTo(x, y)
        }
        path.close()
        canvas.drawPath(path, paint)
    }
    override fun setAlpha(alpha: Int) { paint.alpha = alpha; invalidateSelf() }
    override fun setColorFilter(filter: ColorFilter?) { paint.colorFilter = filter; invalidateSelf() }
    override fun setTintList(tint: ColorStateList?) { tint?.let { color = it.getColorForState(state, it.defaultColor) } }
    @Deprecated("Deprecated in Java") override fun getOpacity() = PixelFormat.TRANSLUCENT
    private companion object { const val LOBES = 7 }
}
