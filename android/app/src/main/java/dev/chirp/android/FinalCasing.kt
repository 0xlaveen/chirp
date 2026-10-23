package dev.chirp.android

import java.util.Locale

/**
 * Conservative local shaping of a dictation final. Pure: no editor, no logging, no retained text.
 * Only unmistakable cases change; anything unsure stays exactly as the server sent it.
 */
object FinalCasing {
    private const val TERMINAL = ".!?…‼⁇⁈⁉。！？।؟"
    private const val OPENERS = "([{<“‘«‹„‚¡¿"
    private const val CLOSING_QUOTES = "”’»›"
    private const val FOLLOWERS = ",.;:!?…)]}\"”’'—–"
    private val BREAKS = "\n\r  "

    /** How much text before the cursor [midSentence] needs to see. */
    const val LOOKBEHIND = 16

    /** True when [before] (the text preceding the insertion point) shows a sentence is already under way. */
    fun midSentence(before: CharSequence?): Boolean {
        if (before == null) return false
        var i = before.length
        while (i > 0 && before[i - 1].isWhitespace()) { if (before[i - 1] in BREAKS) return false; i-- }
        while (i > 0) {
            val c = before[i - 1]; val prev = if (i > 1) before[i - 2] else null
            val closing = c in CLOSING_QUOTES ||
                ((c == '"' || c == '\'') && prev != null && !prev.isWhitespace() && prev !in OPENERS)
            if (!closing) break
            i--
        }
        if (i == 0) return false // field start, or only whitespace/quotes we cannot judge
        val c = before[i - 1]
        return c.isLetterOrDigit() || c == ',' || c == ';'
    }

    // Common sentence starters that are never names. Everything else capitalised may be a proper noun and stays.
    private val COMMON = ("a about actually after again all also although an and another any anyone anything anyway anyways are " +
        "as at basically because before both but by can could did didn't do does doesn't don't each even every everyone " +
        "everything first for from got had has have he her here hey hi his honestly how however if in instead into is isn't it " +
        "it's its just let let's like maybe meanwhile more most much my never next no not nothing now of oh ok okay on once one only " +
        "or other otherwise our out over please plus probably really right same she should since so some someone something " +
        "sometimes still such sure than thanks that that's the their them then there there's these they they're they'll they've she's he's what's who's this those though " +
        "through to today tomorrow tonight too under unless until up us usually very want was wasn't we we'll we're we've well " +
        "went were what whatever when whenever where whether which while who why with without would wouldn't yeah yep yes yesterday " +
        "yet you you'll you're you've your").split(' ').toSet()

    /** Lower-cases the first word when it is a known common word; "I", acronyms and mixed-case words are never touched. */
    internal fun lowerFirstWord(text: String): String {
        val start = text.indexOfFirst { !it.isWhitespace() }
        if (start < 0 || !text[start].isLetter() || !text[start].isUpperCase()) return text
        var end = start + 1
        while (end < text.length && (text[end].isLetter() || (text[end] == '\'' || text[end] == '’') &&
                end + 1 < text.length && text[end + 1].isLetter())) end++
        val word = text.substring(start, end)
        if (end < text.length && !text[end].isWhitespace() && text[end] !in FOLLOWERS) return text // A/B, A1, So-called
        if (word.drop(1).any { it.isUpperCase() }) return text // NASA, iOS-like, McDonald, GitHub
        val key = word.replace('’', '\'').lowercase(Locale.ROOT)
        if (key == "i" || key.startsWith("i'") || key !in COMMON) return text
        return text.substring(0, start) + word.replaceFirstChar { it.lowercaseChar() } + text.substring(end)
    }

    private val COMMAND = Regex("""(?:^|\s)(new line|new paragraph)[\s.,!?…]*$""", RegexOption.IGNORE_CASE)

    /**
     * Applies the opt-in spoken [commands] ("new line" / "new paragraph" as the whole utterance or its tail
     * become one or two line breaks), then lower-cases the first word when [midSentence].
     */
    fun shape(text: String, midSentence: Boolean, commands: Boolean): String {
        val command = if (commands) COMMAND.find(text) else null
        val head = command?.let { text.substring(0, it.groups[1]!!.range.first).trimEnd() } ?: text
        val cased = if (midSentence) lowerFirstWord(head) else head
        return cased + (command?.let { if (it.groupValues[1].length == 8) "\n" else "\n\n" } ?: "")
    }
}
