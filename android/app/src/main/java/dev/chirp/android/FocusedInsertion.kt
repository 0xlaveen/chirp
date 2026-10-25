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
        node.value() == before && node.selectionStart() == start && node.selectionEnd() == end

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
        if (!node.refresh() || !node.isFocused || !node.isEditable || !node.isEnabled || node.isPassword || node.value() != expected ||
            node.selectionStart() != end || node.selectionEnd() != end) return false
        val text = inserted ?: return false
        if (expected.substring(start, end) != text) return false
        if (!setText(expected.replaceRange(start, end, raw))) return false
        select(start + raw.length)
        forget()
        return true
    }
    fun matchesFinal(): Boolean = after?.let {
        node.refresh() && node.isFocused && node.isEnabled && !node.isPassword && node.value() == it && node.selectionStart() == end && node.selectionEnd() == end
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
    /** What the floating mic may do in a field: nothing (no bubble), write the final, or hand it over to copy. */
    enum class Eligibility { NONE, INSERT, COPY }
    companion object {
        /** Longer fields are never snapshotted; the bubble offers copy instead. */
        const val MAX_TEXT = 100000

        /**
         * Password and disabled fields get no bubble at all. A field that is editable but can't be written safely
         * (no ACTION_SET_TEXT, more than [MAX_TEXT] characters, or no usable selection) is copy mode.
         */
        fun eligibility(node: AccessibilityNodeInfo?): Eligibility {
            if (node == null || !node.refresh() || !node.isFocused || !node.isEditable || node.isPassword || !node.isEnabled) return Eligibility.NONE
            return if (from(node) == null) Eligibility.COPY else Eligibility.INSERT
        }
        fun from(node: AccessibilityNodeInfo?): FocusedInsertion? {
            // The service keeps the node from the last focus event; read the field as it is now, not as it was then.
            if (node == null || !node.refresh() || !node.isFocused || !node.isEditable || node.isPassword || !node.isEnabled ||
                node.actionList.none { it.id == AccessibilityNodeInfo.ACTION_SET_TEXT }) return null
            val text = node.value()
            val start = node.selectionStart(); val end = node.selectionEnd()
            if (text.length > MAX_TEXT || start !in 0..text.length || end !in 0..text.length) return null
            return FocusedInsertion(node, text, start, end)
        }
    }
}

/** The field's own value: an empty field reports its hint as text, and the hint is never part of what it holds. */
private fun AccessibilityNodeInfo.value(): String = if (isShowingHintText) "" else text?.toString().orEmpty()
/** An empty field can report no selection (-1); its caret can only be at 0. */
private fun AccessibilityNodeInfo.selectionStart(): Int = textSelectionStart.let { if (it < 0 && value().isEmpty()) 0 else it }
private fun AccessibilityNodeInfo.selectionEnd(): Int = textSelectionEnd.let { if (it < 0 && value().isEmpty()) 0 else it }
