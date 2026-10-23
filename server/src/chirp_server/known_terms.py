"""Known product terms for clean-up: prompt text, and the one respelling the guards license.

Recognition mishears a few domain words ("clawed code" for "Claude Code"). The prompts may fix
a word only when context makes it clearly a mishearing of a listed term; the guards accept
exactly the respellings `respell` makes and nothing else, so a free-form substitution is still
rejected. No I/O.
"""

import re

TERMS = (
    "Claude, Claude Code, Anthropic, Tailscale, GitHub, Koi, Chirp, Parakeet, Qwen, macOS, iOS, "
    "Android"
)

TERMS_RULE = f"""Known terms: {TERMS}.
Respell a word to a known term ONLY when context makes it clearly a mishearing: clawed code ->
Claude Code, thanks clawed -> thanks Claude. Never add a word: clawed alone
becomes Claude, not Claude Code. Otherwise change nothing: the cat clawed the sofa stays."""

# Examples in the prompt format of each style (input JSON string -> output text).
TERMS_EXAMPLES = (
    '"I asked clawed code to fix the test" -> I asked Claude Code to fix the test.',
    '"the cat clawed the sofa" -> The cat clawed the sofa.',
)

_WORD = r"(?<![\w'’-])"
_END = r"(?![\w'’-])"
_CLAUDE = r"(?:clawed|clawd|claud|clod)"
# Each rule needs its own context: a bare "clawed" is also a real verb ("the cat clawed the
# sofa"), so it is only Claude right after a verb of addressing someone, a greeting or thanks,
# or before "code".
RESPELLINGS = (
    (re.compile(rf"{_WORD}{_CLAUDE}\s+code{_END}", re.I), "Claude Code"),
    (
        re.compile(
            rf"{_WORD}(ask|asks|asked|asking|tell|tells|told|telling|ping|pinged|pinging|"
            rf"prompt|prompted|prompting|thanks|thank|hey|hi)(\s+){_CLAUDE}{_END}",
            re.I,
        ),
        r"\1\2Claude",
    ),
    (re.compile(rf"{_WORD}tail\s+scale{_END}", re.I), "Tailscale"),
    (re.compile(rf"{_WORD}get\s+hub{_END}", re.I), "GitHub"),
    (re.compile(rf"{_WORD}mac\s+OS{_END}"), "macOS"),
    (re.compile(rf"{_WORD}(?:kwen|quen)(?:\s*3(?:\.5)?)?{_END}", re.I), "Qwen"),
)


def respell(raw: str) -> str:
    """`raw` with the clearly-contextual known-term mishearings fixed; `raw` itself when none."""
    for pattern, term in RESPELLINGS:
        raw = pattern.sub(term, raw)
    return raw
