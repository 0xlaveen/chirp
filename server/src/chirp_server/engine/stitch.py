"""Conservative transcript stitching for overlapping final voice windows."""

import re
import unicodedata

WORD = re.compile(r"[^\W_]+(?:['’][^\W_]+)*", re.UNICODE)
# Punctuation the decoder attaches to the end of a word.
TRAILING = re.compile(r"^[,.;:!?…]+")


def normalized_words(text: str) -> list[str]:
    return [word.lower() for word in WORD.findall(unicodedata.normalize("NFC", text))]


def stitch_transcript(committed: str, tail: str, *, minimum_overlap: int = 2) -> str | None:
    """Stitch where a verified overlap follows unstable leading tail words."""
    left, right = normalized_words(committed), normalized_words(tail)
    tail = unicodedata.normalize("NFC", tail)
    matches = list(WORD.finditer(tail))
    max_leading_words = min(8, len(right) - minimum_overlap)
    for size in range(min(len(left), len(right)), minimum_overlap - 1, -1):
        for start in range(max_leading_words + 1):
            if left[-size:] == right[start : start + size]:
                suffix = tail[matches[start + size - 1].end() :]
                return join_at_seam(committed, suffix)
    return None


def join_at_seam(committed: str, suffix: str) -> str:
    """Append the text after the seam word without doubling its punctuation.

    The suffix starts right after the shared seam word, so punctuation the
    tail decode put on that word comes first (``", the lock"``). The
    committed copy of the word already carries its own (#2442): keep that,
    or adopt the tail's when the committed word has none.
    """
    left = committed.strip()
    mark = TRAILING.match(suffix.lstrip())
    rest = suffix.lstrip()[mark.end() :].strip() if mark else suffix.strip()
    if mark and left and not TRAILING.match(left[-1]):
        left += mark.group()
    return " ".join(part for part in (left, rest) if part)
