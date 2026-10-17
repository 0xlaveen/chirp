package dev.chirp.android

import org.junit.Assert.*
import org.junit.Test

class SetupFlowTest {
    @Test fun `setup chooses first incomplete prerequisite for all combinations`() {
        for (enabled in listOf(false, true)) for (selected in listOf(false, true))
            for (mic in listOf(false, true)) for (paired in listOf(false, true)) {
                val step = setupStep(enabled, selected, mic, paired)
                assertEquals(listOf(enabled && selected, mic, paired).indexOfFirst { !it }.let { if (it < 0) 3 else it }, step)
            }
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
