package dev.chirp.android

import dev.chirp.android.shell.*
import org.junit.Assert.*
import org.junit.Test

class SetupProgressTest {
    @Test fun `pair then microphone then chosen input and hide on completion`() {
        for (own in listOf(false, true)) for (paired in listOf(false, true)) for (mic in listOf(false, true))
            for (enabled in listOf(false, true)) for (selected in listOf(false, true)) for (floating in listOf(false, true)) {
                val input = if (own) floating else enabled && selected
                val actual = setupProgress(paired, mic, enabled, selected, floating, own)
                assertEquals(listOf(paired, mic, input).count { it }, actual.done)
                assertEquals(when { !paired -> SetupNeed.Pair; !mic -> SetupNeed.Microphone
                    !input -> if (own) SetupNeed.FloatingMic else SetupNeed.Keyboard; else -> null }, actual.missing)
            }
    }
    @Test fun `countdown rounds up and never becomes negative`() {
        assertEquals(5, actionSeconds(5000, 1)); assertEquals(4, actionSeconds(5000, 1000))
        assertEquals(1, actionSeconds(5000, 4999)); assertEquals(0, actionSeconds(5000, 5001))
    }
}
