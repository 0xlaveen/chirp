package dev.chirp.android

/** Start on press for immediate feedback; short release toggles, long release stops. */
class MicGesture {
    enum class Action { START, STOP, CANCEL, NONE }
    private var pressedAt: Long? = null
    private var wasActive = false
    fun down(now: Long, active: Boolean): Action {
        pressedAt = now
        wasActive = active
        return if (active) Action.NONE else Action.START
    }
    fun up(now: Long): Action {
        val down = pressedAt ?: return Action.NONE
        pressedAt = null
        return if (wasActive || now - down >= 300) Action.STOP else Action.NONE
    }
    fun cancel(): Action {
        val hadPress = pressedAt != null
        pressedAt = null
        return if (hadPress) Action.CANCEL else Action.NONE
    }
}
