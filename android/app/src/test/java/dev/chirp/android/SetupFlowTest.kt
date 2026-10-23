package dev.chirp.android

import org.junit.Assert.*
import org.junit.Test

class SetupFlowTest {
    @Test fun `onboarding chooses the first incomplete requirement for all combinations`() {
        for (enabled in listOf(false, true)) for (selected in listOf(false, true))
            for (mic in listOf(false, true)) for (paired in listOf(false, true)) {
                val expected = listOf(enabled && selected, mic, paired).indexOfFirst { !it }.let { if (it < 0) ONBOARDING_DONE else it + 1 }
                assertEquals(expected, setupStep(enabled, selected, mic, paired))
                val firstRun = !enabled && !selected && !mic && !paired
                assertEquals(if (firstRun) PAGE_WELCOME else expected, setupStep(enabled, selected, mic, paired, welcomed = false))
            }
    }
    @Test fun `the welcome page is skipped once paired or once the user is past it`() {
        assertEquals(PAGE_WELCOME, setupStep(false, false, false, false, welcomed = false))
        assertEquals(PAGE_KEYBOARD, setupStep(false, false, false, false, welcomed = true))
        assertEquals(PAGE_KEYBOARD, setupStep(false, false, false, true, welcomed = false))
        assertEquals(ONBOARDING_DONE, setupStep(true, true, true, true, welcomed = false))
    }
    @Test fun `each recoverable dictation error has a specific action`() {
        assertEquals(DictationAction.PAIR, DictationAction.forStatus("Pair your Mac in Chirp setup"))
        assertEquals(DictationAction.PAIR, DictationAction.forStatus("Pairing refused — pair again in Chirp setup"))
        assertEquals(DictationAction.MICROPHONE, DictationAction.forStatus("Allow microphone in Chirp setup"))
        assertEquals(DictationAction.NETWORK, DictationAction.forStatus("Mac unreachable — is Tailscale on?"))
        assertNull(DictationAction.forStatus("Listening…"))
        assertNull(DictationAction.forStatus("Inserted · tap mic to dictate again"))
    }
}
