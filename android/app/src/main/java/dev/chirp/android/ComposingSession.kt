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
    fun useRaw(): Boolean {
        val text = finalText ?: return false
        val raw = rawText ?: return false
        // Refuse if cursor/text changed after commit. The service also invalidates on selection changes.
        if (connection.getTextBeforeCursor(text.length, 0)?.toString() != text) {
            forgetUndo(); return false
        }
        connection.beginBatchEdit()
        return try {
            connection.deleteSurroundingText(text.length, 0) && connection.commitText(raw, 1)
        } finally { connection.endBatchEdit(); forgetUndo() }
    }
}
