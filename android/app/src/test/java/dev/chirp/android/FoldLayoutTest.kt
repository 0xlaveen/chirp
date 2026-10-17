package dev.chirp.android

import android.view.inputmethod.InputMethodSubtype
import helium314.keyboard.keyboard.KeyboardSwitcher
import helium314.keyboard.keyboard.internal.keyboard_parser.floris.KeyCode
import helium314.keyboard.latin.RichInputMethodManager
import helium314.keyboard.latin.settings.Settings
import helium314.keyboard.latin.utils.DeviceProtectedUtils
import helium314.keyboard.latin.utils.LayoutType
import helium314.keyboard.latin.utils.SubtypeSettings
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(application = ChirpApplication::class, sdk = [37], shadows = [KeyboardInputMethods::class])
class FoldLayoutTest {
    @Test @Config(qualifiers = "sw599dp-w599dp-h900dp-port-mdpi")
    fun `cover below tablet threshold keeps phone layout`() = checkLayout(false)

    @Test @Config(qualifiers = "sw600dp-w600dp-h900dp-port-mdpi")
    fun `tablet threshold uses phone layout`() = checkLayout(true)

    @Test @Config(qualifiers = "sw749dp-w749dp-h832dp-port-mdpi")
    fun `representative Fold inner portrait uses phone layout`() = checkLayout(true)

    @Test @Config(qualifiers = "sw749dp-w832dp-h749dp-land-mdpi")
    fun `representative Fold inner landscape uses phone layout with split`() = checkLayout(true, split = true)

    @Test @Config(qualifiers = "sw767dp-w767dp-h900dp-port-mdpi")
    fun `upper small tablet boundary uses phone layout`() = checkLayout(true)

    @Test @Config(qualifiers = "sw768dp-w768dp-h900dp-port-mdpi")
    fun `large tablet resource boundary keeps phone layout`() = checkLayout(false)

    @Test @Config(qualifiers = "sw749dp-w749dp-h832dp-port-mdpi")
    fun `explicit global tablet layout retains tablet function keys and extras`() = checkLayout(true, tablet = true)

    @Test @Config(qualifiers = "sw749dp-w749dp-h832dp-port-mdpi")
    fun `per-language tablet layout overrides seeded global phone layout`() = checkLayout(true, tablet = true, perLanguage = true)

    private fun checkLayout(isTablet: Boolean, split: Boolean = false, tablet: Boolean = false, perLanguage: Boolean = false) {
        val app = RuntimeEnvironment.getApplication()
        val prefs = DeviceProtectedUtils.getSharedPreferences(app)
        // HeliBoard keeps its device-protected preferences and subtype in process statics.
        // Reset the migration input for each render, including after an explicit-layout case.
        prefs.edit().remove(Settings.PREF_LAYOUT_PREFIX + LayoutType.FUNCTIONAL.name)
            .remove("chirp_functional_layout_v1").commit()
        seedKeyboardLayoutDefaults(prefs)
        val subtype = InputMethodSubtype.InputMethodSubtypeBuilder().setSubtypeLocale("en_US")
            .setSubtypeMode("keyboard").setSubtypeExtraValue("KeyboardLayoutSet=MAIN:qwerty" +
                if (perLanguage) "|FUNCTIONAL:functional_keys_tablet" else "").build()
        RichInputMethodManager.forceSubtype(subtype)
        if (tablet) {
            if (perLanguage) {
                val subtype = "en-US§KeyboardLayoutSet=MAIN:qwerty|FUNCTIONAL:functional_keys_tablet"
                prefs.edit().putString(Settings.PREF_SELECTED_SUBTYPE, subtype)
                    .putString(Settings.PREF_ENABLED_SUBTYPES, subtype).commit()
                SubtypeSettings.init(app)
            } else prefs.edit().putString(Settings.PREF_LAYOUT_PREFIX + LayoutType.FUNCTIONAL.name, "functional_keys_tablet").commit()
        }
        val controller = Robolectric.buildService(KeyboardRenderTest.RenderIme::class.java).create()
        val ime = controller.get()
        try {
            val view = ime.onCreateInputView()
            ime.setInputView(view)
            ime.onStartInput(ime.info, false)
            ime.onStartInputView(ime.info, false)
            KeyboardSwitcher.getInstance().reloadMainKeyboard()
            assertEquals(isTablet, Settings.getInstance().isTablet)
            val keyboard = KeyboardSwitcher.getInstance().keyboard!!
            fun key(code: Int) = requireNotNull(keyboard.getKey(code)) { "Missing key $code" }
            val delete = key(KeyCode.DELETE)
            val enter = key('\n'.code)
            val z = key('z'.code)
            if (tablet) {
                assertTrue(delete.y < key('q'.code).y)
                assertEquals(key('a'.code).y, enter.y)
                assertNotNull(keyboard.getKey('!'.code))
            } else {
                assertEquals(z.y, delete.y)
                assertTrue(delete.x > key('m'.code).x)
                assertTrue(key(KeyCode.SHIFT).x < z.x)
                for (code in listOf(KeyCode.SYMBOL_ALPHA, ','.code, '.'.code, '\n'.code))
                    assertEquals(key(' '.code).y, key(code).y)
                assertTrue(enter.x > key('.'.code).x)
                assertNull("Phone rows must not grow tablet punctuation keys", keyboard.getKey('!'.code))
                assertEquals(split, keyboard.mId.isSplitLayout)
            }
        } finally {
            controller.destroy()
            prefs.edit().putString(Settings.PREF_LAYOUT_PREFIX + LayoutType.FUNCTIONAL.name, "functional_keys").commit()
            RichInputMethodManager.forceSubtype(InputMethodSubtype.InputMethodSubtypeBuilder()
                .setSubtypeLocale("en_US").setSubtypeMode("keyboard").build())
        }
    }
}
