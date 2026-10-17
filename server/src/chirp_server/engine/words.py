"""Word timings for the opt-in `word_timings` protocol field.

Parakeet emits SentencePiece pieces with their TDT frame times; `tokens_to_words`
folds them into words the way the transcript text is built: a piece whose text
starts with the word boundary (``▁`` decoded as a space) opens a word, and every
other piece (the rest of the word, attached punctuation) extends the one before.
Joining the word texts with single spaces reproduces the rendered text.
"""

from dataclasses import dataclass


@dataclass(frozen=True)
class Word:
    text: str
    # Seconds from the utterance's first audio sample.
    start: float
    end: float
    # Later partials leave this word alone (the final may still revise any word).
    stable: bool = False

    def payload(self) -> dict:
        return {
            "text": self.text,
            "start": round(self.start, 3),
            "end": round(self.end, 3),
            "stable": self.stable,
        }

    def shifted(self, seconds: float, stable: bool | None = None) -> "Word":
        return Word(
            self.text,
            self.start + seconds,
            self.end + seconds,
            self.stable if stable is None else stable,
        )


def tokens_to_words(tokens, offset: float = 0.0, stable_before: float | None = None) -> list[Word]:
    """Group aligned pieces into words. `offset` shifts the times (seconds); words that
    end before `stable_before` are marked stable."""
    words: list[Word] = []
    group: list = []

    def flush():
        if not group:
            return
        text = "".join(token.text for token in group).strip()
        if not text:
            return
        start = min(token.start for token in group) + offset
        end = max(max(token.end, token.start) for token in group) + offset
        stable = stable_before is not None and end <= stable_before
        words.append(Word(text, start, max(end, start), stable))

    for token in tokens:
        if group and token.text[:1].isspace():
            flush()
            group = []
        group.append(token)
    flush()
    return words


def shift(words, seconds: float, stable: bool | None = None) -> list[Word]:
    return [word.shifted(seconds, stable) for word in words]
