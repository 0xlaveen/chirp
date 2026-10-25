package dev.chirp.android

import kotlin.math.hypot

/**
 * The floating mic bubble's touch rules (#167), pure so the drag guarantee is testable: a drag never
 * opens the mic. Down then up within [hold] ms, moving less than [slop] px, is a tap; moving past [slop]
 * before [hold] ms is a drag; held still for [hold] ms is hold to talk, and movement after that is ignored.
 * The panel's own mic keeps [MicGesture].
 */
class BubbleGesture(private val slop: Float, private val hold: Long = HOLD_MS) {
    enum class Action { NONE, TAP, DRAG_START, DRAG, DROP, HOLD_START, HOLD_END, CANCEL }
    private enum class Phase { IDLE, PRESSED, DRAGGING, HOLDING }
    private var phase = Phase.IDLE
    private var downAt = 0L
    private var downX = 0f
    private var downY = 0f

    val dragging get() = phase == Phase.DRAGGING
    val holding get() = phase == Phase.HOLDING

    fun down(now: Long, x: Float, y: Float): Action {
        phase = Phase.PRESSED; downAt = now; downX = x; downY = y
        return Action.NONE
    }
    fun move(now: Long, x: Float, y: Float): Action = when (phase) {
        Phase.PRESSED -> when {
            hypot(x - downX, y - downY) > slop && now - downAt < hold -> { phase = Phase.DRAGGING; Action.DRAG_START }
            now - downAt >= hold -> { phase = Phase.HOLDING; Action.HOLD_START }
            else -> Action.NONE
        }
        Phase.DRAGGING -> Action.DRAG
        else -> Action.NONE
    }
    /** The hold timer: the host posts this [hold] ms after down; it starts talking only if the finger stayed put. */
    fun held(now: Long): Action =
        if (phase == Phase.PRESSED && now - downAt >= hold) { phase = Phase.HOLDING; Action.HOLD_START } else Action.NONE
    fun up(now: Long, x: Float, y: Float): Action {
        val was = phase
        phase = Phase.IDLE
        return when (was) {
            Phase.PRESSED -> if (hypot(x - downX, y - downY) > slop) Action.DROP else Action.TAP
            Phase.DRAGGING -> Action.DROP
            Phase.HOLDING -> Action.HOLD_END
            Phase.IDLE -> Action.NONE
        }
    }
    /** A cancelled stream cancels any utterance that started; a cancelled drag still snaps home. */
    fun cancel(): Action {
        val was = phase
        phase = Phase.IDLE
        return when (was) {
            Phase.HOLDING -> Action.CANCEL
            Phase.DRAGGING -> Action.DROP
            else -> Action.NONE
        }
    }
    companion object {
        const val HOLD_MS = 250L
        const val SLOP_DP = 8
    }
}
