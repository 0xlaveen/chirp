package dev.chirp.android.shell

import androidx.activity.compose.BackHandler
import androidx.annotation.DrawableRes
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarDefaults
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationRailDefaults
import androidx.compose.material3.Surface
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.material3.Text
import androidx.compose.runtime.getValue
import androidx.compose.runtime.movableContentOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.graphics.Color
import androidx.compose.foundation.selection.selectable
import androidx.compose.ui.Alignment
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.Role
import androidx.compose.foundation.shape.CircleShape
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
        val rail = maxWidth >= RAIL_WIDTH
        // Movable: folding or resizing across RAIL_WIDTH swaps the bar for the rail without recomposing the open screen from scratch.
        val currentTab by rememberUpdatedState(tab)
        val currentContent by rememberUpdatedState(content)
        val page = remember { movableContentOf<Modifier> { modifier ->
            Box(modifier.background(MaterialTheme.colorScheme.background)) { saved.SaveableStateProvider(currentTab.name) { currentContent(currentTab) } }
        } }
        if (rail) Row(Modifier.fillMaxSize()) {
            // Not the stock NavigationRail: that one is a fixed 80 dp wide. This is as wide as its widest label, however large the font.
            Surface(Modifier.fillMaxHeight(), color = MaterialTheme.colorScheme.surface) {
                Column(Modifier.windowInsetsPadding(NavigationRailDefaults.windowInsets).padding(vertical = 4.dp).selectableGroup().widthIn(min = 80.dp),
                    horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    ShellTab.entries.forEach { item -> RailItem(item, item == tab) { select(item) } }
                }
            }
            page(Modifier.weight(1f).fillMaxHeight().consumeWindowInsets(WindowInsets.systemBars.union(WindowInsets.displayCutout).only(WindowInsetsSides.Start)))
        } else Column(Modifier.fillMaxSize()) {
            page(Modifier.weight(1f).fillMaxWidth().consumeWindowInsets(NavigationBarDefaults.windowInsets.only(WindowInsetsSides.Bottom)))
            NavigationBar {
                ShellTab.entries.forEach { item ->
                    NavigationBarItem(item == tab, { select(item) }, { Icon(painterResource(item.icon), null) }, label = { Text(item.label, maxLines = 1) })
                }
            }
        }
    }
}

/**
 * A rail destination that keeps its label whole on one line: the stock rail item is a fixed 80 dp wide, which squeezes
 * "Settings" to nothing at 200% font. This one is at least 80 dp and grows with its label (#182), so the rail widens instead.
 */
@Composable
private fun RailItem(tab: ShellTab, selected: Boolean, onClick: () -> Unit) {
    val colours = MaterialTheme.colorScheme
    Column(Modifier.widthIn(min = 80.dp).heightIn(min = 64.dp).padding(horizontal = 8.dp).selectable(selected, role = Role.Tab, onClick = onClick),
        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
        Box(Modifier.size(56.dp, 32.dp).clip(CircleShape).background(if (selected) colours.secondaryContainer else Color.Transparent), contentAlignment = Alignment.Center) {
            Icon(painterResource(tab.icon), null, tint = if (selected) colours.onSecondaryContainer else colours.onSurfaceVariant)
        }
        Text(tab.label, Modifier.padding(top = 4.dp), color = if (selected) colours.onSurface else colours.onSurfaceVariant,
            style = MaterialTheme.typography.labelMedium, maxLines = 1, softWrap = false)
    }
}
