package dev.chirp.android

import android.content.SharedPreferences
import androidx.core.content.edit
import helium314.keyboard.latin.settings.Settings
import helium314.keyboard.latin.utils.LayoutType

/** Keep function keys in the same places when a Fold crosses the tablet threshold. */
internal fun seedKeyboardLayoutDefaults(prefs: SharedPreferences) {
    if (prefs.getBoolean("chirp_functional_layout_v1", false)) return
    prefs.edit {
        val key = Settings.PREF_LAYOUT_PREFIX + LayoutType.FUNCTIONAL.name
        // Per-language layouts take precedence in HeliBoard's parser; leave those intact too.
        if (!prefs.contains(key)) putString(key, "functional_keys")
        putBoolean("chirp_functional_layout_v1", true)
    }
}
