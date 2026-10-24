package dev.chirp.android

import dev.chirp.android.BubbleGesture.Action
import org.junit.Assert.*
import org.junit.Test

class BubbleGestureTest {
    private val gesture = BubbleGesture(slop = 8f)

    @Test fun `quick still release is a tap`() {
        gesture.down(0, 10f, 10f)
        assertEquals(Action.NONE, gesture.move(100, 14f, 13f))
        assertEquals(Action.TAP, gesture.up(200, 14f, 13f))
    }
    @Test fun `moving past the slop before 250 ms is a drag that never starts talking`() {
        gesture.down(0, 10f, 10f)
        assertEquals(Action.DRAG_START, gesture.move(80, 30f, 10f))
        assertTrue(gesture.dragging)
        // The hold timer firing later, and long still moments, never turn a drag into talking.
        assertEquals(Action.NONE, gesture.held(400))
        assertEquals(Action.DRAG, gesture.move(900, 31f, 10f))
        assertEquals(Action.DROP, gesture.up(1200, 31f, 10f))
        assertEquals(Action.NONE, gesture.held(1300))
    }
    @Test fun `every drag path is free of start actions`() {
        for (end in listOf(60L, 249L, 2000L)) {
            val seen = mutableListOf(gesture.down(0, 0f, 0f), gesture.move(10, 20f, 0f), gesture.held(250), gesture.move(end, 200f, 300f), gesture.up(end + 1, 200f, 300f))
            assertFalse(seen.any { it == Action.HOLD_START || it == Action.TAP })
        }
    }
    @Test fun `holding still for 250 ms is hold to talk and movement after it is ignored`() {
        gesture.down(0, 10f, 10f)
        assertEquals(Action.NONE, gesture.held(249))
        assertEquals(Action.HOLD_START, gesture.held(250))
        assertEquals(Action.NONE, gesture.move(300, 200f, 200f))
        assertFalse(gesture.dragging)
        assertEquals(Action.HOLD_END, gesture.up(900, 200f, 200f))
    }
    @Test fun `a late move after 250 ms still starts the hold instead of a drag`() {
        gesture.down(0, 10f, 10f)
        assertEquals(Action.HOLD_START, gesture.move(260, 40f, 10f))
    }
    @Test fun `cancel cancels a started utterance and snaps a drag home`() {
        gesture.down(0, 0f, 0f); gesture.held(250)
        assertEquals(Action.CANCEL, gesture.cancel())
        gesture.down(0, 0f, 0f); gesture.move(10, 50f, 0f)
        assertEquals(Action.DROP, gesture.cancel())
        gesture.down(0, 0f, 0f)
        assertEquals(Action.NONE, gesture.cancel())
        assertEquals(Action.NONE, gesture.up(10, 0f, 0f))
    }
}
