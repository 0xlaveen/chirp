package dev.chirp.android

import android.os.Bundle
import android.view.accessibility.AccessibilityNodeInfo

/** A bounded snapshot of just the focused editor. No screen traversal, clipboard, logging or persistence. */
internal class FocusedInsertion private constructor(
    val node: AccessibilityNodeInfo,
    private var before: String,
    private var start: Int,
    private var end: Int,
) {
    private var after: String? = null
    private var inserted: String? = null
    fun unchanged(): Boolean = node.refresh() && node.isFocused && node.isEditable && node.isEnabled && !node.isPassword &&
        node.text?.toString().orEmpty() == before && node.textSelectionStart == start && node.textSelectionEnd == end

    fun insert(text: String): Boolean {
        if (!unchanged()) return false
        val low = minOf(start, end); val high = maxOf(start, end)
        val result = before.replaceRange(low, high, text)
        if (!setText(result)) return false
        after = result; inserted = text
        start = low; end = low + text.length
        select(end)
        // Once the insertion succeeds we only need the final field value to guard raw replacement.
        before = ""
        return true
    }
    fun useRaw(raw: String): Boolean {
        val expected = after ?: return false
        if (!node.refresh() || !node.isFocused || !node.isEditable || !node.isEnabled || node.isPassword || node.text?.toString() != expected ||
            node.textSelectionStart != end || node.textSelectionEnd != end) return false
        val text = inserted ?: return false
        if (expected.substring(start, end) != text) return false
        if (!setText(expected.replaceRange(start, end, raw))) return false
        select(start + raw.length)
        forget()
        return true
    }
    fun matchesFinal(): Boolean = after?.let {
        node.refresh() && node.isFocused && node.isEnabled && !node.isPassword && node.text?.toString() == it && node.textSelectionStart == end && node.textSelectionEnd == end
    } == true
    private fun setText(value: String): Boolean = node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, Bundle().apply {
        putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, value)
    })
    private fun select(cursor: Int) {
        node.performAction(AccessibilityNodeInfo.ACTION_SET_SELECTION, Bundle().apply {
            putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, cursor)
            putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, cursor)
        })
    }
    fun forget() { before = ""; after = null; inserted = null }
    companion object {
        fun from(node: AccessibilityNodeInfo?): FocusedInsertion? {
            if (node == null || !node.isFocused || !node.isEditable || node.isPassword || !node.isEnabled ||
                node.actionList.none { it.id == AccessibilityNodeInfo.ACTION_SET_TEXT }) return null
            val text = node.text?.toString().orEmpty()
            val start = node.textSelectionStart; val end = node.textSelectionEnd
            if (text.length > 100000 || start !in 0..text.length || end !in 0..text.length) return null
            return FocusedInsertion(node, text, start, end)
        }
    }
}
