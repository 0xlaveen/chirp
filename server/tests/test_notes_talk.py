"""Structuring guards on long, ASR-mangled talks (`notes_talk_eval.jsonl`, invented): false
positives found on real Qwen output, and the inventions that must still fail."""

import json
from pathlib import Path

from chirp_server import notes

TALK = (
    "so the castrel gym thing, um, we added the api docs last week. the first customer was a "
    "small fund with like three hundred million under management. we decided to kill the voice "
    "version because no one was using it, and it still doesn't feel proactive enough."
)


def reason(markdown, outline=()):
    return notes.rejection_reason(TALK, markdown, "stop", list(outline))


def test_the_outline_supplies_names():
    markdown = "## SDK Docs And Cuts\n- Added the api docs last week"
    assert reason(markdown) == "name"
    assert reason(markdown, ["SDK Docs And Cuts"]) is None


def test_a_bold_phrase_opening_a_line_is_sentence_case():
    assert reason("## Voice\n- **Decided to kill** the voice version; no one was using it") is None
    assert reason("## Voice\n- **Sarah** killed the voice version; no one was using it") == "name"
    assert reason("## Voice\n- **Decided with Sarah** to kill the voice version") == "name"


def test_an_abbreviated_scale_reads_as_the_spoken_value():
    assert reason("## Customers\n- First customer: small fund (~$300M under management)") is None
    assert reason("## Customers\n- First customer: small fund (~$400M under management)") == (
        "number"
    )
    assert reason("## Customers\n- First customer: small fund, 300 people") == "number"


def test_misheard_names_stay_as_transcribed():
    assert reason("## Castrel Gym\n- Added the api docs last week") is None
    # A "corrected" spelling is a name the speaker never said.
    assert reason("## Kestrel Gym\n- **Kestrel** added the api docs last week") == "name"
    assert "Spell names exactly as transcribed" in notes.notes_system_prompt()


def test_talk_eval_set_shape():
    path = Path(__file__).with_name("notes_talk_eval.jsonl")
    entries = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
    assert len(entries) == 20
    for entry in entries:
        assert set(entry) == {"id", "segments", "outline", "keywords"}
        window = "\n".join(entry["segments"])
        assert 1600 <= len(window) <= 3600, entry["id"]
        notes.validate_request({"transcript": window, "outline": entry["outline"]})
        assert all(word.lower() in window.lower() for word in entry["keywords"]), entry["id"]
