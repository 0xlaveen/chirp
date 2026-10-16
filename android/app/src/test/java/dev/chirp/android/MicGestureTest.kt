package dev.chirp.android

import dev.chirp.android.MicGesture.Action.*
import org.junit.Assert.*
import org.junit.Test

class MicGestureTest {
    @Test fun `short tap starts then second tap stops`() {
        val gesture = MicGesture()
        assertEquals(START, gesture.down(0, false)); assertEquals(NONE, gesture.up(299))
        assertEquals(NONE, gesture.down(500, true)); assertEquals(STOP, gesture.up(520))
    }
    @Test fun `hold boundary and release stops`() {
        val gesture = MicGesture()
        assertEquals(START, gesture.down(0, false)); assertEquals(STOP, gesture.up(300))
        assertEquals(START, gesture.down(1000, false)); assertEquals(STOP, gesture.up(2000))
    }
    @Test fun `cancel clears press and stray release does nothing`() {
        val gesture = MicGesture()
        assertEquals(NONE, gesture.cancel()); gesture.down(0, false)
        assertEquals(CANCEL, gesture.cancel()); assertEquals(NONE, gesture.up(1000))
    }
}
