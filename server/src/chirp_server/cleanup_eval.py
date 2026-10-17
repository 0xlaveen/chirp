"""Scoring for synthetic cleanup fixtures; never consumes live dictation."""

import json
import re
import unicodedata
from dataclasses import dataclass
from pathlib import Path


def normalize(text: str) -> list[str]:
    # Ignore typography/casing/punctuation, but preserve words, order and multiplicity.
    return re.findall(r"\w+", unicodedata.normalize("NFKC", text).casefold())


def distance(left: list[str], right: list[str]) -> int:
    row = list(range(len(right) + 1))
    for i, word in enumerate(left, 1):
        next_row = [i]
        for j, other in enumerate(right, 1):
            next_row.append(min(next_row[-1] + 1, row[j] + 1, row[j - 1] + (word != other)))
        row = next_row
    return row[-1]


def contains(words: list[str], phrase: str) -> bool:
    tokens = normalize(phrase)
    return any(words[i : i + len(tokens)] == tokens for i in range(len(words) - len(tokens) + 1))


@dataclass(frozen=True)
class Score:
    exact: bool
    near: bool
    must_keep: bool
    must_drop: bool
    unchanged: bool

    @property
    def passed(self) -> bool:
        return self.near and self.must_keep and self.must_drop and self.unchanged


def score(case: dict, text: str) -> Score:
    words = normalize(text)
    alternatives = [normalize(value) for value in [case["expected"], *case.get("alternatives", [])]]
    errors = min(distance(expected, words) / max(1, len(expected)) for expected in alternatives)
    return Score(
        exact=words in alternatives,
        near=errors <= case.get("max_error_rate", 0.08),
        must_keep=all(contains(words, phrase) for phrase in case["must_keep"])
        and all(phrase in text for phrase in case.get("must_keep_literal", [])),
        must_drop=all(not contains(words, phrase) for phrase in case["must_drop"]),
        unchanged=(not case.get("unchanged", False) or text == case["raw"])
        and (not case.get("required_suffix") or text.endswith(case["required_suffix"]))
        and (not case.get("forbidden_suffix") or not text.endswith(case["forbidden_suffix"])),
    )


def load_cases(path: Path) -> list[dict]:
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
