package dev.chirp.android

import android.content.Context
import helium314.keyboard.latin.settings.Settings
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

@RunWith(RobolectricTestRunner::class)
class TypingDefaultsTest {
    @Test fun `voice-first install migrates to local learning and preserves later user choices`() {
        val prefs = RuntimeEnvironment.getApplication().getSharedPreferences("typing-migration", Context.MODE_PRIVATE)
        prefs.edit().putBoolean(Settings.PREF_KEY_USE_PERSONALIZED_DICTS, false).apply()
        seedTypingDefaults(prefs)
        assertTrue(prefs.getBoolean(Settings.PREF_KEY_USE_PERSONALIZED_DICTS, false))
        assertTrue(prefs.getBoolean(Settings.PREF_BIGRAM_PREDICTIONS, false))
        assertTrue(prefs.getBoolean(Settings.PREF_AUTO_CORRECTION, false))
        assertEquals(.24f, prefs.getFloat(Settings.PREF_AUTO_CORRECT_CONFIDENCE, 0f), 0f)
        assertTrue(prefs.getBoolean(Settings.PREF_ENABLE_SPLIT_KEYBOARD_LANDSCAPE, false))
        assertFalse(prefs.getBoolean(Settings.PREF_ENABLE_SPLIT_KEYBOARD_FOLDED_LANDSCAPE, true))
        assertTrue(prefs.getString(Settings.PREF_TOOLBAR_KEYS, "")!!.contains("ONE_HANDED:true"))
        prefs.edit().putBoolean(Settings.PREF_KEY_USE_PERSONALIZED_DICTS, false)
            .putBoolean(Settings.PREF_AUTO_CORRECTION, false).apply()
        seedTypingDefaults(prefs)
        assertFalse(prefs.getBoolean(Settings.PREF_KEY_USE_PERSONALIZED_DICTS, true))
        assertFalse(prefs.getBoolean(Settings.PREF_AUTO_CORRECTION, true))
    }
    @Test fun `existing explicit preferences survive migration`() {
        val prefs = RuntimeEnvironment.getApplication().getSharedPreferences("typing-existing", Context.MODE_PRIVATE)
        prefs.edit().putBoolean(Settings.PREF_AUTO_CORRECTION, false)
            .putBoolean(Settings.PREF_ENABLE_SPLIT_KEYBOARD_LANDSCAPE, false).apply()
        seedTypingDefaults(prefs)
        assertFalse(prefs.getBoolean(Settings.PREF_AUTO_CORRECTION, true))
        assertFalse(prefs.getBoolean(Settings.PREF_ENABLE_SPLIT_KEYBOARD_LANDSCAPE, true))
    }
}
