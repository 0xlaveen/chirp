package dev.chirp.android

import android.content.SharedPreferences
import androidx.core.content.edit
import helium314.keyboard.latin.settings.Settings
import helium314.keyboard.latin.utils.ToolbarKey

/** One-time migration from the voice-first defaults. Later user choices are preserved. */
internal fun seedTypingDefaults(prefs: SharedPreferences) {
    if (prefs.getBoolean("chirp_typing_defaults_v2", false)) return
    prefs.edit {
        for (key in listOf(Settings.PREF_AUTO_CORRECTION, Settings.PREF_SHOW_SUGGESTIONS,
            Settings.PREF_BIGRAM_PREDICTIONS, Settings.PREF_AUTO_CAP, Settings.PREF_KEY_USE_DOUBLE_SPACE_PERIOD,
            Settings.PREF_POPUP_ON, Settings.PREF_SHOW_HINTS, Settings.PREF_SHOW_POPUP_HINTS,
            Settings.PREF_VIBRATE_ON, Settings.PREF_SUGGEST_EMOJIS, Settings.PREF_INLINE_EMOJI_SEARCH,
            Settings.PREF_AUTOCORRECT_SHORTCUTS, Settings.PREF_ENABLE_SPLIT_KEYBOARD_LANDSCAPE)) {
            if (!prefs.contains(key)) putBoolean(key, true)
        }
        if (!prefs.contains(Settings.PREF_ENABLE_SPLIT_KEYBOARD_FOLDED_LANDSCAPE))
            putBoolean(Settings.PREF_ENABLE_SPLIT_KEYBOARD_FOLDED_LANDSCAPE, false)
        if (!prefs.contains(Settings.PREF_AUTO_CORRECT_CONFIDENCE)) putFloat(Settings.PREF_AUTO_CORRECT_CONFIDENCE, .24f)
        // v1 explicitly disabled this for everyone. Enable local learning once on migration.
        putBoolean(Settings.PREF_KEY_USE_PERSONALIZED_DICTS, true)
        if (!prefs.contains(Settings.PREF_TOOLBAR_KEYS)) {
            val enabled = setOf(ToolbarKey.SETTINGS, ToolbarKey.CLIPBOARD, ToolbarKey.EMOJI,
                ToolbarKey.ONE_HANDED, ToolbarKey.SPLIT, ToolbarKey.UNDO, ToolbarKey.REDO,
                ToolbarKey.SELECT_WORD, ToolbarKey.COPY, ToolbarKey.PASTE, ToolbarKey.LEFT, ToolbarKey.RIGHT)
            putString(Settings.PREF_TOOLBAR_KEYS, ToolbarKey.entries.filter { it != ToolbarKey.CLOSE_HISTORY }
                .joinToString("|") { "${it.name}:${it in enabled}" })
        }
        putBoolean("chirp_typing_defaults_v2", true)
    }
}
