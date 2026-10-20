"""Koi cleanup contract: final text only, fail closed to the original transcript."""

import asyncio
import json
import os
import re
from collections import Counter
from dataclasses import dataclass

import httpx

from .config import CorrectionConfig
from .managed_cleanup import ManagedCleanup
from .profiles import DEFAULT_PROMPT as DEFAULT_PROMPT
from .profiles import LIVE_NOTES_ID, MAX_PROMPT_CHARS, system_prompt

OPENERS = (
    "sure",
    "certainly",
    "of course",
    "here's",
    "here is",
    "the answer",
    "as an ai",
    "i can help",
    "i'd be happy",
    "great question",
)


@dataclass(frozen=True)
class CorrectionResult:
    text: str
    corrected: bool = False
    error: str | None = None


def rejected(raw: str, text: str, finish, profile=None) -> bool:
    if not text or finish not in {"stop", "eos"}:
        return True
    if any(
        marker in text.lower() for marker in ("<think>", "</think>", "```", "cleaned transcript:")
    ):
        return True
    if text.endswith(("...", "…")) and not raw.rstrip().endswith(("...", "…")):
        return True
    if (
        raw.lower().startswith(text.lower())
        and len(raw) - len(text) > 8
        and not text.endswith((".", "!", "?"))
    ):
        return True
    if len(text) > max(len(raw) * 2.5, len(raw) + 200):
        return True
    source = re.sub(r"^(?:(?:um|uh|er|ah|like|you know)[\s,]+)+", "", raw.lower())
    if any(text.lower().startswith(op) and not source.startswith(op) for op in OPENERS):
        return True
    if profile and profile.id == LIVE_NOTES_ID:
        return not notes_faithful(raw, text)
    if profile and profile.rewrites:
        return not rewrite_faithful(raw, text)
    if profile and profile.id == "code":
        return not code_faithful(raw, text)
    return not faithful(raw, text)


# Only these bounded value repairs may bypass word retention. Ambiguous repairs
# fail closed rather than giving a generic deletion budget to unrelated clauses.
VALUE_GROUPS = [
    set("monday tuesday wednesday thursday friday saturday sunday".split()),
    set(
        (
            "january february march april may june july august september october november december"
        ).split()
    ),
    set(
        "zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen "
        "fifteen sixteen seventeen eighteen nineteen twenty thirty forty fifty sixty seventy "
        "eighty ninety hundred thousand".split()
    ),
]
WORD = re.compile(r"\w+(?:['’]\w+)*", re.UNICODE)
REPAIR = re.compile(r"\b(?:no wait(?:[\s,]+make that)?|i mean|actually[\s,]+make that)\b", re.I)


def same_value_kind(before: str, after: str) -> bool:
    left, right = before.casefold(), after.casefold()
    return (
        any(left in group and right in group for group in VALUE_GROUPS)
        or (left.isdecimal() and right.isdecimal())
        or (before[0].isupper() and after[0].isupper())
    )


def faithful(raw: str, text: str) -> bool:
    """Accept only ordered source words, with narrowly licensed deletions.

    Unlike a percentage cutoff this catches a single missing 'not' in a long input.
    No semantic guarantee is possible for arbitrary punctuation or ambiguous speech.
    """
    matches = list(WORD.finditer(raw))
    source = [match.group().casefold().replace("’", "'") for match in matches]
    target = [match.group().casefold().replace("’", "'") for match in WORD.finditer(text)]
    optional = {i for i, word in enumerate(source) if word in {"um", "uh", "er"}}
    for i, word in enumerate(source):
        if i == 0 and word == "so":
            optional.add(i)
        if word == "like" and (
            i == 0
            or source[i - 1] in {"and", "but"}
            or (i + 1 < len(source) and source[i + 1] in {"um", "uh", "er"})
        ):
            optional.add(i)
        if (
            source[i : i + 2] == ["you", "know"]
            and i
            and source[i - 1] in {"should", "could", "would", "can", "will", "we're", "it's"}
        ):
            optional.update((i, i + 1))
        if (
            i
            and word == source[i - 1]
            and word
            in {"i", "we", "you", "he", "she", "it", "they", "the", "a", "an", "to", "and", "of"}
            and raw[matches[i - 1].end() : matches[i].start()].isspace()
        ):
            optional.add(i - 1)
    for repair in REPAIR.finditer(raw):
        indices = [
            i for i, match in enumerate(matches) if repair.start() <= match.start() < repair.end()
        ]
        if not indices:
            continue
        first, last = indices[0], indices[-1]
        if (
            first
            and last + 1 < len(matches)
            and same_value_kind(matches[first - 1].group(), matches[last + 1].group())
        ):
            optional.update(range(first - 1, last + 1))

    # Optional words may also be retained. Alignment preserves order and multiplicity;
    # a set-overlap guard cannot distinguish 'I do not agree' from 'I do agree'.
    reachable = {0}
    for i, word in enumerate(source):
        reachable = {
            following
            for j in reachable
            for following in (
                ([j] if i in optional else [])
                + ([j + 1] if j < len(target) and word == target[j] else [])
            )
        }
        if not reachable:
            return False
    if len(target) not in reachable:
        return False

    return protected_fragments(raw, text)


# --- Live Notes segments ---------------------------------------------------------------------
# Long-form speech is full of fillers, stutters and restarts that dictation rarely has. The
# guard still allows deletions only, in order, and only of these words, of a phrase spoken
# twice in a row, or of a short restart; casing and punctuation are free.

HESITATIONS = frozenset("um uh er erm uhm ah eh hmm hm mm mhm".split())
SPOKEN_FILLERS = HESITATIONS | frozenset(
    "oh like yeah yep yes okay ok so well basically actually literally right just anyway".split()
)
FILLER_PHRASES = (("you", "know"), ("i", "mean"), ("kind", "of"), ("sort", "of"))
NUMBER_WORDS = frozenset(word for group in VALUE_GROUPS[2:] for word in group) | {"million"}
NEGATION_WORDS = frozenset(
    "not no never nothing nobody none nor neither cannot can't don't doesn't didn't won't "
    "isn't aren't wasn't weren't shouldn't couldn't wouldn't haven't hasn't hadn't mustn't "
    "without".split()
)
# Grammar words a restart may drop without losing content ("that can be, something that").
FUNCTION_WORDS = frozenset(
    "i me my we us our you your he him his she her it its they them their this that these those "
    "a an the and or but if then than as of to in on at by for with from about into "
    "is are was were be been being am do does did have has had will would can could should "
    "shall may might must i'm i've i'd i'll we're we've we'd we'll you're you've it's that's "
    "there there's here what which who how when where why".split()
)
MAX_REPEAT = 4
MAX_RESTART = 5


def _protected(word: str) -> bool:
    return word in NUMBER_WORDS or word in NEGATION_WORDS or any(char.isdigit() for char in word)


def repeated_phrases(words: list[str]) -> set[int]:
    """Positions of the first copy of a phrase (1-4 words) said twice in a row."""
    found = set()
    for size in range(1, MAX_REPEAT + 1):
        for i in range(len(words) - 2 * size + 1):
            phrase = words[i : i + size]
            # "twenty twenty six" is a number, not a stutter; "one of the, one of the" is.
            if phrase == words[i + size : i + 2 * size] and not all(
                word in NUMBER_WORDS or any(char.isdigit() for char in word) for word in phrase
            ):
                found.update(range(i, i + size))
    return found


def abandoned_restarts(words: list[str]) -> set[int]:
    """Positions of a short restart: the speaker begins again with the same word, and every
    dropped word is a grammar word or is said again right after. No negation or number."""
    found = set()
    for i, first in enumerate(words):
        for size in range(2, MAX_RESTART + 1):
            if i + size >= len(words) or words[i + size] != first:
                continue
            span = words[i : i + size]
            following = set(words[i + size : i + 2 * size + 3])
            if not any(_protected(word) for word in span) and all(
                word in FUNCTION_WORDS or word in following for word in span
            ):
                found.update(range(i, i + size))
    return found


# "the list is, uh, it's actually nice": the speaker restates the subject after the verb.
RESTATED_SUBJECTS = frozenset("it's that's they're he's she's we're there's".split())
COPULAS = frozenset("is are was were".split())
ARTICLES = frozenset("a an the".split())
# "it's just, it's not the same", "there's only, there's six": either copy of the subject may go.
SUBJECT_GAP = 2


def restated_subjects(words: list[str]) -> set[int]:
    found = {
        i for i in range(1, len(words)) if words[i] in RESTATED_SUBJECTS and words[i - 1] in COPULAS
    }
    for i, word in enumerate(words):
        if word not in RESTATED_SUBJECTS:
            continue
        for gap in range(SUBJECT_GAP + 1):
            between = words[i + 1 : i + 1 + gap]
            if (
                i + 1 + gap < len(words)
                and words[i + 1 + gap] == word
                and not any(_protected(other) for other in between)
            ):
                found.add(i + 1 + gap)
    # "we're going to do a, an actual launch": an article the speaker swaps for another.
    found.update(
        i
        for i in range(len(words) - 1)
        if words[i] in ARTICLES and words[i + 1] in ARTICLES and words[i] != words[i + 1]
    )
    return found


# "the second screen is where hal sion, sorry, halcyon talks": a few words the speaker takes back
# with "sorry", and the marker itself. Never an apology ("I'm sorry", "sorry about that").
REPAIR_SPAN = 4
APOLOGY_BEFORE = frozenset("i'm im am so very really was were feel be".split())
APOLOGY_AFTER = frozenset("for about to that but if i we you".split())


def repaired_spans(words: list[str]) -> set[int]:
    found = set()
    for i, word in enumerate(words):
        if word != "sorry" or i == 0 or words[i - 1] in APOLOGY_BEFORE:
            continue
        if i + 1 >= len(words) or words[i + 1] in APOLOGY_AFTER:
            continue
        span = range(max(0, i - REPAIR_SPAN), i)
        if not any(_protected(words[j]) for j in span):
            found.update(span)
            found.add(i)
    return found


def _notes_words(raw: str) -> tuple[list, list[str], set[int]]:
    """(matches, words, optional positions) of a Live Notes segment: the words the clean-up may
    delete are fillers, filler phrases, a sentence's leading "and", repeats and restarts."""
    matches = list(WORD.finditer(raw))
    source = [match.group().casefold().replace("’", "'") for match in matches]
    optional = {i for i, word in enumerate(source) if word in SPOKEN_FILLERS}
    phrases = set()
    for i in range(len(source) - 1):
        if tuple(source[i : i + 2]) in FILLER_PHRASES:
            phrases.update((i, i + 1))
    optional |= phrases
    # A sentence may drop its leading "and" ("Oh, and the demo moved" -> "The demo moved").
    for i, word in enumerate(source):
        if word != "and":
            continue
        before = i - 1
        while before >= 0 and source[before] in SPOKEN_FILLERS:
            before -= 1
        if before < 0 or re.search(
            r"[.!?]", raw[matches[before].end() : matches[before + 1].start()]
        ):
            optional.add(i)
    # Repeats and restarts are found with fillers skipped: "we have, uh, we have", "a kind of a".
    core = [i for i, word in enumerate(source) if word not in SPOKEN_FILLERS and i not in phrases]
    words = [source[i] for i in core]
    found = (
        repeated_phrases(words)
        | abandoned_restarts(words)
        | restated_subjects(words)
        | repaired_spans(words)
    )
    optional.update(core[i] for i in found)
    return matches, source, optional


def notes_faithful(raw: str, text: str) -> bool:
    """`text` is `raw` with only fillers, repeats and restarts deleted, in order, none added."""
    _, source, optional = _notes_words(raw)
    target = [match.casefold().replace("’", "'") for match in WORD.findall(text)]
    reachable = {0}
    for i, word in enumerate(source):
        reachable = {
            following
            for j in reachable
            for following in (
                ([j] if i in optional else [])
                + ([j + 1] if j < len(target) and word == target[j] else [])
            )
        }
        if not reachable:
            return False
    return len(target) in reachable and protected_fragments(raw, text)


# The model drops "I think" before a number although the prompt says to keep it (docs/bench.md).
# Deleting a hedge changes how sure the speaker was, so it is never licensed; instead the
# clean-up puts the hedge back where it was and the result must pass `notes_faithful` as is.
HEDGE_PHRASES = frozenset({("i", "think"), ("i", "guess"), ("i'd", "say")})


def restore_hedges(raw: str, text: str) -> str | None:
    """`text` with the hedges it dropped put back, when that is its only unlicensed edit."""
    matches, source, optional = _notes_words(raw)
    targets = list(WORD.finditer(text))
    target = [match.group().casefold().replace("’", "'") for match in targets]
    hedges = {i for i in range(len(source) - 1) if tuple(source[i : i + 2]) in HEDGE_PHRASES}
    # Breadth-first over (source, target) positions, fewest restored hedges first.
    frontier, seen = [(0, 0, ())], set()
    while frontier:
        following = []
        for i, j, restored in frontier:
            if (i, j) in seen:
                continue
            seen.add((i, j))
            if i == len(source):
                if j == len(target):
                    if not restored:
                        return None  # already faithful: nothing to restore
                    return _insert_hedges(raw, text, matches, targets, restored)
                continue
            if i in optional:
                frontier.append((i + 1, j, restored))
            if j < len(target) and source[i] == target[j]:
                frontier.append((i + 1, j + 1, restored))
            if i in hedges:
                following.append((i + 2, j, (*restored, (j, i))))
        frontier = following
    return None


def _insert_hedges(raw, text, matches, targets, restored) -> str:
    for j, i in sorted(restored, reverse=True):
        phrase = raw[matches[i].start() : matches[i + 1].end()]
        if j < len(targets):
            at = targets[j].start()
            text = text[:at] + phrase + " " + text[at:]
        else:
            text = text.rstrip(".!? ") + " " + phrase + text[len(text.rstrip(".!? ")) :]
    return text


def protected_fragments(raw: str, text: str) -> bool:
    # Word matching alone loses operators, decimal points and URL syntax.
    protected = re.findall(
        r"https?://[^\s]+|`[^`]+`|\b\w+\([^()\n]*\)|\b\w+_\w+\b|"
        r"\b\d+(?:[.:/-]\d+)+\b|[=+*/<>]",
        raw,
    )
    return all(fragment.rstrip(".,!?") in text for fragment in protected)


# Rewriting permits list formatting, not a generic semantic rewrite.
# A bag of words still preserves multiplicity, negation and all substantive details.
REWRITE_OPTIONAL = set("um uh er first second third then finally and".split())


def rewrite_faithful(raw: str, text: str) -> bool:
    source = Counter(word.casefold() for word in WORD.findall(raw))
    target = Counter(word.casefold() for word in WORD.findall(text))
    if not target or target - source:
        return False  # No novel words: this includes invented facts and answers.
    if any(word not in REWRITE_OPTIONAL for word in source - target):
        # Keep bounded conservative repairs available without broadly licensing deletion.
        return faithful(raw, text)
    if sum(target.values()) < max(1, sum(source.values()) * 0.5):
        return False
    # Keep substantive content in source order: reassigning an action to another
    # person or moving a negation can invent facts without introducing new words.
    remaining = iter(word.casefold() for word in WORD.findall(raw))
    if not all(
        any(candidate == word for candidate in remaining)
        for word in (word.casefold() for word in WORD.findall(text))
    ):
        return False
    return protected_fragments(raw, text)


def code_faithful(raw: str, text: str) -> bool:
    converted = raw
    # Filename/path/identifier fragments only; other ambiguous uses fail closed.
    for spoken, symbol in (("underscore", "_"),):
        converted = re.sub(rf"(?<=\w)\s+{spoken}\s+(?=\w)", symbol, converted, flags=re.I)
    converted = re.sub(
        r"(?<=\w)\s+dot\s+(?=(?:json|py|js|ts|tsx|jsx|toml|yaml|yml|md|txt|com|org|dev)\b)",
        ".",
        converted,
        flags=re.I,
    )
    if re.search(r"\b(?:path|directory|folder|https?)\b", raw, re.I):
        converted = re.sub(r"(?<=\w)\s+slash\s+(?=\w)", "/", converted, flags=re.I)
    converted = re.sub(r"\bdash\s+(?=[A-Za-z]\b)", "-", converted, flags=re.I)
    converted = re.sub(r"(?<=\w)\s+open paren\s*", "(", converted, flags=re.I)
    converted = re.sub(r"\s+close paren\b", ")", converted, flags=re.I)
    converted_fragments = re.findall(
        r"\b\w+(?:[./_]\w+)+|(?<!\w)-[A-Za-z]\b|\b\w+\([^()]*\)", converted
    )
    if not (
        (faithful(raw, text) and not (Counter(WORD.findall(text)) - Counter(WORD.findall(raw))))
        or (
            faithful(converted, text)
            and not (Counter(WORD.findall(text)) - Counter(WORD.findall(converted)))
            and all(part in text for part in converted_fragments)
        )
    ):
        return False
    # Literal code casing and symbols must survive, including leading command flags.
    identifiers = [
        word
        for word in WORD.findall(raw)
        if "_" in word or any(char.isupper() for char in word[1:])
    ]
    symbols = Counter(re.findall(r"[=+*/<>_()\[\]{}%&|~^:#@\\-]", raw))
    output_symbols = Counter(re.findall(r"[=+*/<>_()\[\]{}%&|~^:#@\\-]", text))
    return all(fragment in text for fragment in identifiers) and not (symbols - output_symbols)


class Corrector:
    def __init__(self, config: CorrectionConfig, transport=None):
        self.config = config
        self.transport = transport
        self.managed = ManagedCleanup(config) if config.mode == "managed" else None

    async def close(self):
        if self.managed:
            await self.managed.close()

    async def key(self):
        config = self.config
        value = os.environ.get(config.api_key_env, "")
        if value or not config.keychain_service:
            return value
        process = await asyncio.create_subprocess_exec(
            "security",
            "find-generic-password",
            "-s",
            config.keychain_service,
            "-w",
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL,
        )
        try:
            stdout, _ = await process.communicate()
            return stdout.decode().strip() if process.returncode == 0 else ""
        finally:
            if process.returncode is None:
                process.kill()
                await process.wait()

    async def complete(
        self,
        system: str,
        user: str,
        max_tokens: int,
        *,
        priority: str = "correction",
        timeout: float | None = None,  # noqa: ASYNC109 - the backend call's own budget
        legacy_text: str | None = None,
    ) -> tuple[str, str | None]:
        """One backend completion: (stripped text, finish reason). Raises the backend's own
        exceptions; callers map them to a safe error code and never log them.

        `legacy_text` is the correction transcript: the managed helper then builds the
        `Transcript JSON:` message itself, so correction requests are unchanged.
        """
        budget = timeout or self.config.timeout
        if self.managed:
            if legacy_text is not None:
                text, finish = await self.managed.generate(legacy_text, system)
            else:
                text, finish = await self.managed.generate(
                    "",
                    system,
                    user=user,
                    max_tokens=max_tokens,
                    timeout=budget,
                    priority=priority,
                )
            return text.strip(), finish
        key = await self.key()
        async with httpx.AsyncClient(
            timeout=budget,
            transport=self.transport,
            trust_env=False,
        ) as client:
            response = await client.post(
                self.config.base_url.rstrip("/") + "/chat/completions",
                headers={"Authorization": f"Bearer {key}"} if key else {},
                json={
                    "model": self.config.model,
                    "temperature": 0,
                    "max_tokens": max_tokens,
                    "messages": [
                        {"role": "system", "content": system},
                        {"role": "user", "content": user},
                    ],
                },
            )
            response.raise_for_status()
            choice = response.json()["choices"][0]
            return choice["message"]["content"].strip(), choice.get("finish_reason")

    async def process(
        self,
        raw: str,
        profile: str = "default",
        instructions: str = "",
        correction_prompt: str | None = None,
    ) -> CorrectionResult:
        if not raw or not self.config.enabled:
            return CorrectionResult(raw)
        selected = self.config.profile(profile)
        if (
            selected is None
            or not isinstance(instructions, str)
            or len(instructions) > 2000
            or (
                correction_prompt is not None
                and (
                    not isinstance(correction_prompt, str)
                    or len(correction_prompt) > MAX_PROMPT_CHARS
                )
            )
        ):
            return CorrectionResult(raw, error="rejected")
        prompt = system_prompt(selected, instructions, correction_prompt)
        if selected.id == LIVE_NOTES_ID:
            return await self._process_notes(raw, prompt, selected)
        try:
            async with asyncio.timeout(self.config.timeout):
                text, finish = await self.complete(
                    prompt,
                    "Transcript JSON: " + json.dumps(raw, ensure_ascii=False),
                    512,
                    legacy_text=raw,
                )
                if rejected(raw, text, finish, selected):
                    return CorrectionResult(raw, error="rejected")
                return CorrectionResult(text, text != raw)
        except (TimeoutError, httpx.TimeoutException):
            return CorrectionResult(raw, error="timeout")
        except (httpx.HTTPError, OSError):
            return CorrectionResult(raw, error="http")
        except (ValueError, KeyError, IndexError, TypeError, AttributeError):
            return CorrectionResult(raw, error="rejected")

    async def _process_notes(self, raw: str, prompt: str, selected) -> CorrectionResult:
        """A Live Notes segment: its own budget, and an output cap sized to the segment."""
        budget = self.config.notes_timeout
        try:
            async with asyncio.timeout(budget):
                text, finish = await self.complete(
                    prompt,
                    "Transcript JSON: " + json.dumps(raw, ensure_ascii=False),
                    notes_max_tokens(raw),
                    timeout=budget,
                )
                if rejected(raw, text, finish, selected):
                    restored = restore_hedges(raw, text) if finish in {"stop", "eos"} else None
                    if restored is None or rejected(raw, restored, finish, selected):
                        return CorrectionResult(raw, error="rejected")
                    text = restored
                return CorrectionResult(text, text != raw)
        except (TimeoutError, httpx.TimeoutException):
            return CorrectionResult(raw, error="timeout")
        except (httpx.HTTPError, OSError):
            return CorrectionResult(raw, error="http")
        except (ValueError, KeyError, IndexError, TypeError, AttributeError):
            return CorrectionResult(raw, error="rejected")


def notes_max_tokens(raw: str) -> int:
    # Deleting only never lengthens the text; English is about 4 characters per token.
    return min(1024, 64 + len(raw) // 2)
