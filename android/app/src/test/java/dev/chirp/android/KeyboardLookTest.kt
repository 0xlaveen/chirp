package dev.chirp.android

import android.content.Context
import android.content.res.Configuration
import androidx.core.graphics.ColorUtils
import helium314.keyboard.keyboard.KeyboardTheme
import helium314.keyboard.latin.common.ColorType
import helium314.keyboard.latin.common.DynamicColors
import helium314.keyboard.latin.settings.Settings
import helium314.keyboard.latin.utils.DeviceProtectedUtils
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [37])
class KeyboardLookTest {
    private val app get() = RuntimeEnvironment.getApplication()
    private fun prefs(name: String) = app.getSharedPreferences(name, Context.MODE_PRIVATE).also { it.edit().clear().commit() }

    @Test fun `fresh install gets the Gboard-like look through HeliBoard theme preferences`() {
        val prefs = prefs("look-fresh")
        seedKeyboardLook(prefs)
        assertEquals(KeyboardLook.GBOARD, currentKeyboardLook(prefs))
        assertEquals(KeyboardTheme.STYLE_ROUNDED, prefs.getString(Settings.PREF_THEME_STYLE, null))
        assertTrue(prefs.getBoolean(Settings.PREF_THEME_KEY_BORDERS, false))
        assertEquals(KeyboardTheme.THEME_DYNAMIC, prefs.getString(Settings.PREF_THEME_COLORS, null))
        assertEquals(KeyboardTheme.THEME_DYNAMIC, prefs.getString(Settings.PREF_THEME_COLORS_NIGHT, null))
        assertTrue(prefs.getBoolean(Settings.PREF_THEME_DAY_NIGHT, false))
    }

    @Test fun `0_5_1 install that never picked a theme migrates once, later Appearance choices survive`() {
        val prefs = prefs("look-upgrade")
        prefs.edit().putBoolean("chirp_keyboard_defaults_v1", true).putBoolean("chirp_typing_defaults_v2", true)
            .putBoolean(Settings.PREF_THEME_DAY_NIGHT, true).commit()
        assertEquals("Untouched HeliBoard defaults are the classic look", KeyboardLook.HELIBOARD, currentKeyboardLook(prefs))
        seedKeyboardLook(prefs)
        assertEquals(KeyboardLook.GBOARD, currentKeyboardLook(prefs))
        prefs.edit().putString(Settings.PREF_THEME_COLORS, KeyboardTheme.THEME_DARKER).commit()
        seedKeyboardLook(prefs)
        assertEquals(KeyboardTheme.THEME_DARKER, prefs.getString(Settings.PREF_THEME_COLORS, null))
        assertNull("A custom Appearance choice is not reported as a preset", currentKeyboardLook(prefs))
    }

    @Test fun `explicitly chosen theme is never overridden by the migration`() {
        for (key in listOf(Settings.PREF_THEME_STYLE, Settings.PREF_THEME_COLORS, Settings.PREF_THEME_COLORS_NIGHT, Settings.PREF_THEME_KEY_BORDERS)) {
            val prefs = prefs("look-explicit-$key")
            prefs.edit().apply {
                if (key == Settings.PREF_THEME_KEY_BORDERS) putBoolean(key, false)
                else putString(key, if (key == Settings.PREF_THEME_STYLE) KeyboardTheme.STYLE_HOLO else KeyboardTheme.THEME_BLACK)
            }.commit()
            val before = prefs.all.filterKeys { !it.startsWith("chirp_") }
            seedKeyboardLook(prefs)
            assertEquals(key, before, prefs.all.filterKeys { !it.startsWith("chirp_") })
            assertTrue(prefs.getBoolean("chirp_keyboard_look_v1", false))
        }
    }

    @Test fun `every preset round trips through the chooser`() {
        val prefs = prefs("look-roundtrip")
        for (look in KeyboardLook.entries) {
            applyKeyboardLook(prefs, look)
            assertEquals(look, currentKeyboardLook(prefs))
        }
    }

    @Test fun `Samsung-like look resolves through HeliBoard's colour machinery in light and dark`() {
        val prefs = DeviceProtectedUtils.getSharedPreferences(app)
        applyKeyboardLook(prefs, KeyboardLook.SAMSUNG)
        assertEquals(helium314.keyboard.latin.R.style.KeyboardTheme_Rounded_Base_Border, KeyboardTheme.getKeyboardTheme(app).mStyleId)
        for ((night, expected) in listOf(false to SamsungColors.LIGHT, true to SamsungColors.DARK)) {
            RuntimeEnvironment.setQualifiers(if (night) "+night" else "+notnight")
            val colors = KeyboardTheme.getColorsForCurrentTheme(app)
            assertEquals(expected.background, colors.get(ColorType.MAIN_BACKGROUND))
            assertEquals(expected.keys, colors.get(ColorType.KEY_BACKGROUND))
            assertEquals(expected.functional, colors.get(ColorType.FUNCTIONAL_KEY_BACKGROUND))
            assertEquals(expected.accent, colors.get(ColorType.ACTION_KEY_BACKGROUND))
            assertEquals(expected.text, colors.get(ColorType.KEY_TEXT))
        }
        applyKeyboardLook(prefs, KeyboardLook.GBOARD)
        assertTrue(KeyboardTheme.getColorsForCurrentTheme(app) is DynamicColors)
        assertTrue(KeyboardTheme.getColorsForCurrentTheme(app).hasKeyBorders)
    }

    @Test fun `Chirp row colours stay readable on every preset in light and dark`() {
        for (night in listOf(false, true)) {
            val config = Configuration(app.resources.configuration).apply {
                uiMode = Configuration.UI_MODE_TYPE_NORMAL or (if (night) Configuration.UI_MODE_NIGHT_YES else Configuration.UI_MODE_NIGHT_NO)
            }
            val themed = app.createConfigurationContext(config)
            val dynamic = DynamicColors(themed, KeyboardTheme.STYLE_ROUNDED, true)
            val samsung = if (night) SamsungColors.DARK else SamsungColors.LIGHT
            val cases = listOf(
                Triple(dynamic.get(ColorType.STRIP_BACKGROUND), dynamic.get(ColorType.KEY_TEXT), dynamic.get(ColorType.ACTION_KEY_BACKGROUND)),
                Triple(samsung.background, samsung.text, samsung.accent),
                Triple(VoicePalette.of(themed).background, VoicePalette.of(themed).ink, VoicePalette.of(themed).accent))
            for ((background, ink, accent) in cases) {
                val strip = StripColors.derive(background, ink, ink, accent)
                val base = background or 0xFF000000.toInt()
                assertTrue("waveform/shimmer contrast", ColorUtils.calculateContrast(strip.highlight, base) >= 3.0)
                assertTrue("active mic icon contrast", ColorUtils.calculateContrast(strip.onAccent, strip.accent) >= 3.0)
                assertTrue("status text contrast", ColorUtils.calculateContrast(strip.ink, base) >= 4.5)
            }
        }
    }
}
