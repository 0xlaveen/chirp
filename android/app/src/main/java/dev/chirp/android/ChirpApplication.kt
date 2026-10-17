package dev.chirp.android

import androidx.core.content.edit
import helium314.keyboard.latin.App
import helium314.keyboard.latin.settings.Settings
import helium314.keyboard.latin.utils.DeviceProtectedUtils

class ChirpApplication : App() {
    override fun onCreate() {
        CrashLog(this).install()
        if (BuildConfig.DEBUG) android.os.StrictMode.setThreadPolicy(
            android.os.StrictMode.ThreadPolicy.Builder().detectNetwork().penaltyDeath().build())
        // Seed once, before HeliBoard reads its defaults. Pairing stays in credential storage.
        val keyboard = DeviceProtectedUtils.getSharedPreferences(this)
        if (!keyboard.contains("chirp_keyboard_defaults_v1")) {
            val english = "en-US§KeyboardLayoutSet=MAIN:qwerty"
            keyboard.edit {
                putString(Settings.PREF_ENABLED_SUBTYPES, english)
                putString(Settings.PREF_SELECTED_SUBTYPE, english)
                putBoolean(Settings.PREF_THEME_DAY_NIGHT, true)
                putBoolean("chirp_keyboard_defaults_v1", true)
            }
        }
        seedTypingDefaults(keyboard)
        helium314.keyboard.settings.screens.ChirpSettingsHook.content = { ChirpSettingsSection() }
        super.onCreate()
    }
}
