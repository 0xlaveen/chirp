package dev.chirp.android

import android.view.accessibility.AccessibilityNodeInfo
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [31, 37])
class FocusedInsertionTest {
    private class Editor {
        val node = AccessibilityNodeInfo().apply {
            isFocused = true; isEditable = true; isEnabled = true
            text = "before selected after"; setTextSelection(7, 15)
            addAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_SET_TEXT)
        }
        var accept = true
        var writes = 0
        init {
            shadowOf(node).setRefreshReturnValue(true)
            shadowOf(node).setOnPerformActionListener { action, arguments ->
                when (action) {
                    AccessibilityNodeInfo.ACTION_SET_TEXT -> {
                        writes++
                        if (accept) node.text = arguments.getCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE)
                        accept
                    }
                    AccessibilityNodeInfo.ACTION_SET_SELECTION -> {
                        node.setTextSelection(arguments.getInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT),
                            arguments.getInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT)); true
                    }
                    else -> false
                }
            }
        }
    }
    @Test fun `final replaces selected range preserving prefix suffix and raw replaces only inserted range`() {
        val editor = Editor(); val target = FocusedInsertion.from(editor.node)!!
        assertTrue(target.insert("Synthetic.")); assertEquals("before Synthetic. after", editor.node.text.toString())
        assertTrue(target.useRaw("synthetic")); assertEquals("before synthetic after", editor.node.text.toString())
        assertFalse(target.useRaw("late"))
    }
    @Test fun `changed field cursor or focus refuses writes`() {
        listOf<(AccessibilityNodeInfo) -> Unit>(
            { it.text = "user edit" }, { it.setTextSelection(0, 0) }, { it.isFocused = false }, { it.isPassword = true },
        ).forEach { change ->
            val editor = Editor(); val target = FocusedInsertion.from(editor.node)!!
            change(editor.node)
            assertFalse(target.insert("synthetic")); assertEquals(0, editor.writes)
        }
    }
    @Test fun `raw does not overwrite user edits and rejected replacement preserves final`() {
        val editor = Editor(); val target = FocusedInsertion.from(editor.node)!!
        assertTrue(target.insert("Synthetic."))
        editor.accept = false
        assertFalse(target.useRaw("synthetic")); assertEquals("before Synthetic. after", editor.node.text.toString())
        editor.accept = true; editor.node.text = "user edit"
        assertFalse(target.useRaw("synthetic")); assertEquals("user edit", editor.node.text.toString())
    }
    @Test fun `unsupported password unknown selection and oversized editors are refused`() {
        val editor = Editor()
        editor.node.isPassword = true; assertNull(FocusedInsertion.from(editor.node))
        editor.node.isPassword = false; editor.node.setTextSelection(-1, -1); assertNull(FocusedInsertion.from(editor.node))
        editor.node.text = "x".repeat(100001); editor.node.setTextSelection(0, 0); assertNull(FocusedInsertion.from(editor.node))
        assertNull(FocusedInsertion.from(null))
    }
    @Test fun `forget removes undo and final snapshot`() {
        val editor = Editor(); val target = FocusedInsertion.from(editor.node)!!
        target.insert("Synthetic."); target.forget()
        assertFalse(target.useRaw("synthetic")); assertFalse(target.matchesFinal())
    }
}
