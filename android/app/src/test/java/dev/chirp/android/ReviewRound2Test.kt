package dev.chirp.android

import android.view.inputmethod.InputConnection
import java.lang.reflect.Proxy
import org.junit.Assert.*
import org.junit.Test

/** R2-07: raw replacement must never delete a corrected final before a failed commit. */
class ReviewRound2Test {
    private class Editor {
        var text = ""
        var acceptCommit = true
        var acceptRegion = true
        var disconnectAfterRegion = false
        var region: IntRange? = null
        var batches = 0
        var commits = 0
        val connection = Proxy.newProxyInstance(InputConnection::class.java.classLoader,
            arrayOf(InputConnection::class.java)) { _, method, args ->
            when (method.name) {
                "getSelectedText" -> ""
                "commitText" -> {
                    commits++
                    if (acceptCommit) {
                        text = region?.let { text.replaceRange(it, args!![0].toString()) } ?: (text + args!![0])
                        region = null
                    }
                    acceptCommit
                }
                "getTextBeforeCursor" -> text.takeLast(args!![0] as Int)
                "setComposingRegion" -> {
                    if (acceptRegion) region = (args!![0] as Int) until (args[1] as Int)
                    if (disconnectAfterRegion) acceptCommit = false
                    acceptRegion
                }
                "finishComposingText" -> { region = null; true }
                "beginBatchEdit" -> { batches++; true }
                "endBatchEdit" -> { batches--; true }
                else -> throw UnsupportedOperationException(method.name)
            }
        } as InputConnection
        val session = ComposingSession(connection)
        init { assertTrue(session.final(ServerEvent.Final("Synthetic.", "synthetic", true))) }
    }
    @Test fun `raw replacement failure preserves the corrected text`() {
        val editor = Editor()
        editor.acceptCommit = false
        assertFalse(editor.session.useRaw(editor.text.length))
        assertEquals("Synthetic.", editor.text)
        assertNull(editor.region); assertEquals(0, editor.batches)
        editor.acceptCommit = true
        assertTrue(editor.session.useRaw(editor.text.length))
        assertEquals("synthetic", editor.text)
    }
    @Test fun `rejected composing region leaves final and does not attempt replacement`() {
        val editor = Editor()
        editor.acceptRegion = false
        assertFalse(editor.session.useRaw(editor.text.length))
        assertEquals("Synthetic.", editor.text); assertEquals(1, editor.commits)
        assertNull(editor.region); assertEquals(0, editor.batches)
    }
    @Test fun `connection lost between region and commit preserves the corrected text`() {
        val editor = Editor()
        editor.disconnectAfterRegion = true
        assertFalse(editor.session.useRaw(editor.text.length))
        assertEquals("Synthetic.", editor.text)
        assertNull(editor.region); assertEquals(0, editor.batches)
    }
}
