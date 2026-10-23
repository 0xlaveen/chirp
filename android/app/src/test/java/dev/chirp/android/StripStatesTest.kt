package dev.chirp.android

import android.graphics.Color
import android.view.ContextThemeWrapper
import android.view.View
import android.view.ViewGroup
import android.widget.TextView
import androidx.core.graphics.ColorUtils
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [37])
class StripStatesTest {
    private val app get() = RuntimeEnvironment.getApplication()
    private fun strip(clock: () -> Long = { 0L }) = KeyboardStrip(ContextThemeWrapper(app, R.style.Theme_Chirp), clock)
    private fun noMotion() = android.provider.Settings.Global.putFloat(app.contentResolver, android.provider.Settings.Global.ANIMATOR_DURATION_SCALE, 0f)
    private fun descendants(root: View): List<View> = listOf(root) + if (root is ViewGroup) (0 until root.childCount).flatMap { descendants(root.getChildAt(it)) } else emptyList()

    // Backgrounds, inks and accents of the shipped looks in light and dark, plus pale and saturated extremes.
    private val looks = listOf(
        "gboard light" to Triple(0xFFF6FAF6.toInt(), 0xFF182D25.toInt(), 0xFF386A58.toInt()), "gboard dark" to Triple(0xFF121715.toInt(), 0xFFE3EBE5.toInt(), 0xFF9FD3B9.toInt()),
        "samsung light" to Triple(0xFFF1F1F4.toInt(), 0xFF1B1B1F.toInt(), 0xFF2F7CF6.toInt()), "samsung dark" to Triple(0xFF111113.toInt(), 0xFFF0F0F3.toInt(), 0xFF3E91FF.toInt()),
        "heliboard light" to Triple(0xFFECEFF1.toInt(), 0xFF000000.toInt(), 0xFF80CBC4.toInt()), "heliboard dark" to Triple(0xFF263238.toInt(), 0xFFFFFFFF.toInt(), 0xFF80CBC4.toInt()),
        "holo" to Triple(0xFF282828.toInt(), 0xFFFFFFFF.toInt(), 0xFFFFFFFF.toInt()),
        "pale accent on light" to Triple(0xFFFFFFFF.toInt(), 0xFF202020.toInt(), 0xFFFFF59D.toInt()), "dark accent on dark" to Triple(0xFF000000.toInt(), 0xFFEEEEEE.toInt(), 0xFF1A237E.toInt()),
    )

    @Test fun `status text reads on every state tint and the stop icon on its fill for every look and theme`() {
        for ((name, parts) in looks) {
            val (background, ink, accent) = parts
            val colors = StripColors.derive(background, ink, ink, accent)
            for (kind in StripKind.entries) {
                val tint = colors.tints.of(kind) ?: continue
                assertTrue("$name $kind text", ColorUtils.calculateContrast(tint.text, tint.fill) >= StripTints.TEXT)
                assertTrue("$name $kind accent graphics", ColorUtils.calculateContrast(tint.accent, tint.fill) >= StripTints.GRAPHIC)
            }
            for (tint in listOf(colors.tints.warning, colors.tints.solidError)) assertTrue("$name text on ${tint.fill}", ColorUtils.calculateContrast(tint.text, tint.fill) >= StripTints.TEXT)
            assertTrue("$name stop icon on its fill", ColorUtils.calculateContrast(colors.onAccent, colors.accent) >= StripTints.GRAPHIC)
            assertTrue("$name waveform on the row", ColorUtils.calculateContrast(colors.highlight, background or Color.BLACK) >= 3.0)
        }
    }

    @Test fun `palette containers follow the app colours and keep text readable`() {
        val colors = VoicePalette.of(app)
        for ((fill, text) in listOf(colors.accentContainer to colors.onAccentContainer, colors.secondaryContainer to colors.onSecondaryContainer, colors.errorContainer to colors.onErrorContainer)) {
            assertNotEquals(Color.TRANSPARENT, fill)
            assertTrue(ColorUtils.calculateContrast(text, fill) >= 4.5)
        }
    }

    @Test fun `the row tints while listening and returns to transparent, with the same height contract`() {
        noMotion()
        val strip = strip()
        assertEquals(0, Color.alpha(strip.tintColor))
        strip.show("Listening…", "", true, false, false, false)
        assertEquals(StripKind.LISTENING, strip.stripKind); assertNotEquals(0, Color.alpha(strip.tintColor))
        strip.show("Inserted · tap mic to dictate again", "", false, false, true, false, notice = true, undoable = true)
        assertEquals(StripKind.SUCCESS, strip.stripKind); assertEquals("Inserted", strip.status.text.toString())
        strip.show("Tap mic · hold to talk", "", false, false, false, false)
        assertEquals(StripKind.IDLE, strip.stripKind); assertEquals(0, Color.alpha(strip.tintColor))
        strip.show(DictationAction.TAILSCALE_OFF, "", false, false, false, false)
        assertEquals(StripKind.ERROR, strip.stripKind); assertEquals(View.VISIBLE, strip.action.visibility)
    }

    @Test fun `with animator scale zero no strip animator runs in any state`() {
        noMotion()
        val strip = strip()
        for (state in listOf("Connecting to Mac…" to false, "Listening…" to false, "Polishing…" to true)) {
            strip.show(state.first, "", true, state.second, false, false, polishing = state.second, style = "Email")
            assertFalse("${state.first} animating", strip.animating)
        }
        strip.show("Listening…", "", true, false, false, false)
        assertEquals("shape is applied instantly", app.dp(12), strip.mic.cornerRadius)
    }

    @Test fun `with animations on the morph runs once and settles on the tint`() {
        val strip = strip()
        strip.show("Listening…", "", true, false, false, false)
        assertTrue(strip.animating)
        strip.show("Listening…", "", true, false, false, false) // a partial re-render must not restart it
        shadowOf(android.os.Looper.getMainLooper()).idleFor(java.time.Duration.ofMillis(400))
        assertEquals(strip.stripKind, StripKind.LISTENING)
        assertEquals(app.dp(12), strip.mic.cornerRadius)
        val tint = StripColors.of(app).tints.listening.fill
        assertEquals(tint, strip.tintColor)
    }

    @Test fun `elapsed timer counts while listening and shows the segment`() {
        noMotion()
        var now = 0L
        val strip = strip { now }
        assertEquals(View.GONE, strip.timer.visibility)
        strip.show("Connecting to Mac…", "", true, false, false, false)
        assertEquals("no timer while connecting", View.GONE, strip.timer.visibility)
        strip.show("Listening…", "", true, false, false, false)
        assertEquals(View.VISIBLE, strip.timer.visibility); assertEquals("0:00", strip.timer.text.toString())
        now = 12_400
        shadowOf(android.os.Looper.getMainLooper()).idleFor(java.time.Duration.ofSeconds(1))
        assertEquals("0:12", strip.timer.text.toString()); assertEquals("12 seconds", strip.timer.contentDescription.toString())
        strip.nextSegment(); assertEquals("0:12 · #2", strip.timer.text.toString()); assertTrue(strip.timer.contentDescription.endsWith("part 2"))
        assertEquals(View.IMPORTANT_FOR_ACCESSIBILITY_NO, strip.timer.importantForAccessibility)
        strip.show("Tap mic · hold to talk", "", false, false, false, false)
        assertEquals(View.GONE, strip.timer.visibility)
        now = 99_000; strip.show("Listening…", "", true, false, false, false); assertEquals("0:00", strip.timer.text.toString())
    }

    @Test fun `near the limit the timer is a warning chip but the one live region is unchanged`() {
        noMotion()
        val strip = strip()
        strip.show("Listening… · 15 s left", "", true, false, false, false, countdown = true)
        assertNotNull(strip.timer.compoundDrawablesRelative[0])
        assertEquals(1, descendants(strip).count { it.accessibilityLiveRegion != View.ACCESSIBILITY_LIVE_REGION_NONE })
        strip.show("Listening…", "", true, false, false, false)
        assertEquals(0, descendants(strip).count { it.accessibilityLiveRegion != View.ACCESSIBILITY_LIVE_REGION_NONE })
        assertEquals("Listening…", strip.status.text.toString())
    }

    @Test fun `the final shows Undo then Use raw chips and no truncated hint`() {
        noMotion()
        val strip = strip()
        strip.show("cleaned", "", false, false, true, false, notice = true, undoable = true)
        assertEquals(View.VISIBLE, strip.raw.visibility); assertEquals(View.VISIBLE, strip.revert.visibility)
        assertTrue(strip.indexOfChild(strip.revert) < strip.indexOfChild(strip.raw))
        assertEquals("cleaned", strip.status.text.toString())
        assertEquals(StripKind.SUCCESS, strip.stripKind)
    }

    @Test fun `debug retention uses the palette error colours not a fixed red`() {
        noMotion()
        val strip = strip()
        strip.show("Listening…", "", true, false, false, true)
        val fill = (strip.status.background as android.graphics.drawable.ColorDrawable).color
        val error = StripColors.of(app).tints.solidError
        assertEquals(error.fill, fill); assertEquals(error.text, strip.status.currentTextColor)
        assertTrue(ColorUtils.calculateContrast(error.text, error.fill) >= 4.5)
    }

    @Test fun `the history toggle shows a tonal fill with a readable icon when open`() {
        val strip = strip()
        strip.historyOpen(true)
        val fill = strip.history.backgroundTintList!!.defaultColor
        assertNotEquals(Color.TRANSPARENT, fill)
        assertTrue(ColorUtils.calculateContrast(strip.history.iconTint.defaultColor, fill) >= 4.5)
        strip.historyOpen(false)
        assertEquals(Color.TRANSPARENT, strip.history.backgroundTintList!!.defaultColor)
    }

    @Test fun `the options menu exposes switch and radio roles with checked state and closes on a choice`() {
        val anchor = View(ContextThemeWrapper(app, R.style.Theme_Chirp))
        var cleanup = true; var picked = ""; var opened = false
        val menu = StripMenu(anchor).apply {
            toggle("Clean-up", "Correction on Mac", cleanup) { cleanup = it }
            section("Style")
            radio("Default", null, true) { picked = "default" }
            radio("Notes", "rewrites", false) { picked = "notes" }
            section("Chirp")
            item(R.drawable.ic_settings, "Chirp settings") { opened = true }
        }
        val rows = descendants(menu.content).filter { it.isClickable }
        assertEquals(4, rows.size)
        fun info(view: View) = android.view.accessibility.AccessibilityNodeInfo.obtain().also { view.onInitializeAccessibilityNodeInfo(it) }
        assertEquals("android.widget.Switch", info(rows[0]).className.toString()); assertTrue(info(rows[0]).isChecked)
        assertEquals("android.widget.RadioButton", info(rows[1]).className.toString()); assertTrue(info(rows[1]).isChecked)
        assertFalse(info(rows[2]).isChecked); assertEquals("Notes, rewrites", rows[2].contentDescription.toString())
        rows[0].performClick(); assertFalse(cleanup)
        assertFalse(info(rows[0]).isChecked)
        rows[2].performClick(); assertEquals("notes", picked)
        rows[3].performClick(); assertTrue(opened)
        assertTrue(descendants(menu.content).filterIsInstance<TextView>().any { it.text == "Style" && androidx.core.view.ViewCompat.isAccessibilityHeading(it) })
    }
}
