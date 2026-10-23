package dev.chirp.android

import android.view.inputmethod.InputConnection

/** Reads [start, start + length) around the user's selection without moving it; null when the editor can't confirm it. */
internal fun InputConnection.textAt(start: Int, length: Int, selStart: Int, selEnd: Int): String? {
    val end = start + length
    if (start < 0 || length <= 0 || selStart < 0 || selEnd < selStart) return null
    fun before(count: Int) = if (count == 0) "" else getTextBeforeCursor(count, 0)?.toString()?.takeIf { it.length == count }
    fun after(count: Int) = if (count == 0) "" else getTextAfterCursor(count, 0)?.toString()?.takeIf { it.length == count }
    return when {
        selStart >= end -> before(selStart - start)?.take(length)
        selEnd <= start -> after(end - selEnd)?.drop(start - selEnd)
        selStart >= start && selEnd <= end -> {
            val selected = if (selEnd == selStart) "" else getSelectedText(0)?.toString()?.takeIf { it.length == selEnd - selStart } ?: return null
            (before(selStart - start) ?: return null) + selected + (after(end - selEnd) ?: return null)
        }
        else -> null
    }
}

/** Replaces [start, start + length) with text in one batch and puts the selection back where the user left it. */
internal fun InputConnection.replaceAt(start: Int, length: Int, text: CharSequence, selStart: Int, selEnd: Int): IntArray? {
    if (start < 0 || length <= 0) return null
    fun moved(position: Int) = when { position <= start -> position; position >= start + length -> position + text.length - length; else -> start + text.length }
    val selection = intArrayOf(moved(selStart), moved(selEnd))
    beginBatchEdit()
    try {
        if (!setComposingRegion(start, start + length) || !commitText(text, 1)) return null
        // commitText leaves the caret after the new text; only move it when the user's caret was elsewhere.
        if (selection[0] != start + text.length || selection[1] != selection[0]) setSelection(selection[0], selection[1])
        return selection
    } finally { finishComposingText(); endBatchEdit() }
}
