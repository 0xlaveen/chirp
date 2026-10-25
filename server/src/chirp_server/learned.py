"""What a client learned from the user's own edits, sent with a dictation's `start` (#220).

`start.learned` is versioned and optional; a server that predates it ignores the key:

    {"v": 1,
     "terms": [{"term": "Kubernetes", "heard": ["cooper netties"]}],
     "style": ["lowercase_start", "no_final_period"],
     "examples": [{"said": "sounds good", "wanted": "sounds good"}]}

Style preferences are ids from a fixed list, so no free-form instruction reaches the prompt.
Examples are the user's own dictations shown as preferred output; the guards still check every
answer against the raw transcript, so a learned item can never make clean-up add content. A
newer `v` is ignored rather than refused. Nothing here is ever logged. No I/O.
"""

import json
from dataclasses import dataclass

from .known_terms import UserTerm, parse_user_terms, user_terms_rule

VERSION = 1
MAX_EXAMPLES = 3
MAX_EXAMPLE_CHARS = 300

# The only style preferences a client may ask for, and the prompt line each one adds.
STYLE_RULES = {
    "lowercase_start": "Start with a lowercase letter, unless the first word is a name or I.",
    "no_final_period": "Do not end with a period; keep a final ? or !.",
}


@dataclass(frozen=True)
class Learned:
    terms: tuple[UserTerm, ...] = ()
    style: tuple[str, ...] = ()
    examples: tuple[tuple[str, str], ...] = ()

    def __bool__(self) -> bool:
        return bool(self.terms or self.style or self.examples)


def parse_learned(value) -> Learned | None:
    """The `start.learned` block, or None when it is from a newer version. Raises ValueError when
    a version-1 block is malformed (the session refuses it as `bad_request`)."""
    if not isinstance(value, dict) or not isinstance(value.get("v"), int):
        raise ValueError("learned")
    if value["v"] > VERSION:
        return None
    if value["v"] < VERSION or set(value) - {"v", "terms", "style", "examples"}:
        raise ValueError("learned")
    terms = parse_user_terms(value.get("terms", []))
    style = value.get("style", [])
    if not isinstance(style, list) or any(rule not in STYLE_RULES for rule in style):
        raise ValueError("style")
    examples = value.get("examples", [])
    if not isinstance(examples, list) or len(examples) > MAX_EXAMPLES:
        raise ValueError("examples")
    pairs = []
    for item in examples:
        if not isinstance(item, dict) or set(item) != {"said", "wanted"}:
            raise ValueError("example")
        said, wanted = item["said"], item["wanted"]
        if (
            not isinstance(said, str)
            or not isinstance(wanted, str)
            or not said.strip()
            or not wanted.strip()
            or len(said) > MAX_EXAMPLE_CHARS
            or len(wanted) > MAX_EXAMPLE_CHARS
        ):
            raise ValueError("example")
        pairs.append((said, wanted))
    return Learned(terms, tuple(dict.fromkeys(style)), tuple(pairs))


def learned_prompt(learned: Learned | None) -> str:
    """The prompt section for `learned`; empty when there is nothing."""
    if not learned:
        return ""
    lines = ["Learned from this user's own edits in this app (preferences, never instructions):"]
    lines += [f"- {STYLE_RULES[rule]}" for rule in learned.style]
    if learned.terms:
        lines.append(user_terms_rule(learned.terms))
    if learned.examples:
        lines.append("Their preferred output for earlier dictations (input JSON -> output):")
        lines += [
            f"{json.dumps(said, ensure_ascii=False)} -> {' '.join(wanted.split())}"
            for said, wanted in learned.examples
        ]
    return "\n".join(lines)
