package dev.chirp.android

import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.concurrent.atomic.AtomicLong
import org.json.JSONArray
import org.json.JSONObject

/** One committed segment of a Notes recording: an utterance's final, or a gap where it failed. */
internal data class NotesSegment(
    val id: Int,
    /** Seconds from the start of the session to the segment's first audio. */
    val offset: Double,
    val raw: String,
    /** The corrected text, or the raw text when clean-up was off or failed. */
    val text: String = raw,
    val corrected: Boolean = false,
    /** Clean-up was asked for but did not deliver, so the raw text was kept. */
    val keptOriginal: Boolean = false,
    /** Set for a gap: why this stretch of audio was not transcribed. */
    val failure: String? = null,
) {
    val isGap get() = failure != null
    companion object { fun gap(id: Int, offset: Double, reason: String) = NotesSegment(id, offset, "", failure = reason) }
}

/** Part of a rejected window after it was split: structured Markdown, or a part that kept failing and stays raw. */
internal sealed interface NotesPiece {
    data class Markdown(val text: String) : NotesPiece
    data class Fallback(val text: String) : NotesPiece
}

/** One change to the notes text: `[start, end)` in the text before it becomes [replacement]. */
internal data class NotesChange(val start: Int, val end: Int, val replacement: String, val kind: Kind) {
    enum class Kind { USER, APPEND, REORGANIZE, ORGANIZE }
    fun applied(text: String) = text.substring(0, start) + replacement + text.substring(end)
    /** Where an offset in the old text lands in the new one (inside the replaced range: after the replacement). */
    fun map(offset: Int) = when {
        offset <= start -> offset
        offset >= end -> offset + replacement.length - (end - start)
        else -> start + replacement.length
    }
}

/** The small Markdown subset the server's notes guards allow, line by line. */
internal object NotesMarkdown {
    const val PLACEHOLDER = "_(nothing yet)_"

    /** `# `, `## ` or `### ` followed by text: (level, text). */
    fun heading(line: String): Pair<Int, String>? {
        val hashes = line.takeWhile { it == '#' }.length
        if (hashes !in 1..3 || line.getOrNull(hashes) != ' ') return null
        return line.substring(hashes + 1).trim().takeIf { it.isNotEmpty() }?.let { hashes to it }
    }

    fun headings(md: String) = md.replace("\r\n", "\n").replace('\r', '\n').split('\n').mapNotNull { heading(it.trim())?.second }

    /** Each heading starts a section; text before the first heading is one too. `[start, end)` and the heading. */
    fun sections(text: String): List<Pair<IntRange, String?>> {
        val result = mutableListOf<Pair<IntRange, String?>>()
        var start = 0; var location = 0; var current: String? = null
        for (line in text.split('\n')) {
            val title = heading(line)?.second
            if (title != null) {
                if (location > start || current != null) result += (start until location) to current
                start = location; current = title
            }
            location += line.length + 1
        }
        if (text.length > start || current != null) result += (start until text.length) to current
        return result
    }
}

/** Unicode scalars, as the server counts its limits. */
internal val String.scalars get() = codePointCount(0, length)

/**
 * Everything a Notes session holds, in memory only: the transcript segments and one Markdown string, the notes,
 * written by the user and by structuring passes. The AI owns only a suffix, the tail (`text[tailStart..]`): an append
 * only ever replaces the tail, and any user edit that touches the tail hands it to the user. A port of the Mac's
 * `NotesDocument` (without speaker labels); nothing here is persisted or logged.
 */
internal class NotesDocument(var startedAt: Long = System.currentTimeMillis(), text: String = "") {
    /** This document, as opposed to one New replaced: a late answer for a discarded document is never applied. */
    val id = ids.incrementAndGet()
    private val committed = mutableListOf<NotesSegment>()
    val segments: List<NotesSegment> get() = committed
    var text = text
        private set
    var tailStart = text.length
        private set
    /** +1 on every change to [text] (user or AI). */
    var version = 0
        private set
    /** +1 whenever the tail is claimed, settles or a reorganize lands: a pass asked for an earlier one is stale. */
    var windowGeneration = 0
        private set
    var windowStart = 0
        private set
    /** The last segment index the tail covers; below [windowStart] before any pass succeeded in this window. */
    var structuredEnd = -1
        private set
    var consecutiveFailures = 0
        private set
    var lastReorganizeVersion = 0
        private set
    /** Characters inserted (user or AI) since the last reorganize. */
    var charsSinceReorganize = 0
        private set
    /** The live partials of the segments still in flight. Display only: never exported. */
    var livePartial = ""
    /** The user's name for this session (Rename), else the title is the start time. */
    var name: String? = null
    /** Every fallback block appended, exactly as appended; one still found verbatim is one Organize may redo. */
    private val fallbackBlocks = mutableListOf<String>()

    val isEmpty get() = text.isBlank() && committed.none { !it.isGap && it.text.isNotEmpty() }
    val tail get() = text.substring(tailStart)
    val settledText get() = text.substring(0, tailStart)

    /** The first recording of an empty document starts now: the title uses this time. */
    fun stampStart(time: Long) { if (committed.isEmpty()) startedAt = time }

    fun append(segment: NotesSegment) { committed += segment.copy(id = committed.size) }

    // User edits

    /**
     * The editor changed the text. An edit wholly before the tail shifts it; an edit that touches a non-empty tail
     * claims it, so the whole tail becomes user text and the next pass starts a new tail after it.
     */
    fun userEdit(start: Int, end: Int, replacement: String): NotesChange {
        val change = NotesChange(start, end, replacement, NotesChange.Kind.USER)
        val claims = touchesTail(start, end)
        text = change.applied(text)
        if (claims) { settleTail(); consecutiveFailures = 0 } else tailStart += replacement.length - (end - start)
        changed(replacement.length)
        return change
    }

    /** Whether an edit of `[start, end)` would claim the tail (and so whether an append would land under a caret). */
    fun touchesTail(start: Int, end: Int): Boolean {
        if (tailStart >= text.length) return false
        if (end > tailStart) return true
        // An insertion right before the separator extends the user's line; right before AI text, it edits the tail.
        return start == tailStart && end == start && text[tailStart] != '\n'
    }

    private fun changed(inserted: Int) { version++; charsSinceReorganize += inserted }

    private fun settleTail() {
        tailStart = text.length
        if (structuredEnd >= windowStart) windowStart = structuredEnd + 1
        windowGeneration++
    }

    // The open window

    private val windowSegments get() = if (windowStart >= committed.size) emptyList()
        else committed.subList(windowStart, committed.size).filter { !it.isGap && it.text.isNotEmpty() }

    private fun windowTranscript(through: Int = Int.MAX_VALUE) = windowSegments.filter { it.id <= through }.joinToString("\n") { it.text }

    fun windowChars(through: Int = Int.MAX_VALUE) = windowTranscript(through).scalars

    /** The window's text no pass has structured yet: the "Hearing" strip. */
    val unstructuredTail get() = windowSegments.filter { it.id > structuredEnd }.joinToString(" ") { it.text }

    val outline get() = capOutline(NotesMarkdown.headings(settledText))

    /** The next pass, or null when the window has nothing new or is over [MAX_WINDOW_CHARS] (until it overflows). */
    fun nextStructureRequest(final: Boolean = false): NotesStructureRequest? {
        val last = windowSegments.lastOrNull() ?: return null
        if (last.id <= structuredEnd) return null
        val transcript = windowTranscript()
        if (transcript.scalars > MAX_WINDOW_CHARS || transcript.isBlank()) return null
        return NotesStructureRequest(transcript, outline, final, committed.size - 1, version, windowGeneration, id)
    }

    /**
     * Takes a pass's answer: a success replaces the tail and settles it once the window is long enough; a failure keeps
     * the previous tail. A response for a tail that was claimed, settled or reorganized since is ignored.
     */
    fun apply(response: NotesStructureResponse, request: NotesStructureRequest): NotesChange? {
        if (!current(request)) return null
        return recording(NotesChange.Kind.APPEND) {
            val md = response.markdown?.trim()
            if (response.structured && !md.isNullOrEmpty()) {
                replaceTail(md)
                structuredEnd = request.windowEnd; consecutiveFailures = 0
                if (windowChars(request.windowEnd) >= FREEZE_CHARS) settleTail()
            } else consecutiveFailures++
            overflow()
        }
    }

    private fun current(request: NotesStructureRequest) = request.documentId == id && request.windowGeneration == windowGeneration &&
        request.windowEnd >= windowStart && request.windowEnd < committed.size && request.windowEnd > structuredEnd

    private val tailSeparator get() = settledText.let { if (it.isEmpty() || it.endsWith("\n\n")) "" else if (it.endsWith("\n")) "\n" else "\n\n" }

    private fun replaceTail(markdown: String) { text = settledText + tailSeparator + markdown }

    /** A window past [MAX_WINDOW_CHARS], or past [FREEZE_CHARS] after two failures, settles and falls back to raw text. */
    fun freezeOverflow() = recording(NotesChange.Kind.APPEND) { overflow() }

    private fun overflow() {
        fun qualifies(chars: Int) = chars > MAX_WINDOW_CHARS || (consecutiveFailures >= 2 && chars >= FREEZE_CHARS)
        if (!qualifies(windowChars())) return
        settleTail()
        if (!qualifies(windowChars())) return
        appendFallback(); consecutiveFailures = 0
    }

    /** At Stop, after the final pass: the tail settles and, with structuring on, whatever it did not cover falls back. */
    fun freezeAll(structuring: Boolean = true) = recording(NotesChange.Kind.APPEND) {
        settleTail()
        if (structuring) appendFallback()
        consecutiveFailures = 0
    }

    private fun appendFallback() {
        val rest = windowSegments
        if (rest.isNotEmpty()) {
            val block = fallbackBlock(rest.joinToString("\n\n") { it.text })
            fallbackBlocks += block
            text = settledText + tailSeparator + block
        }
        windowStart = committed.size; structuredEnd = windowStart - 1
        settleTail()
    }

    /** Runs AI mutations (which only change a suffix) and returns the minimal change they made. */
    private fun recording(kind: NotesChange.Kind, body: () -> Unit): NotesChange? {
        val before = text
        body()
        return diff(before, text, kind)?.also { changed(it.replacement.length) }
    }

    /** The parts of a split window replace the tail in order and the tail settles. */
    fun applyPieces(pieces: List<NotesPiece>, request: NotesStructureRequest): NotesChange? {
        if (!current(request) || pieces.isEmpty()) return null
        return recording(NotesChange.Kind.APPEND) {
            replaceTail(render(pieces))
            pieces.filterIsInstance<NotesPiece.Fallback>().forEach { fallbackBlocks += fallbackBlock(it.text.trim()) }
            structuredEnd = request.windowEnd; consecutiveFailures = 0
            settleTail(); overflow()
        }
    }

    /** Fallback blocks still in the text exactly as appended: (block, raw text under its header). */
    val untouchedFallbacks get() = fallbackBlocks.filter { text.contains(it) }.map { it to it.drop(FALLBACK_HEADER.length + 2) }

    /** Organize: each untouched fallback block replaced in place, only when the text is still [expected]. */
    fun replaceFallbacks(replacements: List<Pair<String, List<NotesPiece>>>, expected: Int): List<NotesChange> {
        if (version != expected) return emptyList()
        val located = replacements.mapNotNull { (block, pieces) -> text.indexOf(block).takeIf { it >= 0 }?.let { Triple(it, block, pieces) } }
        val changes = mutableListOf<NotesChange>()
        var inserted = 0
        // From the end backwards, so every range is still where it was found when its change is replayed.
        for ((at, block, pieces) in located.sortedByDescending { it.first }) {
            val change = NotesChange(at, at + block.length, render(pieces), NotesChange.Kind.ORGANIZE)
            text = change.applied(text)
            if (change.end <= tailStart) tailStart += change.replacement.length - block.length else settleTail()
            fallbackBlocks.remove(block)
            pieces.filterIsInstance<NotesPiece.Fallback>().forEach { fallbackBlocks += fallbackBlock(it.text.trim()) }
            inserted += change.replacement.length
            changes += change
        }
        if (changes.isNotEmpty()) changed(inserted)
        return changes
    }

    // Reorganize

    /** The longest suffix of whole sections within [maxChars], and the headings above it (context only). */
    fun reorganizeScope(maxChars: Int = MAX_REORGANIZE_CHARS): Pair<IntRange, List<String>>? {
        var start = text.length; var chars = 0
        for ((range, _) in NotesMarkdown.sections(text).asReversed()) {
            val size = text.substring(range.first, range.last + 1).scalars
            if (chars + size > maxChars) break
            chars += size; start = range.first
        }
        if (start >= text.length || text.substring(start).trim().length < MIN_REORGANIZE_CHARS) return null
        return (start until text.length) to (if (start == 0) emptyList() else capOutline(NotesMarkdown.headings(text.substring(0, start))))
    }

    val reorganizeTooLong get() = NotesMarkdown.sections(text).lastOrNull()?.let { text.substring(it.first.first, it.first.last + 1).scalars > MAX_REORGANIZE_CHARS } == true

    fun reorganizeRequest(final: Boolean, manual: Boolean, maxChars: Int = MAX_REORGANIZE_CHARS): NotesReorganizeRequest? {
        if (!manual && version == lastReorganizeVersion) return null
        val (range, outline) = reorganizeScope(maxChars) ?: return null
        return NotesReorganizeRequest(text.substring(range.first), outline, final, version, range.first, text.length, id)
    }

    /** Takes a reorganize answer, only when the text is exactly what the request was made from. */
    fun applyReorganize(response: NotesReorganizeResponse, request: NotesReorganizeRequest): NotesChange? {
        if (request.documentId != id || request.version != version || request.end > text.length || !response.reorganized) return null
        val md = response.markdown?.trim()
        if (!response.changed || md.isNullOrEmpty()) { lastReorganizeVersion = version; charsSinceReorganize = 0; return null }
        val old = text.substring(request.start, request.end)
        // Keep the blank lines that frame the scope, so the sections around it stay separated as they were.
        val change = NotesChange(request.start, request.end, old.takeWhile { it == '\n' } + md + old.takeLastWhile { it.isWhitespace() },
            NotesChange.Kind.REORGANIZE)
        text = change.applied(text)
        settleTail()
        changed(change.replacement.length)
        lastReorganizeVersion = version; charsSinceReorganize = 0
        return change
    }

    // Export

    private fun format(pattern: String, zone: TimeZone) = SimpleDateFormat(pattern, Locale.US).apply { timeZone = zone }.format(Date(startedAt))

    fun title(zone: TimeZone = TimeZone.getDefault()) = "# " + (name ?: "Notes — " + format("yyyy-MM-dd HH:mm", zone))

    /** Save's suggested file name: the name, else the start time, without characters file systems refuse. */
    fun fileName(zone: TimeZone = TimeZone.getDefault()) =
        (name ?: "Notes " + format("yyyy-MM-dd HHmm", zone)).replace(Regex("[\\\\/:*?\"<>|\\p{Cntrl}]"), " ").trim().take(80) + ".md"

    /** The notes without placeholder lines, trimmed. */
    val notesBody get() = text.split('\n').filter { it.trim() != NotesMarkdown.PLACEHOLDER }.joinToString("\n").trim()

    /** One line per segment: `**[00:00:12]** text`, gaps and "kept original" marked; [raw] swaps in the raw text. */
    fun transcriptLines(raw: Boolean = false) = committed.map { s ->
        val stamp = "**[${timestamp(s.offset)}]** "
        if (s.failure != null) stamp + "⚠︎ audio not transcribed (${s.failure})"
        else stamp + (if (raw) s.raw else s.text) + if (s.keptOriginal && !raw) " _(kept original)_" else ""
    }

    fun transcriptMarkdown(raw: Boolean = false) = (listOf("## Transcript") + transcriptLines(raw)).joinToString("\n\n")

    /** Copy and Share: the title, the notes, then the transcript appendix (only the transcript without notes). */
    fun exportMarkdown(includeNotes: Boolean = true, zone: TimeZone = TimeZone.getDefault()): String {
        val parts = mutableListOf(title(zone))
        val body = if (includeNotes) notesBody else ""
        if (body.isNotEmpty()) parts += listOf(body, "---")
        parts += transcriptMarkdown()
        return parts.joinToString("\n\n") + "\n"
    }

    // Recovery copy

    /** Everything but the live partial and the reorganize bookkeeping, for [NotesJournal]. */
    fun toJson(): JSONObject = JSONObject().put("startedAt", startedAt).put("text", text).put("tailStart", tailStart)
        .put("windowStart", windowStart).put("structuredEnd", structuredEnd).put("fallbacks", JSONArray(fallbackBlocks))
        .put("segments", JSONArray().apply {
            committed.forEach { s ->
                put(JSONObject().put("offset", s.offset).put("raw", s.raw).put("text", s.text).put("corrected", s.corrected)
                    .put("kept", s.keptOriginal).apply { s.failure?.let { put("failure", it) } })
            }
        }).apply { name?.let { put("name", it) } }

    companion object {
        fun fromJson(json: JSONObject) = NotesDocument(json.getLong("startedAt"), json.getString("text")).apply {
            name = json.optString("name").takeIf { json.has("name") }
            val list = json.getJSONArray("segments")
            for (i in 0 until list.length()) list.getJSONObject(i).let { s ->
                committed += NotesSegment(i, s.getDouble("offset"), s.getString("raw"), s.getString("text"), s.optBoolean("corrected"),
                    s.optBoolean("kept"), s.optString("failure").takeIf { s.has("failure") })
            }
            tailStart = json.getInt("tailStart").coerceIn(0, text.length)
            windowStart = json.getInt("windowStart").coerceIn(0, committed.size)
            structuredEnd = json.getInt("structuredEnd").coerceIn(windowStart - 1, committed.size - 1)
            json.optJSONArray("fallbacks")?.let { a -> for (i in 0 until a.length()) fallbackBlocks += a.getString(i) }
        }

        /** The tail settles once a pass succeeded on this many transcript characters. */
        const val FREEZE_CHARS = 1600
        /** The open window never grows past this; it falls back to raw text instead. */
        const val MAX_WINDOW_CHARS = 3600
        /** The most notes one reorganize sends (the server's limit), Unicode scalars. */
        const val MAX_REORGANIZE_CHARS = 3500
        const val MIN_REORGANIZE_CHARS = 80
        /** An automatic reorganize while recording: small enough to fit between two segment cuts. */
        const val RECORDING_REORGANIZE_CHARS = 1200
        const val MAX_OUTLINE_ITEMS = 24
        const val MAX_OUTLINE_ITEM_CHARS = 120
        const val MAX_OUTLINE_CHARS = 1500
        const val MIN_SPLIT_CHARS = 400
        const val FALLBACK_HEADER = "_Not structured — see transcript_"
        private val ids = AtomicLong()

        fun capOutline(headings: List<String>): List<String> {
            val items = headings.takeLast(MAX_OUTLINE_ITEMS).map { it.take(MAX_OUTLINE_ITEM_CHARS) }.toMutableList()
            while (items.sumOf { it.length } > MAX_OUTLINE_CHARS) items.removeAt(0)
            return items
        }

        fun fallbackBlock(body: String) = "$FALLBACK_HEADER\n\n$body"

        fun render(pieces: List<NotesPiece>) = pieces.map {
            when (it) { is NotesPiece.Markdown -> it.text.trim(); is NotesPiece.Fallback -> fallbackBlock(it.text.trim()) }
        }.filter { it.isNotEmpty() }.joinToString("\n\n")

        /** Splits at the sentence end nearest the middle (else the nearest space), each part at least [minPart]. */
        fun split(text: String, minPart: Int = MIN_SPLIT_CHARS): Pair<String, String>? {
            if (text.length < 2 * minPart) return null
            val middle = text.length / 2
            fun cut(boundary: (Int) -> Boolean) = (minPart..(text.length - minPart)).filter(boundary).minByOrNull { kotlin.math.abs(it - middle) }
            val at = cut { i -> text[i].isWhitespace() && text[i - 1] in ".?!\n" } ?: cut { text[it].isWhitespace() } ?: return null
            val a = text.substring(0, at).trim(); val b = text.substring(at).trim()
            return if (a.isEmpty() || b.isEmpty()) null else a to b
        }

        /** The smallest single replacement that turns [old] into [new], never splitting a surrogate pair. */
        fun diff(old: String, new: String, kind: NotesChange.Kind): NotesChange? {
            if (old == new) return null
            var prefix = 0
            while (prefix < old.length && prefix < new.length && old[prefix] == new[prefix]) prefix++
            var suffix = 0
            while (suffix < old.length - prefix && suffix < new.length - prefix && old[old.length - 1 - suffix] == new[new.length - 1 - suffix]) suffix++
            fun splits(s: String, i: Int) = i < s.length && s[i].isLowSurrogate()
            while (prefix > 0 && (splits(old, prefix) || splits(new, prefix))) prefix--
            while (suffix > 0 && (splits(old, old.length - suffix) || splits(new, new.length - suffix))) suffix--
            return NotesChange(prefix, old.length - suffix, new.substring(prefix, new.length - suffix), kind)
        }

        /** `hh:mm:ss` from the session start. */
        fun timestamp(offset: Double): String {
            val s = maxOf(0, offset.toInt())
            return "%02d:%02d:%02d".format(Locale.US, s / 3600, s / 60 % 60, s % 60)
        }
    }
}
