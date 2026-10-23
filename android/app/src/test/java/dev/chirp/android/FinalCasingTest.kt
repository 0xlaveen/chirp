package dev.chirp.android

import org.junit.Assert.*
import org.junit.Test

class FinalCasingTest {
    private fun mid(before: String?) = FinalCasing.midSentence(before)
    private fun lower(text: String) = FinalCasing.lowerFirstWord(text)
    private fun shape(text: String, mid: Boolean = false, commands: Boolean = false) = FinalCasing.shape(text, mid, commands)

    @Test fun `field start and blank context are not mid-sentence`() {
        assertFalse(mid("")); assertFalse(mid("   ")); assertFalse(mid(" \t ")); assertFalse(mid(null))
    }
    @Test fun `sentence terminals start a new sentence`() {
        for (end in listOf(".", "!", "?", "…", "。", "！", "？", "।", "؟", "‼", "⁇", "?!")) {
            assertFalse("after '$end'", mid("Done$end")); assertFalse("after '$end ' ", mid("Done$end "))
            assertFalse("after '$end' two spaces", mid("Done$end  "))
        }
    }
    @Test fun `line breaks start a new sentence`() {
        for (br in listOf("\n", "\r", "\r\n", " ", " ")) {
            assertFalse(mid("and then$br")); assertFalse(mid("and then$br  "))
        }
        assertFalse(mid("one\n\n"))
    }
    @Test fun `words and commas mean mid-sentence`() {
        assertTrue(mid("and then")); assertTrue(mid("and then ")); assertTrue(mid("and then  "))
        assertTrue(mid("first,")); assertTrue(mid("first, ")); assertTrue(mid("first;")); assertTrue(mid("page 3")); assertTrue(mid("x"))
        assertTrue(mid("été")); assertTrue(mid("日本語")); assertTrue(mid("привет ")); assertTrue(mid("Straße "))
    }
    @Test fun `closing quotes look through to the sentence end`() {
        assertFalse(mid("He left.\"")); assertFalse(mid("He left.” ")); assertFalse(mid("He left.’")); assertFalse(mid("«Fini.» "))
        assertFalse(mid("He left.'")); assertTrue(mid("\"hello\"")); assertTrue(mid("“hello” ")); assertTrue(mid("the dogs' ")); assertTrue(mid("it’s ‘fine’ "))
    }
    @Test fun `opening quotes brackets colons and markers stay as sent`() {
        for (before in listOf("said \"", "said “", "said ‘", "(", "see (", "[", "{", "«", "«  ", "said '", "x: ", "x:", "- ", "* ", "• ", "# ",
            "1) ", "(a) ", "see this) ", "> ", "😀 ", "@", "/", "=", "a—", "a - ", "¿", "„")) assertFalse("'$before'", mid(before))
        assertTrue(mid("…and "))
    }
    @Test fun `lookbehind is limited to what the editor returned`() {
        assertTrue(mid("x".repeat(FinalCasing.LOOKBEHIND)))
        assertFalse(mid(" ".repeat(FinalCasing.LOOKBEHIND)))
    }

    @Test fun `common sentence starters are lower-cased`() {
        for (word in listOf("And", "But", "So", "Then", "We", "The", "A", "An", "It", "He", "She", "They", "You", "This", "That", "What",
            "Because", "Also", "Actually", "Okay", "Yeah", "Maybe", "Tomorrow", "Today", "Please", "However", "Just", "Let")) {
            assertEquals("${word.lowercase()} went there.", lower("$word went there."))
        }
    }
    @Test fun `contractions of common words are lower-cased but I contractions are not`() {
        assertEquals("we're late", lower("We're late")); assertEquals("don't stop", lower("Don't stop")); assertEquals("it’s fine", lower("It’s fine"))
        assertEquals("that's it", lower("That's it")); assertEquals("let's go", lower("Let's go")); assertEquals("they’ll try", lower("They’ll try"))
        for (text in listOf("I", "I am", "I'm here", "I’m here", "I'll go", "I've seen", "I'd say", "I, too", "I.")) assertEquals(text, lower(text))
    }
    @Test fun `acronyms and mixed case words stay`() {
        for (text in listOf("NASA said", "AND then", "US ships", "SO what", "GitHub is down", "McDonald's opened", "WiFi is out", "A1 sauce", "A/B test",
            "B2B sales", "So-called experts", "ÀB test", "AI wins")) assertEquals(text, lower(text))
    }
    @Test fun `possible proper nouns and unknown words stay`() {
        for (text in listOf("Paris is nice", "Monday works", "Google said", "Will you come", "May I", "Mark it", "Bill paid", "Grace helped", "Hope so",
            "Amazon ships", "Tomorrowland opens", "Something's off", "Anna and Bob")) assertEquals(text, lower(text))
    }
    @Test fun `already lower or non-letter starts are untouched`() {
        for (text in listOf("and then", "and", "", " ", "\"And then\"", "(And then)", "3 And", "…And", "¿And", "-And", "😀 And", "_And")) assertEquals(text, lower(text))
    }
    @Test fun `only the first word changes and leading whitespace is kept`() {
        assertEquals("and We went. The end.", lower("And We went. The end."))
        assertEquals(" and then", lower(" And then")); assertEquals("\nand then", lower("\nAnd then"))
        assertEquals("and, then", lower("And, then")); assertEquals("and.", lower("And.")); assertEquals("and—then", lower("And—then"))
        assertEquals("and", lower("And")); assertEquals("the (And)", lower("The (And)"))
    }
    @Test fun `unicode text is safe`() {
        for (text in listOf("Élan vital", "Über cool", "İstanbul", "ΑΛΦΑ", "Привет мир", "日本語です", "Éa", "Ünd", "Çok")) assertEquals(text, lower(text))
        assertEquals("and 日本語", lower("And 日本語")); assertEquals("and 😀", lower("And 😀")); assertEquals("and é", lower("And é"))
    }

    @Test fun `shape leaves sentence starts and commands-off finals alone`() {
        assertEquals("And then We went.", shape("And then We went.", mid = false))
        assertEquals("and then We went.", shape("And then We went.", mid = true))
        assertEquals("New line.", shape("New line.", mid = true))
        assertEquals("Go new line", shape("Go new line"))
    }
    @Test fun `new line and new paragraph as the whole utterance`() {
        for (text in listOf("New line", "New line.", "new line", "NEW LINE!", "New Line?", "  New line  ", "New line…", "New line,")) assertEquals(text, "\n", shape(text, commands = true))
        for (text in listOf("New paragraph", "New paragraph.", "new paragraph", "NEW PARAGRAPH!", "New Paragraph…")) assertEquals(text, "\n\n", shape(text, commands = true))
    }
    @Test fun `new line and new paragraph as a tail`() {
        assertEquals("Okay,\n", shape("Okay, new line.", commands = true))
        assertEquals("Thanks for the update.\n\n", shape("Thanks for the update. New paragraph.", commands = true))
        assertEquals("Thanks,\n", shape("Thanks, new line", commands = true))
        assertEquals("one two\n", shape("one two   new line", commands = true))
        assertEquals("one\n", shape("one\tnew line!", commands = true))
        assertEquals("one\n\n", shape("one\nnew paragraph", commands = true))
    }
    @Test fun `commands need an exact word match at the tail`() {
        for (text in listOf("New lines", "Newline", "new-line", "new  line", "a new line of work", "New line please", "Renew line", "new linen", "New paragraphs",
            "new  paragraph", "New paragraph one", "line new", "new", "line")) assertEquals(text, shape(text, commands = true))
    }
    @Test fun `commands apply after casing the remaining head`() {
        assertEquals("and then\n", shape("And then new line.", mid = true, commands = true))
        assertEquals("And then\n", shape("And then new line.", mid = false, commands = true))
        assertEquals("\n", shape("New line", mid = true, commands = true))
        assertEquals("Paris.\n\n", shape("Paris. New paragraph.", mid = true, commands = true))
    }
    @Test fun `commands only fire when enabled`() {
        assertEquals("Okay, new line.", shape("Okay, new line.", commands = false))
        assertEquals("New paragraph.", shape("New paragraph.", mid = true, commands = false))
    }
}
