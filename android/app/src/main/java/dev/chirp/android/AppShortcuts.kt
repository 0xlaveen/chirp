package dev.chirp.android

import android.content.ContextWrapper
import android.view.KeyEvent
import android.view.KeyboardShortcutGroup
import android.view.KeyboardShortcutInfo
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.platform.LocalContext

/** One table drives dispatch and Android's Meta+/ helper. Only mounted contexts publish actions. */
internal enum class AppCommand(val label: String, val key: Int, val modifiers: Int) {
    NewNote("New recording note", KeyEvent.KEYCODE_N, KeyEvent.META_CTRL_ON),
    Search("Search notes / history", KeyEvent.KEYCODE_F, KeyEvent.META_CTRL_ON),
    Record("Record / Stop note", KeyEvent.KEYCODE_R, KeyEvent.META_CTRL_ON or KeyEvent.META_SHIFT_ON),
    Pause("Pause / Resume note", KeyEvent.KEYCODE_P, KeyEvent.META_CTRL_ON or KeyEvent.META_SHIFT_ON),
    Edit("Edit / Done", KeyEvent.KEYCODE_E, KeyEvent.META_CTRL_ON),
    Dictate("Start / Stop dictation", KeyEvent.KEYCODE_ENTER, KeyEvent.META_CTRL_ON),
    Escape("Cancel / Close", KeyEvent.KEYCODE_ESCAPE, 0),
    Copy("Copy result", KeyEvent.KEYCODE_C, KeyEvent.META_CTRL_ON or KeyEvent.META_SHIFT_ON),
    Raw("Use raw", KeyEvent.KEYCODE_Z, KeyEvent.META_CTRL_ON or KeyEvent.META_SHIFT_ON),
    Notes("Notes tab", KeyEvent.KEYCODE_1, KeyEvent.META_CTRL_ON),
    History("History tab", KeyEvent.KEYCODE_2, KeyEvent.META_CTRL_ON),
    Settings("Settings tab", KeyEvent.KEYCODE_3, KeyEvent.META_CTRL_ON),
}

internal interface AppShortcutHost { val appShortcuts: AppShortcuts }

class AppShortcuts {
    private val contexts = linkedMapOf<Any, () -> Map<AppCommand, () -> Boolean>>()
    private val pressed = mutableSetOf<Int>()
    internal fun bind(owner: Any, actions: () -> Map<AppCommand, () -> Boolean>) { contexts[owner] = actions }
    fun unbind(owner: Any) { contexts.remove(owner) }
    fun dispatch(event: KeyEvent): Boolean {
        if (event.action == KeyEvent.ACTION_UP) return pressed.remove(event.keyCode)
        if (event.action != KeyEvent.ACTION_DOWN) return false
        val modifiers = KeyEvent.normalizeMetaState(event.metaState) and
            (KeyEvent.META_CTRL_ON or KeyEvent.META_SHIFT_ON or KeyEvent.META_ALT_ON or KeyEvent.META_META_ON)
        val command = AppCommand.entries.firstOrNull { it.key == event.keyCode && it.modifiers == modifiers } ?: return false
        if (event.repeatCount > 0) return event.keyCode in pressed
        for (actions in contexts.values.toList().asReversed()) {
            if (actions()[command]?.invoke() == true) { pressed.add(event.keyCode); return true }
        }
        return false
    }
    fun provide(groups: MutableList<KeyboardShortcutGroup>) {
        val available = contexts.values.flatMap { it().keys }.toSet()
        val items = AppCommand.entries.filter { it in available }.map { KeyboardShortcutInfo(it.label, it.key, it.modifiers) }
        if (items.isNotEmpty()) groups.add(KeyboardShortcutGroup("Chirp", items))
    }
}

internal val LocalAppShortcuts = androidx.compose.runtime.staticCompositionLocalOf<AppShortcuts?> { null }

@Composable
internal fun AppShortcutActions(vararg actions: Pair<AppCommand, () -> Boolean>) {
    var context = LocalContext.current
    while (context is ContextWrapper && context !is AppShortcutHost) context = context.baseContext
    val shortcuts = LocalAppShortcuts.current ?: (context as? AppShortcutHost)?.appShortcuts ?: return
    val current = rememberUpdatedState(actions.toMap())
    val owner = remember { Any() }
    DisposableEffect(shortcuts, owner) {
        shortcuts.bind(owner) { current.value }
        onDispose { shortcuts.unbind(owner) }
    }
}
