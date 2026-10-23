package dev.chirp.android

import android.text.InputType
import android.view.KeyEvent
import android.view.inputmethod.EditorInfo

/** Hardware-keyboard dictation keys: Ctrl+Alt+Space toggles (Ctrl+Space stays with language switching), Esc cancels while listening. */
internal object HardwareShortcut {
    enum class Action { TOGGLE, CANCEL, NONE }
    fun action(keyCode: Int, event: KeyEvent, enabled: Boolean, listening: Boolean): Action = when {
        !enabled || event.repeatCount > 0 -> Action.NONE
        keyCode == KeyEvent.KEYCODE_SPACE && event.isCtrlPressed && event.isAltPressed && !event.isShiftPressed && !event.isMetaPressed -> Action.TOGGLE
        keyCode == KeyEvent.KEYCODE_ESCAPE && listening && !event.isCtrlPressed &&
            !event.isAltPressed && !event.isShiftPressed && !event.isMetaPressed -> Action.CANCEL
        else -> Action.NONE
    }
}

internal fun EditorInfo.isPasswordField(): Boolean {
    val type = inputType and InputType.TYPE_MASK_CLASS
    val variation = inputType and InputType.TYPE_MASK_VARIATION
    return (type == InputType.TYPE_CLASS_TEXT && variation in setOf(InputType.TYPE_TEXT_VARIATION_PASSWORD,
        InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD, InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD)) ||
        (type == InputType.TYPE_CLASS_NUMBER && variation == InputType.TYPE_NUMBER_VARIATION_PASSWORD)
}
