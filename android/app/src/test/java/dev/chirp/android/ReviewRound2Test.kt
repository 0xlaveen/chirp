package dev.chirp.android

import android.view.inputmethod.InputConnection
import java.lang.reflect.Proxy
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

class ReviewRound2Test {
    @Test fun `raw replacement failure preserves the corrected text`() {
        // Skip in normal runs; enable explicitly to demonstrate R2-07.
        assumeTrue("R2-07: destructive delete before a failed commit", System.getenv("CHIRP_REVIEW_REPRO") == "1")
        var text = ""
        var acceptCommit = true
        val connection = Proxy.newProxyInstance(InputConnection::class.java.classLoader,
            arrayOf(InputConnection::class.java)) { _, method, args ->
            when (method.name) {
                "getSelectedText" -> ""
                "commitText" -> { if (acceptCommit) text += args!![0].toString(); acceptCommit }
                "getTextBeforeCursor" -> text.takeLast(args!![0] as Int)
                "deleteSurroundingText" -> { text = text.dropLast(args!![0] as Int); true }
                "finishComposingText", "beginBatchEdit", "endBatchEdit" -> true
                else -> throw UnsupportedOperationException(method.name)
            }
        } as InputConnection
        val session = ComposingSession(connection)
        assertTrue(session.final(ServerEvent.Final("Synthetic.", "synthetic", true)))
        acceptCommit = false
        assertFalse(session.useRaw())
        assertEquals("Synthetic.", text)
    }
}
