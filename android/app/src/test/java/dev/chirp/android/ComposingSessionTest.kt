package dev.chirp.android

import android.view.inputmethod.InputConnection
import java.lang.reflect.Proxy
import org.junit.Assert.*
import org.junit.Test

class ComposingSessionTest {
    // A real interface fake: models a composing region and committed text without Android runtime.
    private class Editor {
        var committed = "prefix "
        var cursor: Int? = null
        private fun insert(text: String) {
            val at = cursor ?: committed.length
            val range = region ?: (at until at)
            committed = committed.replaceRange(range, text)
            if (cursor != null) cursor = range.first + text.length
            region = null
        }
        var composing = ""
        var available = true
        var finishes = 0
        var selected = ""
        var region: IntRange? = null
        val connection = Proxy.newProxyInstance(InputConnection::class.java.classLoader,
            arrayOf(InputConnection::class.java)) { _, method, args ->
            when (method.name) {
                "getSelectedText" -> selected
                "setComposingText" -> { if (available) composing = args!![0].toString(); available }
                "setComposingRegion" -> { if (available) region = (args!![0] as Int) until (args[1] as Int); available }
                "commitText" -> { if (available) {
                    insert(args!![0].toString()); composing = ""
                }; available }
                "finishComposingText" -> { finishes++; if (composing.isNotEmpty()) insert(composing); composing = ""; region = null; true }
                "getTextBeforeCursor" -> committed.take(cursor ?: committed.length).takeLast(args!![0] as Int)
                "deleteSurroundingText" -> { committed = committed.dropLast(args!![0] as Int); true }
                "beginBatchEdit", "endBatchEdit" -> true
                else -> throw UnsupportedOperationException(method.name)
            }
        } as InputConnection
    }
    @Test fun `partials replace composition and final replaces rather than duplicates`() {
        val editor = Editor(); val session = ComposingSession(editor.connection)
        assertTrue(session.partial(ServerEvent.Partial(1, "syn", "")))
        session.partial(ServerEvent.Partial(2, "synthetic", "syn"))
        session.partial(ServerEvent.Partial(1, "stale", ""))
        assertEquals("prefix ", editor.committed); assertEquals("synthetic", editor.composing)
        assertTrue(session.final(ServerEvent.Final("Synthetic.", "synthetic", true)))
        assertEquals("prefix Synthetic.", editor.committed); assertEquals("", editor.composing)
        assertFalse(session.final(ServerEvent.Final("duplicate", "", false)))
    }
    @Test fun `cancel erases only composition and late results cannot insert`() {
        val editor = Editor(); val session = ComposingSession(editor.connection)
        session.partial(ServerEvent.Partial(0, "synthetic", "")); session.cancel()
        assertEquals("prefix ", editor.committed); assertEquals(1, editor.finishes)
        session.partial(ServerEvent.Partial(2, "late", ""))
        assertFalse(session.final(ServerEvent.Final("late", "late", false)))
        assertEquals("prefix ", editor.committed)
    }
    @Test fun `lost connection signals failure`() {
        val editor = Editor(); val session = ComposingSession(editor.connection); editor.available = false
        assertFalse(session.partial(ServerEvent.Partial(0, "synthetic", "")))
        assertFalse(session.final(ServerEvent.Final("synthetic", "synthetic", false)))
    }
    @Test fun `raw replacement is bounded and refuses changed cursor text`() {
        val editor = Editor(); val session = ComposingSession(editor.connection)
        session.final(ServerEvent.Final("Synthetic.", "synthetic", true))
        assertTrue(session.useRaw(editor.committed.length)); assertEquals("prefix synthetic", editor.committed)
        assertFalse(session.useRaw(editor.committed.length))
        val second = ComposingSession(editor.connection)
        second.final(ServerEvent.Final("Changed.", "changed", true)); editor.committed += " user edit"
        assertFalse(second.useRaw(editor.committed.length)); assertTrue(editor.committed.endsWith(" user edit"))
    }
    @Test fun `cancel restores selected text replaced by composition`() {
        val editor = Editor(); editor.selected = "original selection"
        val session = ComposingSession(editor.connection)
        session.partial(ServerEvent.Partial(1, "synthetic", "")); session.cancel()
        assertEquals("prefix original selection", editor.committed)
    }
    @Test fun `expiry forgets raw and cancellation before partial leaves selection alone`() {
        val editor = Editor(); val session = ComposingSession(editor.connection)
        session.cancel(); assertEquals(0, editor.finishes)
        val final = ComposingSession(editor.connection)
        final.final(ServerEvent.Final("Synthetic.", "synthetic", true)); final.forgetUndo()
        assertFalse(final.useRaw(editor.committed.length))
    }
    @Test fun `editor disconnect during raw region replacement cannot crash the IME`() {
        var disconnected = false
        var committed = ""
        val connection = Proxy.newProxyInstance(InputConnection::class.java.classLoader,
            arrayOf(InputConnection::class.java)) { _, method, args ->
            when (method.name) {
                "getSelectedText" -> ""
                "getTextBeforeCursor" -> committed.takeLast(args!![0] as Int)
                "commitText" -> { committed = args!![0].toString(); true }
                "setComposingRegion" -> { disconnected = true; throw IllegalStateException("synthetic private editor detail") }
                "finishComposingText", "endBatchEdit" -> {
                    if (disconnected) throw IllegalStateException("synthetic private editor detail") else true
                }
                else -> true
            }
        } as InputConnection
        val session = ComposingSession(connection)
        assertTrue(session.final(ServerEvent.Final("Synthetic.", "synthetic", true)))
        assertFalse(session.useRaw(committed.length))
        assertTrue(disconnected)
        session.cancel()
    }

    private fun assertBoundary(before: String, text: String, expected: String) {
        val editor = Editor().apply { committed = before }
        val session = ComposingSession(editor.connection)
        assertTrue(session.partial(ServerEvent.Partial(1, text, "")))
        assertEquals(expected, editor.composing)
        assertTrue(session.partial(ServerEvent.Partial(2, text, text)))
        assertEquals(expected, editor.composing)
        assertEquals(text.isNotBlank(), session.final(ServerEvent.Final(text, text, false)))
        assertEquals(before + expected, editor.committed)
        assertEquals(expected.length, session.committedLength)
        // Also cover a final without any composing partial.
        val direct = Editor().apply { committed = before }
        assertEquals(text.isNotBlank(), ComposingSession(direct.connection).final(ServerEvent.Final(text, text, false)))
        assertEquals(before + expected, direct.committed)
    }
    @Test fun `sentence punctuation and closing brackets receive one separator`() {
        for (before in listOf("Previous.", "Previous!", "Previous?", "Previous,", "Previous)", "Previous]", "Previous}")) {
            assertBoundary(before, "Next", " Next")
        }
    }
    @Test fun `letters and digits receive a separator`() {
        for (before in listOf("word", "42", "café")) assertBoundary(before, "Next", " Next")
    }
    @Test fun `empty fields and existing whitespace need no separator`() {
        for (before in listOf("", "word ", "word\t", "word\n", "word\r\n", "word\u00a0")) {
            assertBoundary(before, "Next", "Next")
        }
    }
    @Test fun `opening brackets and quotes need no separator`() {
        for (opening in listOf("(", "[", "{", "\"", "'", "“", "‘", "«", "‹", "（")) {
            assertBoundary("Previous $opening", "Next", "Next")
        }
    }
    @Test fun `leading whitespace in incoming text is preserved without doubling`() {
        for (text in listOf(" Next", "  Next", "\nNext", "\tNext")) assertBoundary("Previous.", text, text)
    }
    @Test fun `empty partial or final does not insert a separator alone`() {
        assertBoundary("Previous.", "", "")
    }
    @Test fun `mid-word cursor adds a separator after a letter and preserves the suffix`() {
        val editor = Editor().apply { committed = "beforeafter"; cursor = 6 }
        val session = ComposingSession(editor.connection)
        session.partial(ServerEvent.Partial(1, "new", ""))
        assertEquals(" new", editor.composing)
        assertTrue(session.final(ServerEvent.Final("New", "new", true)))
        assertEquals("before Newafter", editor.committed)
        assertTrue(session.useRaw(editor.cursor!!))
        assertEquals("before newafter", editor.committed)
    }
    @Test fun `cursor at start of a nonempty field receives no leading space`() {
        val editor = Editor().apply { committed = "suffix"; cursor = 0 }
        val session = ComposingSession(editor.connection)
        session.partial(ServerEvent.Partial(1, "new", ""))
        assertEquals("new", editor.composing)
        session.final(ServerEvent.Final("New", "new", false))
        assertEquals("Newsuffix", editor.committed)
    }
    @Test fun `cancel removes the added separator and raw replacement keeps it`() {
        val editor = Editor().apply { committed = "Previous." }
        val cancelled = ComposingSession(editor.connection)
        cancelled.partial(ServerEvent.Partial(1, "next", "")); cancelled.cancel()
        assertEquals("Previous.", editor.committed)
        val session = ComposingSession(editor.connection)
        session.partial(ServerEvent.Partial(1, " next", ""))
        session.final(ServerEvent.Final("Next.", " next", true))
        assertEquals("Previous. Next.", editor.committed)
        assertTrue(session.useRaw(editor.committed.length))
        assertEquals("Previous. next", editor.committed)
    }

    @Test fun `empty final preserves selection and performs no commit`() {
        var commits = 0
        val connection = Proxy.newProxyInstance(InputConnection::class.java.classLoader,
            arrayOf(InputConnection::class.java)) { _, method, _ ->
            when (method.name) {
                "getSelectedText" -> "selected fixture"
                "getTextBeforeCursor" -> "prefix"
                "commitText" -> { commits++; true }
                else -> true
            }
        } as InputConnection
        val session = ComposingSession(connection)
        assertFalse(session.final(ServerEvent.Final("", "", false)))
        assertEquals(0, commits); assertEquals(0, session.committedLength)
    }

}
