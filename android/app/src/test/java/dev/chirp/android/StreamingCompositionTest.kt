package dev.chirp.android

import android.os.Looper
import android.text.Editable
import android.text.Selection
import android.text.SpannableStringBuilder
import android.view.View
import android.view.inputmethod.BaseInputConnection
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import java.time.Duration

@RunWith(RobolectricTestRunner::class)
class StreamingCompositionTest {
    private class Editor : BaseInputConnection(View(RuntimeEnvironment.getApplication()), true) {
        val buffer = SpannableStringBuilder("prefix ").apply { Selection.setSelection(this, length) }
        val replacements = mutableListOf<String>()
        override fun getEditable(): Editable = buffer
        override fun setComposingText(text: CharSequence?, newCursorPosition: Int): Boolean {
            replacements += text.toString()
            return super.setComposingText(text, newCursorPosition)
        }
    }
    @Test fun `only changed suffix is replaced while prefix and stable text stay in place`() {
        val editor = Editor(); val session = ComposingSession(editor, 7)
        session.partial(ServerEvent.Partial(1, "hello wor", ""))
        session.partial(ServerEvent.Partial(2, "hello world", "hello "))
        assertEquals(listOf("hello wor", "ld"), editor.replacements)
        assertEquals("prefix hello world", editor.buffer.toString())
        assertEquals(13, BaseInputConnection.getComposingSpanStart(editor.buffer))
        session.partial(ServerEvent.Partial(3, "hello words", "hello "))
        assertEquals("ds", editor.replacements.last())
        assertEquals("prefix hello words", editor.buffer.toString())
        session.final(ServerEvent.Final("Hello words.", "hello words", true))
        assertEquals("prefix Hello words.", editor.buffer.toString())
        assertEquals(-1, BaseInputConnection.getComposingSpanStart(editor.buffer))
    }
    @Test fun `cancel restores all dictated text even after server commits stable prefix`() {
        val editor = Editor(); val session = ComposingSession(editor, 7)
        session.partial(ServerEvent.Partial(1, "hello world", "hello "))
        session.cancel()
        assertEquals("prefix ", editor.buffer.toString())
    }
    @Test fun `surrogate pairs are never split by suffix replacement`() {
        val editor = Editor(); val session = ComposingSession(editor, 7)
        session.partial(ServerEvent.Partial(1, "hello 🙂", ""))
        session.partial(ServerEvent.Partial(2, "hello 🙃", ""))
        assertEquals("🙃", editor.replacements.last())
        assertEquals("prefix hello 🙃", editor.buffer.toString())
    }
    @Test fun `frame bursts retain newest partial and cancel clears scheduled work`() {
        val applied = mutableListOf<Long>()
        val frames = PartialFrames({ applied += it.seq })
        repeat(100) { frames.offer(ServerEvent.Partial(it.toLong(), "synthetic", "")) }
        assertTrue(applied.isEmpty())
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(16))
        assertEquals(listOf(99L), applied)
        frames.offer(ServerEvent.Partial(100, "synthetic", "")); frames.clear()
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(16))
        assertEquals(listOf(99L), applied)
    }
}
