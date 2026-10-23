package dev.chirp.android

import android.view.inputmethod.InputConnection

/** Own only this utterance's composing span. Never keep editor text outside memory. */
class ComposingSession(private val connection: InputConnection, private val anchor: Int = -1,
                       private val decorate: (String) -> CharSequence = { it }) {
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
    private var shaping = false
    private var midSentence = false
    private var commands = false
    private var seq = -1L
    private var composing = false
    private var rendered = ""
    private var regionOwned = false
    private var finalText: String? = null
    private var rawText: String? = null
    var committedLength = 0
        private set

    /** Opt this utterance's final into mid-sentence casing (and spoken commands). Call before the first partial. */
    fun shapeFinal(spokenCommands: Boolean) {
        shaping = true; commands = spokenCommands
        midSentence = editor(false) { FinalCasing.midSentence(connection.getTextBeforeCursor(FinalCasing.LOOKBEHIND, 0)) }
    }

    private fun atBoundary(text: String): String =
        if (needsSpace && text.isNotEmpty() && !text.first().isWhitespace()) " $text" else text

    fun partial(event: ServerEvent.Partial): Boolean {
        if (!live || event.seq <= seq) return true
        seq = event.seq
        val next = atBoundary(event.text)
        val stable = event.stable.takeIf { event.text.startsWith(it) }.orEmpty()
        val nextStable = if (stable.isEmpty()) 0 else atBoundary(stable).length
        val accepted = editor(false) {
            connection.beginBatchEdit()
            try {
                var common = rendered.commonPrefixWith(next).length
                // Never split a UTF-16 surrogate pair or detach a combining mark.
                if (common > 0 && (Character.isHighSurrogate(rendered[common - 1]) ||
                        (common < next.length && Character.getType(next[common]) == Character.NON_SPACING_MARK.toInt()))) common--
                val suffix = composing && anchor >= 0 && common > 0 &&
                    connection.getTextBeforeCursor(rendered.length, 0)?.toString() == rendered &&
                    connection.setComposingRegion(anchor + common, anchor + rendered.length)
                val inserted = if (next == rendered && composing) true
                    else connection.setComposingText(decorate(if (suffix) next.substring(common) else next), 1)
                if (inserted && anchor >= 0 && connection.getTextBeforeCursor(next.length, 0)?.toString() == next) {
                    // A reported stable prefix becomes normal editor text; only the tail composes.
                    // Re-mark the whole utterance on final/cancel so cleanup and rollback stay atomic.
                    regionOwned = connection.setComposingRegion(anchor + nextStable, anchor + next.length)
                }
                inserted
            } finally { connection.endBatchEdit() }
        }
        if (accepted) { composing = true; rendered = next }
        return accepted
    }
    private fun wholeRegion() {
        if (composing && regionOwned && anchor >= 0) editor(false) { connection.setComposingRegion(anchor, anchor + rendered.length) }
    }

    fun final(event: ServerEvent.Final): Boolean {
        if (!live) return false
        if (event.text.isBlank()) { cancel(); return false }
        live = false
        val text = atBoundary(if (shaping) FinalCasing.shape(event.text, midSentence, commands) else event.text)
        wholeRegion()
        val inserted = editor(false) { connection.commitText(text, 1) }
        if (inserted) committedLength = text.length
        if (!inserted && composing) editor(false) { connection.setComposingText(replacedSelection, 1) }
        editor(false) { connection.finishComposingText() }
        replacedSelection = ""
        composing = false; rendered = ""; regionOwned = false
        if (inserted && event.corrected && event.raw != event.text) {
            finalText = text
            rawText = atBoundary(event.raw)
        }
        return inserted
    }
    fun cancel() {
        if (live && composing) {
            wholeRegion()
            editor(false) { connection.setComposingText(replacedSelection, 1) }
            editor(false) { connection.finishComposingText() }
        }
        live = false
        replacedSelection = ""
        composing = false; rendered = ""; regionOwned = false
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
