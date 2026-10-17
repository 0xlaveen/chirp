package dev.chirp.android

import android.view.inputmethod.InputConnection

/** Own only this utterance's composing span. Never keep editor text outside memory. */
class ComposingSession(private val connection: InputConnection) {
    private var live = true
    private var replacedSelection = editor("") { connection.getSelectedText(0)?.toString().orEmpty() }
    // Snapshot the boundary before any partial moves the cursor into our composing span.
    // Retain only the decision, not surrounding editor text.
    private val needsSpace = editor(false) {
        connection.getTextBeforeCursor(1, 0)?.lastOrNull()?.let { previous ->
            !previous.isWhitespace() && previous != '\'' && previous != '"' &&
                Character.getType(previous) != Character.START_PUNCTUATION.toInt() &&
                Character.getType(previous) != Character.INITIAL_QUOTE_PUNCTUATION.toInt()
        } ?: false
    }
    private var seq = -1L
    private var composing = false
    private var finalText: String? = null
    private var rawText: String? = null
    var committedLength = 0
        private set

    private fun atBoundary(text: String): String =
        if (needsSpace && text.isNotEmpty() && !text.first().isWhitespace()) " $text" else text

    fun partial(event: ServerEvent.Partial): Boolean {
        if (!live || event.seq <= seq) return true
        seq = event.seq
        return editor(false) { connection.setComposingText(atBoundary(event.text), 1) }.also { accepted ->
            if (accepted) composing = true
        }
    }
    fun final(event: ServerEvent.Final): Boolean {
        if (!live) return false
        live = false
        val text = atBoundary(event.text)
        val inserted = editor(false) { connection.commitText(text, 1) }
        if (inserted) committedLength = text.length
        if (!inserted && composing) editor(false) { connection.setComposingText(replacedSelection, 1) }
        editor(false) { connection.finishComposingText() }
        replacedSelection = ""
        composing = false
        if (inserted && event.corrected && event.raw != event.text) {
            finalText = text
            rawText = atBoundary(event.raw)
        }
        return inserted
    }
    fun cancel() {
        if (live && composing) {
            editor(false) { connection.setComposingText(replacedSelection, 1) }
            editor(false) { connection.finishComposingText() }
        }
        live = false
        replacedSelection = ""
        composing = false
        forgetUndo()
    }
    // An editor may disappear between verification, region marking and commit (IME switch,
    // app close or fold). No editor exception may escape onto the IME's main thread.
    private fun <T> editor(fallback: T, action: () -> T): T = try { action() } catch (_: RuntimeException) { fallback }

    fun forgetUndo() { finalText = null; rawText = null }
    fun useRaw(cursor: Int): Boolean {
        val text = finalText ?: return false
        val raw = rawText ?: return false
        // Refuse if cursor/text changed after commit. The service also invalidates on selection changes.
        if (cursor < text.length || editor<String?>(null) { connection.getTextBeforeCursor(text.length, 0)?.toString() } != text) {
            forgetUndo(); return false
        }
        editor(false) { connection.beginBatchEdit() }
        return try {
            // Mark the verified final for a single replacement. Never delete it first:
            // a rejected commit must leave the corrected text in the editor.
            if (!editor(false) { connection.setComposingRegion(cursor - text.length, cursor) }) return false
            editor(false) { connection.commitText(raw, 1) }.also {
                if (it) { committedLength = raw.length; forgetUndo() }
            }
        } finally { editor(false) { connection.finishComposingText() }; editor(false) { connection.endBatchEdit() } }
    }
}
