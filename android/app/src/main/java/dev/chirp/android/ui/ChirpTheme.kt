package dev.chirp.android.ui

import android.content.Context
import android.content.SharedPreferences
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import dev.chirp.android.SettingsStore

/** Chirp's own green, used when "App colours" is Chirp green. */
internal val ChirpGreenDark = darkColorScheme(
    primary = Color(0xFF9FD3B9), onPrimary = Color(0xFF12382A),
    primaryContainer = Color(0xFF284E3E), onPrimaryContainer = Color(0xFFBCEFD3),
    secondary = Color(0xFFB5CCBE), onSecondary = Color(0xFF21352A),
    secondaryContainer = Color(0xFF344A3D), onSecondaryContainer = Color(0xFFD0E8D9),
    tertiary = Color(0xFFA6CCE0), onTertiary = Color(0xFF0B3443),
    tertiaryContainer = Color(0xFF254B5B), onTertiaryContainer = Color(0xFFC2E8FC),
    surface = Color(0xFF121715), onSurface = Color(0xFFE3EBE5),
    surfaceVariant = Color(0xFF34443B), onSurfaceVariant = Color(0xFFB5C8BC),
    surfaceContainer = Color(0xFF202A25), surfaceContainerHigh = Color(0xFF29382F),
    surfaceContainerHighest = Color(0xFF34443B), background = Color(0xFF121715),
    outline = Color(0xFF8B9F91), outlineVariant = Color(0xFF34443B),
)
internal val ChirpGreenLight = lightColorScheme(
    primary = Color(0xFF386A58), onPrimary = Color.White,
    primaryContainer = Color(0xFFBCEFD3), onPrimaryContainer = Color(0xFF12382A),
    secondary = Color(0xFF52645B), onSecondary = Color.White,
    secondaryContainer = Color(0xFFD5E8DC), onSecondaryContainer = Color(0xFF21352A),
    tertiary = Color(0xFF3E6374), onTertiary = Color.White,
    tertiaryContainer = Color(0xFFC2E8FC), onTertiaryContainer = Color(0xFF001F2A),
    surface = Color(0xFFF6FAF6), onSurface = Color(0xFF182D25),
    surfaceVariant = Color(0xFFE0EAE2), onSurfaceVariant = Color(0xFF43564A),
    surfaceContainer = Color(0xFFE6EFE8), surfaceContainerHigh = Color(0xFFDDE9DF),
    surfaceContainerHighest = Color(0xFFD5E3D8), background = Color(0xFFF6FAF6),
    outline = Color(0xFF6D8475), outlineVariant = Color(0xFFBFCFC3),
)

/** Shape and type tokens shared by every Chirp screen. */
internal object ChirpTokens {
    val shapes = Shapes(extraSmall = RoundedCornerShape(4.dp), small = RoundedCornerShape(8.dp),
        medium = RoundedCornerShape(12.dp), large = RoundedCornerShape(16.dp), extraLarge = RoundedCornerShape(28.dp))
    /** Outer corners of a [SettingsGroup]; rows inside keep [Shapes.extraSmall]. */
    val group = RoundedCornerShape(16.dp)
    val typography = Typography().run {
        copy(displaySmall = displaySmall.copy(fontWeight = FontWeight.Medium),
            titleMedium = titleMedium.copy(fontWeight = FontWeight.SemiBold))
    }
}

/** Wallpaper colours (minSdk 31, so always available) unless the user picked Chirp green. */
internal fun chirpColorScheme(context: Context, dark: Boolean, dynamic: Boolean = SettingsStore(context).dynamicColor): ColorScheme = when {
    dynamic && dark -> dynamicDarkColorScheme(context)
    dynamic -> dynamicLightColorScheme(context)
    dark -> ChirpGreenDark
    else -> ChirpGreenLight
}

@Composable
internal fun ChirpTheme(dark: Boolean = isSystemInDarkTheme(), dynamic: Boolean = rememberDynamicColor(), content: @Composable () -> Unit) {
    val context = LocalContext.current
    val colors = remember(context, dark, dynamic) { chirpColorScheme(context, dark, dynamic) }
    // MotionScheme.expressive() and MaterialExpressiveTheme are not public in material3 1.4.0 (BOM 2026.09.00); standard motion until they are.
    MaterialTheme(colorScheme = colors, shapes = ChirpTokens.shapes, typography = ChirpTokens.typography, content = content)
}

/** Follows the "App colours" choice live, so switching it restyles the open screen. */
@Composable
private fun rememberDynamicColor(): Boolean {
    val context = LocalContext.current
    val store = remember(context) { SettingsStore(context) }
    var dynamic by remember(store) { mutableStateOf(store.dynamicColor) }
    DisposableEffect(store) {
        val prefs = context.getSharedPreferences(SettingsStore.FILE, Context.MODE_PRIVATE)
        val listener = SharedPreferences.OnSharedPreferenceChangeListener { _, _ -> dynamic = store.dynamicColor }
        prefs.registerOnSharedPreferenceChangeListener(listener)
        onDispose { prefs.unregisterOnSharedPreferenceChangeListener(listener) }
    }
    return dynamic
}

@Composable
internal fun AppColoursSettings() {
    val context = LocalContext.current
    val store = remember { SettingsStore(context) }
    var dynamic by remember { mutableStateOf(store.dynamicColor) }
    SettingsGroup("App colours") {
        SettingsItem {
            ChoiceChips(listOf(true, false), dynamic, { if (it) "Match wallpaper" else "Chirp green" }) {
                dynamic = it; store.dynamicColor = it
            }
        }
    }
}
