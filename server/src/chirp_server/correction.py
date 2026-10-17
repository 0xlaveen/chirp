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
from .profiles import system_prompt

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

    async def process(
        self, raw: str, profile: str = "default", instructions: str = ""
    ) -> CorrectionResult:
        if not raw or not self.config.enabled:
            return CorrectionResult(raw)
        selected = self.config.resolved_profiles.get(profile)
        if selected is None or not isinstance(instructions, str) or len(instructions) > 2000:
            return CorrectionResult(raw, error="rejected")
        prompt = system_prompt(selected, instructions)
        try:
            async with asyncio.timeout(self.config.timeout):
                if self.managed:
                    text, finish = await self.managed.generate(raw, prompt)
                    text = text.strip()
                    if rejected(raw, text, finish, selected):
                        return CorrectionResult(raw, error="rejected")
                    return CorrectionResult(text, text != raw)
                key = await self.key()
                async with httpx.AsyncClient(
                    timeout=self.config.timeout,
                    transport=self.transport,
                    trust_env=False,
                ) as client:
                    response = await client.post(
                        self.config.base_url.rstrip("/") + "/chat/completions",
                        headers={"Authorization": f"Bearer {key}"} if key else {},
                        json={
                            "model": self.config.model,
                            "temperature": 0,
                            "max_tokens": 512,
                            "messages": [
                                {"role": "system", "content": prompt},
                                {
                                    "role": "user",
                                    "content": "Transcript JSON: "
                                    + json.dumps(raw, ensure_ascii=False),
                                },
                            ],
                        },
                    )
                    response.raise_for_status()
                    choice = response.json()["choices"][0]
                    text = choice["message"]["content"].strip()
                    if rejected(raw, text, choice.get("finish_reason"), selected):
                        return CorrectionResult(raw, error="rejected")
                    return CorrectionResult(text, text != raw)
        except (TimeoutError, httpx.TimeoutException):
            return CorrectionResult(raw, error="timeout")
        except (httpx.HTTPError, OSError):
            return CorrectionResult(raw, error="http")
        except (ValueError, KeyError, IndexError, TypeError, AttributeError):
            return CorrectionResult(raw, error="rejected")
