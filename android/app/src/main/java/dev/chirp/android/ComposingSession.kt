package dev.chirp.android

import android.view.inputmethod.InputConnection

/** Own only this utterance's composing span. Never keep editor text outside memory. */
class ComposingSession(private val connection: InputConnection) {
    private var live = true
    private var replacedSelection = connection.getSelectedText(0)?.toString().orEmpty()
    private var seq = -1L
    private var composing = false
    private var finalText: String? = null
    private var rawText: String? = null

    fun partial(event: ServerEvent.Partial): Boolean {
        if (!live || event.seq <= seq) return true
        seq = event.seq
        composing = true
        return connection.setComposingText(event.text, 1)
    }
    fun final(event: ServerEvent.Final): Boolean {
        if (!live) return false
        live = false
        val inserted = connection.commitText(event.text, 1)
        if (!inserted && composing) connection.setComposingText(replacedSelection, 1)
        connection.finishComposingText()
        replacedSelection = ""
        composing = false
        if (inserted && event.corrected && event.raw != event.text) {
            finalText = event.text
            rawText = event.raw
        }
        return inserted
    }
    fun cancel() {
        if (live && composing) {
            connection.setComposingText(replacedSelection, 1)
            connection.finishComposingText()
        }
        live = false
        replacedSelection = ""
        composing = false
        forgetUndo()
    }
    fun forgetUndo() { finalText = null; rawText = null }
    fun useRaw(cursor: Int): Boolean {
        val text = finalText ?: return false
        val raw = rawText ?: return false
        // Refuse if cursor/text changed after commit. The service also invalidates on selection changes.
        if (cursor < text.length || connection.getTextBeforeCursor(text.length, 0)?.toString() != text) {
            forgetUndo(); return false
        }
        connection.beginBatchEdit()
        return try {
            // Mark the verified final for a single replacement. Never delete it first:
            // a rejected commit must leave the corrected text in the editor.
            if (!connection.setComposingRegion(cursor - text.length, cursor)) return false
            connection.commitText(raw, 1).also { if (it) forgetUndo() }
        } finally { connection.finishComposingText(); connection.endBatchEdit() }
    }
}
