package dev.chirp.android.shell

import androidx.activity.compose.BackHandler
import androidx.annotation.DrawableRes
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.adaptive.navigationsuite.NavigationSuiteScaffold
import androidx.compose.material3.adaptive.navigationsuite.NavigationSuiteType
import androidx.compose.runtime.Composable
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.dp
import dev.chirp.android.R

internal enum class ShellTab(val label: String, @DrawableRes val icon: Int) {
    Notes("Notes", R.drawable.ic_notes_tab), History("History", R.drawable.ic_history), Settings("Settings", R.drawable.ic_settings),
}

/** Narrower than this (the cover screen, a phone) a bottom navigation bar; from it (the Fold's inner screen, a tablet) a rail. */
internal val RAIL_WIDTH = 600.dp

/**
 * The app after onboarding: Notes · History · Settings, with edge-to-edge insets left to the scaffold. Back pops within a
 * tab first (each tab's own handler, composed after this one), then returns Notes, then leaves the app. [exitOnBack]: opened from
 * outside (the keyboard, a recovery link), so Back returns there instead of to Notes. Each tab keeps its saved state while hidden.
 */
@Composable
internal fun AppShell(tab: ShellTab, select: (ShellTab) -> Unit, exitOnBack: Boolean = false, content: @Composable (ShellTab) -> Unit) {
    BackHandler(enabled = tab != ShellTab.Notes && !exitOnBack) { select(ShellTab.Notes) }
    val saved = rememberSaveableStateHolder()
    BoxWithConstraints(Modifier.fillMaxSize()) {
        NavigationSuiteScaffold(navigationSuiteItems = {
            ShellTab.entries.forEach { item ->
                item(selected = item == tab, onClick = { select(item) }, icon = { Icon(painterResource(item.icon), null) }, label = { Text(item.label) })
            }
        }, layoutType = if (maxWidth >= RAIL_WIDTH) NavigationSuiteType.NavigationRail else NavigationSuiteType.NavigationBar) {
            saved.SaveableStateProvider(tab.name) { content(tab) }
        }
    }
}
