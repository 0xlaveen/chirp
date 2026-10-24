package dev.chirp.android

import android.content.Context
import androidx.core.content.edit
import dev.chirp.android.ui.ChirpRoles
import dev.chirp.android.ui.PondDark
import dev.chirp.android.ui.PondLight
import dev.chirp.android.ui.chirpRoles
import androidx.compose.ui.graphics.toArgb
import dev.chirp.android.ui.ripplePeriod
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.RuntimeEnvironment
import kotlin.math.abs

/** The Pond tokens (spec §C), checked the WCAG way like the Mac suite's theme tests. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [37])
class ChirpThemeTest {
    private fun luminance(argb: Long): Double {
        fun lin(v: Double) = if (v <= 0.03928) v / 12.92 else Math.pow((v + 0.055) / 1.055, 2.4)
        val r = ((argb shr 16) and 0xFF) / 255.0
        val g = ((argb shr 8) and 0xFF) / 255.0
        val b = (argb and 0xFF) / 255.0
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    private fun contrast(a: Long, b: Long): Double {
        val (x, y) = luminance(a) to luminance(b)
        return (maxOf(x, y) + 0.05) / (minOf(x, y) + 0.05)
    }

    @Test fun `ink, inkMuted and koi text meet WCAG AA on background and surface in both modes`() {
        val surfaces = listOf(
            0xF6F7FAL to 0x0D1526L,  // background
            0xFFFFFFL to 0x121C30L,  // surface
        )
        val textTokens = listOf(
            0x1A2333L to 0xE8ECF3L,  // ink
            0x5B6577L to 0xA3ADBFL,  // inkMuted
            0xC2410CL to 0xFF8A4CL,  // koi
        )
        for ((lightSurface, darkSurface) in surfaces) {
            for ((lightText, darkText) in textTokens) {
                assertTrue("light $lightText on $lightSurface", contrast(lightText, lightSurface) >= 4.5)
                assertTrue("dark $darkText on $darkSurface", contrast(darkText, darkSurface) >= 4.5)
            }
        }
    }

    @Test fun `the Pond schemes carry the token values`() {
        // koi as primary, its fill pair, and the record dot as error — so the roles and the scheme agree.
        assertEquals(0xFFC2410C.toInt(), PondLight.primary.toArgb())
        assertEquals(0xFFFF8A4C.toInt(), PondDark.primary.toArgb())
        assertEquals(0xFFFFE4D4.toInt(), PondLight.primaryContainer.toArgb())
        assertEquals(0xFF7A2A08.toInt(), PondLight.onPrimaryContainer.toArgb())
        assertEquals(0xFF5C2207.toInt(), PondDark.primaryContainer.toArgb())
        assertEquals(0xFFFFD9C2.toInt(), PondDark.onPrimaryContainer.toArgb())
    }

    @Test fun `brand roles stay fixed per mode and match the Pond error role`() {
        assertEquals(ChirpRoles.Light, chirpRoles(night = false))
        assertEquals(ChirpRoles.Dark, chirpRoles(night = true))
        assertEquals(ChirpRoles.Light.record.toArgb(), PondLight.error.toArgb())
        assertEquals(ChirpRoles.Dark.record.toArgb(), PondDark.error.toArgb())
        assertEquals(0xFFF26A1B.toInt(), ChirpRoles.Light.koiDecor.toArgb())
        assertEquals(0xFF2F7A4F.toInt(), ChirpRoles.Light.lily.toArgb())
        assertEquals(0xFF8A5A00.toInt(), ChirpRoles.Light.moon.toArgb())
    }

    @Test fun `absent earlier choice starts on Pond, explicit choices are kept`() {
        val context = RuntimeEnvironment.getApplication()
        val prefs = context.getSharedPreferences(SettingsStore.FILE, Context.MODE_PRIVATE)
        val store = { SettingsStore(context) }
        prefs.edit { clear() }
        assertEquals(AppColour.POND, store().appColour)
        prefs.edit { clear().putBoolean("dynamic_color", true) }
        assertEquals("an explicit wallpaper choice is kept", AppColour.DYNAMIC, store().appColour)
        assertFalse("the pre-Pond key is migrated away", prefs.contains("dynamic_color"))
        prefs.edit { clear().putBoolean("dynamic_color", false) }
        assertEquals("an explicit Chirp-scheme choice becomes Pond", AppColour.POND, store().appColour)
        assertFalse(prefs.contains("dynamic_color"))
        prefs.edit { clear().putString("app_colours", "DYNAMIC") }
        assertEquals(AppColour.DYNAMIC, store().appColour)
    }

    @Test fun `ripple period shrinks from 1,6 s at silence to 0,6 s at peak`() {
        assertTrue(abs(ripplePeriod(0f) - 1.6f) < 1e-6)
        assertTrue(abs(ripplePeriod(1f) - 0.6f) < 1e-6)
        assertTrue(ripplePeriod(0.8f) < ripplePeriod(0.2f))
        assertTrue(abs(ripplePeriod(2f) - 0.6f) < 1e-6)
    }
}
