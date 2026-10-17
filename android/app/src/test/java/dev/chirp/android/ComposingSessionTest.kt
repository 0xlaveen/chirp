package dev.chirp.android

import android.view.inputmethod.InputConnection
import java.lang.reflect.Proxy
import org.junit.Assert.*
import org.junit.Test

class ComposingSessionTest {
    // A real interface fake: models a composing region and committed text without Android runtime.
    private class Editor {
        var committed = "prefix "
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
                    committed = region?.let { committed.replaceRange(it, args!![0].toString()) } ?: (committed + args!![0])
                    region = null; composing = ""
                }; available }
                "finishComposingText" -> { finishes++; committed += composing; composing = ""; region = null; true }
                "getTextBeforeCursor" -> committed.takeLast(args!![0] as Int)
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
}
