package dev.chirp.android

import android.content.ComponentName
import android.content.Context
import android.provider.Settings
import android.view.inputmethod.InputMethodManager

enum class InputMode { KEYBOARD, OWN_KEYBOARD }

internal fun migratedInputMode(enabled: Boolean, selected: Boolean, bubbleEnabled: Boolean): InputMode? = when {
    selected || (enabled && !bubbleEnabled) -> InputMode.KEYBOARD
    bubbleEnabled -> InputMode.OWN_KEYBOARD
    else -> null
}

internal fun chirpKeyboardActive(context: Context): Boolean =
    ComponentName.unflattenFromString(Settings.Secure.getString(context.contentResolver, Settings.Secure.DEFAULT_INPUT_METHOD).orEmpty()) ==
        ComponentName(context, ChirpImeService::class.java)

/** Read the selected IME's public label only; no keyboard contents or learned words. */
internal fun currentKeyboardLabel(context: Context): String? {
    if (chirpKeyboardActive(context)) return null
    val selected = Settings.Secure.getString(context.contentResolver, Settings.Secure.DEFAULT_INPUT_METHOD)
    return context.getSystemService(InputMethodManager::class.java).inputMethodList.firstOrNull { it.id == selected }
        ?.loadLabel(context.packageManager)?.toString()?.takeIf { it.isNotBlank() }
}
