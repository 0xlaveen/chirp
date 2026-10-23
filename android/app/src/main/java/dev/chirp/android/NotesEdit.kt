package dev.chirp.android

import org.json.JSONObject

/**
 * `POST /v1/notes/edit`: one spoken instruction applied to part of the notes. Only `notes` and `instruction` go on the
 * wire; the scope `[start, end)`, the document and its `version` stay on the phone, so the answer applies only to the
 * text it was made from. Never logged.
 */
internal data class NotesEditRequest(val notes: String, val instruction: String, val start: Int = 0, val end: Int = 0,
    val version: Int = 0, val documentId: Long? = null) {
    fun json(): String = JSONObject().put("notes", notes).put("instruction", instruction).toString()
}

/**
 * `edited:false` fails closed (no Markdown). `error:"refused"` means the instruction asks for something an edit may not do
 * (`reason`: `adds_content`, `unclear`, `not_an_edit`); `changed:false` means nothing to apply; `error:"preempted"` means a
 * segment clean-up took the model first (it did not run).
 */
internal data class NotesEditResponse(val markdown: String?, val edited: Boolean, val changed: Boolean = true,
    val error: String? = null, val reason: String? = null) {
    val failureLabel get() = NotesFailure.label(error, reason)
    val preempted get() = !edited && error == "preempted"
    /** The refusal reason (a code, never text), when the server refused the instruction. */
    val refusal get() = if (!edited && error == "refused") NotesFailure.guardName(reason) ?: "unclear" else null
    companion object {
        fun failed(code: String) = NotesEditResponse(null, false, false, code)
        fun decode(body: String) = JSONObject(body).let {
            val markdown = it.optString("markdown").takeIf { _ -> it.has("markdown") && !it.isNull("markdown") }
            NotesEditResponse(markdown, markdown != null && it.optBoolean("edited"), markdown != null && it.optBoolean("changed"),
                it.text("error"), it.text("reason"))
        }
    }
}

/** How one voice edit ended. */
internal sealed interface NotesEditOutcome {
    data object Applied : NotesEditOutcome
    /** The model found nothing to change. */
    data object Unchanged : NotesEditOutcome
    /** The server refused the instruction (`adds_content`, `unclear`, `not_an_edit`). */
    data class Refused(val reason: String) : NotesEditOutcome
    /** The notes changed while it ran (typing, a composition): nothing was applied. */
    data object Conflict : NotesEditOutcome
    /** Nothing to edit: no notes, nothing heard, or a selection over the limit (`empty`, `not_heard`, `too_long`). */
    data class Skipped(val why: String) : NotesEditOutcome
    /** The call failed or the guards rejected the answer (`rejected: dropped_line`, `timeout`, `busy`…). */
    data class Failed(val code: String) : NotesEditOutcome
}

/** What a voice edit may change: `[start, end)` of the notes, or why there is none (`empty`, `too_long`). */
internal sealed interface NotesEditScope {
    data class Range(val start: Int, val end: Int) : NotesEditScope
    data class None(val why: String) : NotesEditScope
}

/**
 * What an instruction may edit: the selected lines, else the whole notes, else (past the reorganize limit) the trailing
 * whole sections that fit. [selection] is `[start, end)` in the text.
 */
internal fun NotesDocument.editScope(selection: Pair<Int, Int>?): NotesEditScope {
    if (text.isBlank()) return NotesEditScope.None("empty")
    if (selection != null && selection.second > selection.first && selection.second <= text.length) {
        val start = text.lastIndexOf('\n', selection.first - 1) + 1
        val end = text.indexOf('\n', selection.second - 1).let { if (it < 0) text.length else it + 1 }
        val lines = text.substring(start, end)
        return when {
            lines.isBlank() -> NotesEditScope.None("empty")
            lines.scalars <= NotesDocument.MAX_REORGANIZE_CHARS -> NotesEditScope.Range(start, end)
            else -> NotesEditScope.None("too_long")
        }
    }
    if (text.scalars <= NotesDocument.MAX_REORGANIZE_CHARS) return NotesEditScope.Range(0, text.length)
    return reorganizeScope()?.first?.let { NotesEditScope.Range(it.first, it.last + 1) } ?: NotesEditScope.None("too_long")
}

/** The request for [instruction] over `[start, end)`, without the blank lines that frame it. */
internal fun NotesDocument.editRequest(instruction: String, start: Int, end: Int) =
    NotesEditRequest(text.substring(start, end).trim(), instruction, start, end, version, id)

/** The request still describes this text: same document, and no change to the notes since (any edit anywhere counts). */
internal fun NotesDocument.canApplyEdit(request: NotesEditRequest) = request.documentId == id && request.version == version && request.end <= text.length

/**
 * Applies an edit answer as one change, only when the notes are exactly what the request was made from. It is the user's
 * instruction, so it goes in as the user's edit: one that touches the AI tail makes the tail theirs, and the next
 * structuring answer starts a new one. Null when there is nothing to apply.
 */
internal fun NotesDocument.applyEdit(response: NotesEditResponse, request: NotesEditRequest): NotesChange? {
    if (!canApplyEdit(request) || !response.edited || !response.changed) return null
    val md = response.markdown?.trim()?.takeIf { it.isNotEmpty() } ?: return null
    val old = text.substring(request.start, request.end)
    // Keep the blank lines that frame the scope, then replace only what the answer changed.
    val edited = old.takeWhile { it == '\n' || it == '\r' } + md + old.takeLastWhile { it.isWhitespace() }
    val change = NotesDocument.diff(old, edited, NotesChange.Kind.USER) ?: return null
    return userEdit(request.start + change.start, request.start + change.end, change.replacement)
}
