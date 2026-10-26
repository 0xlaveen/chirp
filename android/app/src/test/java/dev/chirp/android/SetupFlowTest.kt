package dev.chirp.android

import org.junit.Assert.*
import org.junit.Test

class SetupFlowTest {
    @Test fun `every requirement combination respects the chosen mode and skip`() {
        for (mode in InputMode.entries) for (enabled in listOf(false, true)) for (selected in listOf(false, true))
            for (mic in listOf(false, true)) for (paired in listOf(false, true)) for (bubble in listOf(false, true))
                for (skipped in listOf(false, true)) {
                    val ready = if (mode == InputMode.KEYBOARD) enabled && selected else bubble || skipped
                    val expected = when { !ready -> PAGE_KEYBOARD; !mic -> PAGE_MIC; !paired -> PAGE_PAIR; else -> ONBOARDING_DONE }
                    assertEquals(expected, setupStep(enabled, selected, mic, paired, mode = mode, bubbleEnabled = bubble, floatingMicSkipped = skipped))
                }
    }
    @Test fun `fresh installs start at welcome then require a choice`() {
        assertEquals(PAGE_WELCOME, setupStep(false, false, false, false, welcomed = false, mode = null))
        assertEquals(PAGE_CHOICE, setupStep(false, false, false, false, mode = null))
        assertEquals(PAGE_CHOICE, setupStep(false, false, true, true, mode = null))
    }
    @Test fun `every legacy keyboard and bubble combination migrates without changing its behaviour`() {
        for (enabled in listOf(false, true)) for (selected in listOf(false, true)) for (bubble in listOf(false, true)) {
            val expected = when { selected || (enabled && !bubble) -> InputMode.KEYBOARD; bubble -> InputMode.OWN_KEYBOARD; else -> null }
            assertEquals(expected, migratedInputMode(enabled, selected, bubble))
        }
    }
    @Test fun `each recoverable dictation error has a specific action`() {
        assertEquals(DictationAction.PAIR, DictationAction.forStatus("Pair your computer in Chirp settings"))
        assertEquals(DictationAction.PAIR, DictationAction.forStatus("Pairing refused — pair again in Chirp settings"))
        assertEquals(DictationAction.MICROPHONE, DictationAction.forStatus("Allow microphone in Chirp settings"))
        assertEquals(DictationAction.NETWORK, DictationAction.forStatus("Computer unreachable — is Tailscale on?"))
        assertNull(DictationAction.forStatus("Listening…"))
        assertNull(DictationAction.forStatus("Inserted · tap mic to dictate again"))
    }
}
