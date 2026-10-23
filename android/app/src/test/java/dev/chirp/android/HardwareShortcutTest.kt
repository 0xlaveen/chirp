package dev.chirp.android

import android.view.KeyEvent
import android.view.inputmethod.EditorInfo
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [31, 37])
class HardwareShortcutTest {
    private fun key(code: Int, meta: Int = 0, repeat: Int = 0) = KeyEvent(0, 0, KeyEvent.ACTION_DOWN, code, repeat, meta)
    private val chord = KeyEvent.META_CTRL_ON or KeyEvent.META_ALT_ON
    private fun action(event: KeyEvent, enabled: Boolean = true, listening: Boolean = false) =
        HardwareShortcut.action(event.keyCode, event, enabled, listening)

    @Test fun `Ctrl Alt Space toggles and exact modifiers are required`() {
        assertEquals(HardwareShortcut.Action.TOGGLE, action(key(KeyEvent.KEYCODE_SPACE, chord)))
        assertEquals(HardwareShortcut.Action.TOGGLE, action(key(KeyEvent.KEYCODE_SPACE, chord), listening = true))
        for (meta in listOf(0, KeyEvent.META_CTRL_ON, KeyEvent.META_ALT_ON, chord or KeyEvent.META_SHIFT_ON, chord or KeyEvent.META_META_ON))
            assertEquals("meta=$meta", HardwareShortcut.Action.NONE, action(key(KeyEvent.KEYCODE_SPACE, meta)))
        assertEquals(HardwareShortcut.Action.NONE, action(key(KeyEvent.KEYCODE_A, chord)))
    }
    @Test fun `key repeat does not toggle again`() {
        assertEquals(HardwareShortcut.Action.NONE, action(key(KeyEvent.KEYCODE_SPACE, chord, repeat = 1)))
    }
    @Test fun `Esc cancels only while listening and without modifiers`() {
        assertEquals(HardwareShortcut.Action.CANCEL, action(key(KeyEvent.KEYCODE_ESCAPE), listening = true))
        assertEquals(HardwareShortcut.Action.NONE, action(key(KeyEvent.KEYCODE_ESCAPE), listening = false))
        assertEquals(HardwareShortcut.Action.NONE, action(key(KeyEvent.KEYCODE_ESCAPE, KeyEvent.META_CTRL_ON), listening = true))
    }
    @Test fun `setting off disables both keys`() {
        assertEquals(HardwareShortcut.Action.NONE, action(key(KeyEvent.KEYCODE_SPACE, chord), enabled = false))
        assertEquals(HardwareShortcut.Action.NONE, action(key(KeyEvent.KEYCODE_ESCAPE), enabled = false, listening = true))
    }
    @Test fun `password editors are recognised`() {
        fun info(type: Int) = EditorInfo().apply { inputType = type }
        assertTrue(info(android.text.InputType.TYPE_CLASS_TEXT or android.text.InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD).isPasswordField())
        assertTrue(info(android.text.InputType.TYPE_CLASS_NUMBER or android.text.InputType.TYPE_NUMBER_VARIATION_PASSWORD).isPasswordField())
        assertFalse(info(android.text.InputType.TYPE_CLASS_TEXT).isPasswordField())
    }
}
