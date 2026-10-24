package dev.chirp.android

import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.withStyle

/**
 * One rendered piece of the notes, with the source lines `[start, end)` it came from (without the final newline), so a
 * tap can put the caret there and a checkbox can write back. [depth] is the list nesting, two spaces (or a tab) a level.
 */
internal sealed interface NotesBlock {
    val start: Int
    val end: Int
    data class Heading(val level: Int, val text: String, override val start: Int, override val end: Int) : NotesBlock
    data class Paragraph(val text: String, override val start: Int, override val end: Int) : NotesBlock
    /** `- item`, `* item` or `1. item`; [number] is null for a bullet. */
    data class Item(val text: String, val depth: Int, val number: String?, override val start: Int, override val end: Int) : NotesBlock
    /** `- [ ] task`; [mark] is the offset of the character between the brackets. */
    data class Task(val text: String, val depth: Int, val checked: Boolean, val mark: Int, override val start: Int, override val end: Int) : NotesBlock
    /** A `Decision:` or `Question:` line, plain or as a list item, bold or not. */
    data class Callout(val kind: Kind, val text: String, val depth: Int, override val start: Int, override val end: Int) : NotesBlock {
        enum class Kind(val label: String) { DECISION("Decision"), QUESTION("Question") }
    }
    data class Quote(val text: String, override val start: Int, override val end: Int) : NotesBlock
    data class Code(val text: String, override val start: Int, override val end: Int) : NotesBlock
    /** Quiet metadata: the "not structured" header, the "nothing yet" placeholder. */
    data class Note(val text: String, override val start: Int, override val end: Int) : NotesBlock
    data class Rule(override val start: Int, override val end: Int) : NotesBlock
}

/** A focused renderer for the notes' Markdown subset: block structure here, inline spans in [notesInline]. No HTML, no links followed. */
internal object NotesBlocks {
    private val item = Regex("""^([ \t]*)([-*+]|\d{1,3}[.)])[ \t]+(.*)$""")
    private val task = Regex("""^\[([ xX])][ \t]+(.*)$""")
    private val callout = Regex("""^(?:\*\*|__)?(Decision|Question)s?(?::(?:\*\*|__)|(?:\*\*|__):|:)[ \t]*(.*)$""", RegexOption.IGNORE_CASE)
    private val rule = Regex("""^[ \t]*([-*_])(?:[ \t]*\1){2,}[ \t]*$""")

    fun parse(text: String): List<NotesBlock> {
        val blocks = mutableListOf<NotesBlock>()
        val lines = mutableListOf<IntRange>()
        var at = 0
        while (at <= text.length) {
            val end = text.indexOf('\n', at).let { if (it < 0) text.length else it }
            lines += at until end; at = end + 1
        }
        fun line(i: Int) = text.substring(lines[i].first, lines[i].last + 1).removeSuffix("\r")
        var i = 0
        while (i < lines.size) {
            val raw = line(i); val trimmed = raw.trim(); val start = lines[i].first; var end = lines[i].last + 1
            when {
                trimmed.isEmpty() -> Unit
                trimmed.startsWith("```") -> {
                    val body = mutableListOf<String>()
                    while (++i < lines.size && !line(i).trim().startsWith("```")) { body += line(i); end = lines[i].last + 1 }
                    if (i < lines.size) end = lines[i].last + 1
                    blocks += NotesBlock.Code(body.joinToString("\n"), start, end)
                }
                NotesMarkdown.heading(trimmed) != null || Regex("^#{4,6} .+").matches(trimmed) -> {
                    val level = trimmed.takeWhile { it == '#' }.length
                    blocks += NotesBlock.Heading(level, trimmed.drop(level).trim().trimEnd('#').trim(), start, end)
                }
                rule.matches(raw) -> blocks += NotesBlock.Rule(start, end)
                trimmed.startsWith(">") -> {
                    val body = mutableListOf(trimmed.removePrefix(">").trim())
                    while (i + 1 < lines.size && line(i + 1).trim().startsWith(">")) { i++; body += line(i).trim().removePrefix(">").trim(); end = lines[i].last + 1 }
                    blocks += NotesBlock.Quote(body.joinToString("\n"), start, end)
                }
                trimmed == NotesDocument.FALLBACK_HEADER || trimmed == NotesMarkdown.PLACEHOLDER ->
                    blocks += NotesBlock.Note(trimmed.removeSurrounding("_"), start, end)
                else -> {
                    val match = item.matchEntire(raw)
                    if (match != null) {
                        val (indent, marker, rest) = match.destructured
                        val depth = indent.replace("\t", "  ").length / 2
                        val restAt = match.groups[3]!!.range.first
                        val taskMatch = task.matchEntire(rest)
                        val calloutMatch = callout.matchEntire(rest)
                        blocks += when {
                            taskMatch != null -> NotesBlock.Task(taskMatch.groupValues[2], depth, taskMatch.groupValues[1] != " ", start + restAt + 1, start, end)
                            calloutMatch != null -> calloutOf(calloutMatch, depth, start, end)
                            else -> NotesBlock.Item(rest, depth, marker.takeIf { it[0].isDigit() }?.dropLast(1)?.plus("."), start, end)
                        }
                    } else {
                        val calloutMatch = callout.matchEntire(trimmed)
                        if (calloutMatch != null) blocks += calloutOf(calloutMatch, 0, start, end)
                        else {
                            // Consecutive plain lines are one paragraph; their line breaks stay, as in most notes apps.
                            val body = mutableListOf(trimmed)
                            while (i + 1 < lines.size && plain(line(i + 1))) { i++; body += line(i).trim(); end = lines[i].last + 1 }
                            blocks += NotesBlock.Paragraph(body.joinToString("\n"), start, end)
                        }
                    }
                }
            }
            i++
        }
        return blocks
    }

    private fun calloutOf(match: MatchResult, depth: Int, start: Int, end: Int): NotesBlock.Callout {
        val kind = if (match.groupValues[1].lowercase() == "decision") NotesBlock.Callout.Kind.DECISION else NotesBlock.Callout.Kind.QUESTION
        return NotesBlock.Callout(kind, match.groupValues[2], depth, start, end)
    }

    private fun plain(line: String): Boolean {
        val trimmed = line.trim()
        return trimmed.isNotEmpty() && !trimmed.startsWith("#") && !trimmed.startsWith(">") && !trimmed.startsWith("```") &&
            item.matchEntire(line) == null && callout.matchEntire(trimmed) == null && !rule.matches(line) &&
            trimmed != NotesDocument.FALLBACK_HEADER && trimmed != NotesMarkdown.PLACEHOLDER
    }

    /** A stable key per block for the lazy list: its kind and source, numbered when the same block repeats. */
    fun keys(text: String, blocks: List<NotesBlock>): List<String> {
        val seen = HashMap<String, Int>()
        return blocks.map { block ->
            val base = block::class.simpleName + ":" + text.substring(block.start, block.end).hashCode()
            "$base#" + seen.merge(base, 1, Int::plus)
        }
    }

    /** The notes with the task at [block] ticked or cleared; the rest of the text is untouched. */
    fun toggle(text: String, block: NotesBlock.Task): String {
        if (block.mark !in text.indices || text[block.mark] !in " xX") return text
        return text.substring(0, block.mark) + (if (block.checked) ' ' else 'x') + text.substring(block.mark + 1)
    }

    /** The block whose source contains [offset], or the last one before it. */
    fun at(blocks: List<NotesBlock>, offset: Int) = blocks.indexOfLast { it.start <= offset }.coerceAtLeast(0)

    /** Plain words of the notes for a list preview: no markers, no heading equal to [title], at most [max] characters. */
    fun preview(text: String, title: String? = null, max: Int = 160): String = parse(text).asSequence()
        .filterNot { it is NotesBlock.Rule || it is NotesBlock.Note || (it is NotesBlock.Heading && it.text == title) }
        .map { block ->
            when (block) {
                is NotesBlock.Heading -> block.text
                is NotesBlock.Paragraph -> block.text.replace('\n', ' ')
                is NotesBlock.Item -> block.text
                is NotesBlock.Task -> (if (block.checked) "☑ " else "☐ ") + block.text
                is NotesBlock.Callout -> block.kind.label + ": " + block.text
                is NotesBlock.Quote -> block.text.replace('\n', ' ')
                is NotesBlock.Code -> block.text.replace('\n', ' ')
                else -> ""
            }.let(::plainInline)
        }
        .filter { it.isNotBlank() }
        .joinToString(" · ").let { if (it.length > max) it.take(max - 1).trimEnd() + "…" else it }

    private fun plainInline(text: String) = notesInline(text, SpanStyle(), SpanStyle()).text
}

/**
 * `**bold**`, `*italic*` / `_italic_`, `` `code` ``, `~~struck~~` and `[label](target)` (shown as the label, never followed);
 * a backslash escapes a marker. Anything unmatched stays as typed.
 */
internal fun notesInline(text: String, code: SpanStyle = SpanStyle(fontFamily = FontFamily.Monospace), link: SpanStyle = SpanStyle(textDecoration = TextDecoration.Underline)): AnnotatedString =
    buildAnnotatedString { inline(text, code, link) }

private fun AnnotatedString.Builder.inline(text: String, code: SpanStyle, link: SpanStyle) {
    var i = 0
    val plain = StringBuilder()
    fun flush() { if (plain.isNotEmpty()) { append(plain.toString()); plain.clear() } }
    fun wordAt(k: Int) = k in text.indices && text[k].isLetterOrDigit()
    while (i < text.length) {
        val c = text[i]
        if (c == '\\' && i + 1 < text.length && text[i + 1] in "\\*_`~[]#") { plain.append(text[i + 1]); i += 2; continue }
        if (c == '`') {
            val close = text.indexOf('`', i + 1)
            if (close > i + 1) { flush(); withStyle(code) { append(text.substring(i + 1, close)) }; i = close + 1; continue }
        }
        if (c == '[') {
            val close = text.indexOf("](", i + 1); val paren = if (close > i) text.indexOf(')', close + 2) else -1
            if (close > i + 1 && paren > close) { flush(); withStyle(link) { inline(text.substring(i + 1, close), code, link) }; i = paren + 1; continue }
        }
        val marker = when {
            text.startsWith("**", i) -> "**"; text.startsWith("__", i) -> "__"; text.startsWith("~~", i) -> "~~"
            c == '*' -> "*"; c == '_' && !wordAt(i - 1) -> "_"
            else -> null
        }
        if (marker != null) {
            var close = text.indexOf(marker, i + marker.length + 1)
            // `_` closes only at a word end, so snake_case stays as typed.
            while (marker == "_" && close > 0 && wordAt(close + 1)) close = text.indexOf(marker, close + 1)
            if (close > 0 && !text[i + marker.length].isWhitespace() && !text[close - 1].isWhitespace()) {
                flush()
                val style = when (marker) {
                    "**", "__" -> SpanStyle(fontWeight = FontWeight.SemiBold)
                    "~~" -> SpanStyle(textDecoration = TextDecoration.LineThrough)
                    else -> SpanStyle(fontStyle = FontStyle.Italic)
                }
                withStyle(style) { inline(text.substring(i + marker.length, close), code, link) }
                i = close + marker.length; continue
            }
        }
        plain.append(c); i++
    }
    flush()
}

/** The light formatting toolbar: line kinds it toggles on the lines the selection touches. */
internal enum class NotesLineKind(val prefix: String) { HEADING("## "), BULLET("- "), TASK("- [ ] ") }

internal object NotesFormat {
    private val marker = Regex("""^([ \t]*)(#{1,6} |[-*+] \[[ xX]] |[-*+] |\d{1,3}[.)] )?""")

    private fun kindOf(line: String): NotesLineKind? {
        val m = marker.find(line)?.groupValues?.get(2).orEmpty()
        return when {
            m.startsWith("#") -> NotesLineKind.HEADING
            m.contains("[") -> NotesLineKind.TASK
            m.isNotEmpty() -> NotesLineKind.BULLET
            else -> null
        }
    }

    /**
     * Gives every line the selection touches [kind] (replacing a heading or list marker it had), or takes it away when the
     * first of them already is one. The caret keeps its place in the words.
     */
    fun toggle(value: TextFieldValue, kind: NotesLineKind): TextFieldValue {
        val text = value.text
        val from = text.lastIndexOf('\n', value.selection.min - 1) + 1
        val to = text.indexOf('\n', value.selection.max).let { if (it < 0) text.length else it }
        val lines = text.substring(from, to).split('\n')
        val prefix = if (kindOf(lines.first()) == kind) "" else kind.prefix
        var shift = 0
        var selStart = value.selection.start; var selEnd = value.selection.end
        val out = StringBuilder()
        var lineAt = from
        lines.forEachIndexed { index, line ->
            val match = marker.find(line)!!
            val indent = match.groupValues[1]; val old = match.groupValues[2]
            val newIndent = if (kind == NotesLineKind.HEADING) "" else indent
            val newLine = newIndent + prefix + line.substring(indent.length + old.length)
            val delta = newLine.length - line.length
            val markerEnd = lineAt + indent.length + old.length
            // A caret in the old marker lands where the words start; after it, it moves with them.
            fun map(p: Int) = if (p <= markerEnd) lineAt + shift + newIndent.length + prefix.length else p + shift + delta
            if (value.selection.start in lineAt..lineAt + line.length) selStart = map(value.selection.start)
            if (value.selection.end in lineAt..lineAt + line.length) selEnd = map(value.selection.end)
            out.append(newLine); if (index < lines.lastIndex) out.append('\n')
            shift += delta; lineAt += line.length + 1
        }
        return TextFieldValue(text.substring(0, from) + out + text.substring(to), TextRange(selStart, selEnd))
    }
}

/**
 * Undo for typing in the editor: each step is the text before an edit. Only the user's own run of edits undoes; once
 * anything else changed the notes (a structuring answer, Organize, a voice edit) the steps are dropped rather than undo it.
 */
internal class NotesTextUndo(private val clock: () -> Long = System::currentTimeMillis) {
    private val steps = ArrayDeque<TextFieldValue>()
    private var after: String? = null
    private var last = 0L

    fun canUndo(current: String) = steps.isNotEmpty() && current == after

    /** An edit from [before] to [now]; edits in one burst (under a second apart, no new line) are one step. */
    fun record(before: TextFieldValue, now: String) {
        if (before.text == now) return
        if (after != before.text) steps.clear()
        val t = clock()
        val burst = steps.isNotEmpty() && t - last < BURST_MS && !now.endsWith("\n")
        if (!burst) { steps.addLast(before); if (steps.size > MAX) steps.removeFirst() }
        after = now; last = t
    }

    /** The value to restore, or null when there is nothing (or the notes changed meanwhile). */
    fun undo(current: String): TextFieldValue? {
        if (!canUndo(current)) { steps.clear(); return null }
        return steps.removeLast().also { after = it.text; last = 0L }
    }

    companion object { const val BURST_MS = 1000L; const val MAX = 100 }
}

/** The title shown on the Notes screen: the name given, else a `# ` heading on the first line, else the start time. */
internal fun NotesDocument.displayTitle(): String = name
    ?: text.lineSequence().firstOrNull { it.isNotBlank() }?.let { NotesMarkdown.heading(it.trim()) }?.takeIf { it.first == 1 }?.second
    ?: title().removePrefix("# ")
