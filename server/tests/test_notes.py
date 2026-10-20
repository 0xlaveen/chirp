"""POST /v1/notes/structure: validation, guards, fail-closed mapping, priority and privacy.

All transcripts are synthetic. The managed path runs the real pipe supervision against
`fake_cleanup_helper.py`; no model is loaded outside the opt-in `model` test.
"""

import asyncio
import json
import logging
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import httpx
import pytest
from conftest import HEADERS, PCM, START, TOKEN
from starlette.testclient import TestClient
from test_protocol import final

from chirp_server import cleanup_worker, notes
from chirp_server.app import create_app
from chirp_server.cleanup_models import DEFAULT_MODEL, discover
from chirp_server.config import CorrectionConfig
from chirp_server.correction import Corrector
from chirp_server.engine import FakeEngine
from chirp_server.managed_cleanup import ManagedCleanup

HELPER = Path(__file__).with_name("fake_cleanup_helper.py")
COMMAND = [sys.executable, "-u", str(HELPER)]
URL = "/v1/notes/structure"
TRANSCRIPT = "the plan is to ship on friday and maya will send the draft spec"
MARKDOWN = "## Plan\n- Ship **Friday**"


def service(*extra, **kwargs):
    config = CorrectionConfig(mode="managed", **kwargs)
    corrector = Corrector(config)
    if "--reply-structure" not in extra:
        extra = (*extra, "--reply-structure", MARKDOWN)
    corrector.managed = ManagedCleanup(config, command=[*COMMAND, *extra])
    return corrector


def run(settings, corrector):
    return TestClient(create_app(settings, FakeEngine(), TOKEN, corrector=corrector))


def post(client, body, headers=HEADERS):
    return client.post(URL, headers=headers, json=body)


def read_log(path):
    return [json.loads(line) for line in Path(path).read_text().splitlines()]


def logged(path):
    try:
        return len(read_log(path))
    except FileNotFoundError:
        return 0


# --- auth, off, health ---------------------------------------------------------------------


@pytest.mark.parametrize("headers", [{}, {"Authorization": "Bearer wrong"}, {"Authorization": "x"}])
def test_auth(client, headers):
    response = post(client, {"transcript": "hello there"}, headers)
    assert response.status_code == 401
    assert response.headers["www-authenticate"] == "Bearer"
    assert response.json()["code"] == "auth"


def test_off_is_409(client):
    response = post(client, {"transcript": "hello there"})
    assert response.status_code == 409
    assert response.json() == {
        "type": "error",
        "code": "notes_off",
        "message": "Notes structuring needs correction enabled on the server",
    }


def test_health_advertises_structuring(client):
    assert client.get("/v1/health", headers=HEADERS).json()["notes_structure"] is True
    assert client.get("/v1/health").json() == {"ok": True}


# --- validation ----------------------------------------------------------------------------

VALID = {"transcript": TRANSCRIPT}
INVALID = {
    "non-object": [],
    "string": "hello",
    "unknown key": {**VALID, "mode": "summary"},
    "missing transcript": {"outline": []},
    "empty transcript": {"transcript": "  \n "},
    "non-string transcript": {"transcript": 5},
    "too long": {"transcript": "a" * 6001},
    "outline not list": {**VALID, "outline": "Plan"},
    "outline not strings": {**VALID, "outline": ["Plan", 3]},
    "too many items": {**VALID, "outline": ["a"] * 25},
    "item too long": {**VALID, "outline": ["a" * 121]},
    "outline too long": {**VALID, "outline": ["a" * 100] * 16},
    "final not bool": {**VALID, "final": "yes"},
}


@pytest.mark.parametrize("body", INVALID.values(), ids=INVALID)
def test_invalid_requests_are_400(settings, body):
    with run(settings, service(timeout=1)) as client:
        response = post(client, body)
    assert response.status_code == 400
    assert response.json() == {
        "type": "error",
        "code": "bad_notes",
        "message": "Invalid notes request",
    }


@pytest.mark.parametrize(
    "content",
    [b"not json", b"\xff\xfe", b"", b"x" * (64 * 1024 + 1), b'{"transcript": "a"}' + b" " * 70000],
)
def test_bad_bodies_are_400(settings, content):
    with run(settings, service(timeout=1)) as client:
        response = client.post(URL, headers=HEADERS, content=content)
    assert response.status_code == 400 and response.json()["code"] == "bad_notes"


def test_limits_are_inclusive():
    transcript, outline, final = notes.validate_request(
        {"transcript": f"  {'a' * 6000}  ", "outline": ["a" * 60] * 24 + [], "final": True}
    )
    assert len(transcript) == 6000 and len(outline) == 24 and final is True
    assert notes.validate_request({"transcript": "x"}) == ("x", [], False)


# --- managed backend -----------------------------------------------------------------------


def test_managed_structures(settings, tmp_path):
    log = tmp_path / "requests.jsonl"
    corrector = service("--reply-structure", MARKDOWN, "--log", str(log), timeout=2)
    with run(settings, corrector) as client:
        response = post(client, {"transcript": TRANSCRIPT, "outline": ["Intro"], "final": True})
    body = response.json()
    assert response.status_code == 200
    assert body["markdown"] == MARKDOWN and body["structured"] is True and body["error"] is None
    assert body["timings_ms"]["structure"] > 0
    (request,) = read_log(log)
    assert request["kind"] == "structure" and request["max_tokens"] == 768
    assert request["user"].startswith("Notes JSON: ")
    assert json.loads(request["user"].removeprefix("Notes JSON: ")) == {
        "outline": ["Intro"],
        "transcript": TRANSCRIPT,
    }


def test_correction_requests_keep_their_shape(tmp_path):
    log = tmp_path / "requests.jsonl"

    async def go():
        corrector = service("--log", str(log))
        try:
            return await corrector.process("please send the schedule")
        finally:
            await corrector.close()

    assert asyncio.run(go()).corrected
    assert read_log(log)[0]["keys"] == ["system", "text"]


@pytest.mark.parametrize(
    "transcript,error",
    [("hang", "timeout"), ("crash", "rejected"), ("invalid", "rejected"), ("fail", "rejected")],
)
def test_managed_failures_fail_closed(settings, transcript, error):
    corrector = service(timeout=1, structure_timeout=1.5)
    with run(settings, corrector) as client:
        response = post(client, {"transcript": transcript})
        again = post(client, {"transcript": TRANSCRIPT})
    assert response.status_code == 200
    assert response.json()["markdown"] is None
    assert response.json()["structured"] is False and response.json()["error"] == error
    assert again.json()["structured"] is True  # the helper restarts after a failure


def test_guard_rejection_is_reported(settings):
    corrector = service("--reply-structure", "# Title\n- Ship Friday", timeout=2)
    with run(settings, corrector) as client:
        body = post(client, {"transcript": TRANSCRIPT}).json()
    assert body["structured"] is False and body["error"] == "rejected"


# --- endpoint backend ----------------------------------------------------------------------


def endpoint_corrector(handle):
    config = CorrectionConfig(mode="endpoint", base_url="http://127.0.0.1:1234/v1", timeout=2)
    return Corrector(config, httpx.MockTransport(handle))


def reply(content, finish="stop"):
    return httpx.Response(
        200, json={"choices": [{"message": {"content": content}, "finish_reason": finish}]}
    )


def test_endpoint_structures_with_the_notes_budget(settings):
    seen = []

    def handle(request):
        seen.append(json.loads(request.content))
        return reply(MARKDOWN)

    with run(settings, endpoint_corrector(handle)) as client:
        body = post(client, {"transcript": TRANSCRIPT}).json()
    assert body["structured"] is True and body["markdown"] == MARKDOWN
    (sent,) = seen
    assert sent["max_tokens"] == 768 and sent["temperature"] == 0
    assert sent["messages"][0]["content"] == notes.notes_system_prompt()
    assert sent["messages"][1]["content"].startswith("Notes JSON: ")


@pytest.mark.parametrize(
    "handle,error,reason",
    [
        (lambda request: httpx.Response(500), "http", None),
        (lambda request: reply("# Title\n- Ship Friday"), "rejected", "forbidden"),
        (lambda request: reply(MARKDOWN, "length"), "rejected", "finish"),
        (lambda request: httpx.Response(200, json={"unexpected": True}), "rejected", None),
    ],
)
def test_endpoint_failures_fail_closed(settings, handle, error, reason):
    with run(settings, endpoint_corrector(handle)) as client:
        body = post(client, {"transcript": TRANSCRIPT}).json()
    assert body == {
        "markdown": None,
        "structured": False,
        "error": error,
        "reason": reason,
        "timings_ms": {"structure": pytest.approx(body["timings_ms"]["structure"])},
    }


def test_endpoint_timeout(settings):
    async def slow(request):
        await asyncio.sleep(1)
        return reply(MARKDOWN)

    config = CorrectionConfig(
        mode="endpoint", base_url="http://127.0.0.1:1234/v1", timeout=2, structure_timeout=0.1
    )
    corrector = Corrector(config, httpx.MockTransport(slow))
    with run(settings, corrector) as client:
        assert post(client, {"transcript": TRANSCRIPT}).json()["error"] == "timeout"


def test_structure_timeout_is_validated():
    for bad in (0, -1, float("nan"), float("inf")):
        with pytest.raises(ValueError):
            CorrectionConfig(mode="managed", structure_timeout=bad)
    assert CorrectionConfig(mode="managed").structure_timeout == 30.0


# --- concurrency ---------------------------------------------------------------------------


async def test_second_concurrent_request_is_busy(settings):
    corrector = service("--slow-structure", "0.5")
    app = create_app(settings, FakeEngine(), TOKEN, corrector=corrector)
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t") as c:
        first = asyncio.create_task(c.post(URL, headers=HEADERS, json={"transcript": TRANSCRIPT}))
        await asyncio.sleep(0.15)
        second = await c.post(URL, headers=HEADERS, json={"transcript": TRANSCRIPT})
        assert second.status_code == 503
        assert second.json() == {
            "type": "error",
            "code": "busy",
            "message": "Speech engine busy; retry shortly",
        }
        assert (await first).status_code == 200
        # The lock is released afterwards.
        assert (
            await c.post(URL, headers=HEADERS, json={"transcript": TRANSCRIPT})
        ).status_code == 200
    await corrector.close()


async def wait_for(path, count, seconds=10):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if logged(path) >= count:
            return
        await asyncio.sleep(0.02)
    raise AssertionError("helper did not receive the request")


async def test_corrections_overtake_queued_structuring(tmp_path):
    log = tmp_path / "requests.jsonl"
    corrector = service("--slow-structure", "0.5", "--log", str(log), timeout=8)
    try:
        first = asyncio.create_task(notes.structure(corrector, TRANSCRIPT, []))
        await wait_for(log, 1)  # the first pass is running inside the helper
        second = asyncio.create_task(notes.structure(corrector, TRANSCRIPT + " again", []))
        await asyncio.sleep(0.05)
        correction = asyncio.create_task(corrector.process("please send the schedule"))
        results = await asyncio.gather(first, second, correction)
        assert all(result is not None for result in results)
        assert results[0].structured and results[1].structured and results[2].corrected
        assert [entry["kind"] for entry in read_log(log)] == [
            "structure",
            "correction",
            "structure",
        ]
    finally:
        await corrector.close()


async def test_priority_counter_recovers_after_cancellation(tmp_path):
    log = tmp_path / "requests.jsonl"
    corrector = service("--slow-structure", "1.0", "--log", str(log), timeout=8)
    managed = corrector.managed
    try:
        running = asyncio.create_task(notes.structure(corrector, TRANSCRIPT, []))
        await wait_for(log, 1)
        waiting = asyncio.create_task(corrector.process("please send the schedule"))
        await asyncio.sleep(0.05)
        waiting.cancel()
        with pytest.raises(asyncio.CancelledError):
            await waiting
        assert managed.waiting == 0 and managed.no_waiting.is_set()
        assert (await running).structured
        assert (await notes.structure(corrector, TRANSCRIPT, [])).structured
    finally:
        await corrector.close()


def test_structuring_does_not_hold_the_engine_lease(settings):
    corrector = service("--slow-structure", "1.0", timeout=8)
    with run(settings, corrector) as client, ThreadPoolExecutor(1) as pool:
        pending = pool.submit(post, client, {"transcript": TRANSCRIPT})
        time.sleep(0.4)
        with client.websocket_connect("/v1/stream", headers=HEADERS) as ws:
            ws.send_json(START)
            assert ws.receive_json()["type"] == "ready"
            ws.send_bytes(PCM)
            ws.send_json({"type": "stop"})
            assert final(ws)["type"] == "final"
        assert not pending.done()  # still structuring while the utterance completed
        assert pending.result(timeout=10).json()["structured"] is True


# --- privacy -------------------------------------------------------------------------------


def test_structuring_writes_nothing_and_logs_no_text(settings, tmp_path, caplog):
    settings.debug_retain = True
    sentinel = "zyxwvu quixotic marmalade"
    corrector = service("--reply-structure", f"## Plan\n- Ship {sentinel}", timeout=2)
    caplog.set_level(logging.DEBUG)
    with run(settings, corrector) as client:
        before = {path for path in tmp_path.rglob("*")}
        body = post(
            client, {"transcript": f"ship {sentinel}", "outline": ["Secret heading"]}
        ).json()
        assert body["structured"] is True
        assert {path for path in tmp_path.rglob("*")} == before
    assert not list(settings.debug_dir.rglob("*.wav")) and not list(
        settings.debug_dir.rglob("*.json")
    )
    assert "notes_structure chars=" in caplog.text
    for secret in (sentinel, "zyxwvu", "Secret heading", "Ship"):
        assert secret not in caplog.text


# --- output guards -------------------------------------------------------------------------

GOOD = (
    "okay so the launch is moving to march third and we decided to keep the vendor contract. "
    "maya will send the draft spec by friday. we will not hire a contractor this quarter. "
    "who owns QA though"
)
GOOD_MD = (
    "## Launch plan\n"
    "- Launch moved to **March 3**\n"
    "- **Decision:** keep the vendor contract\n"
    "- [ ] **Maya** to send the draft spec by **Friday**\n"
    "- We will **not** hire a contractor this quarter\n"
    "- **Question:** who owns QA?"
)


def rejected(markdown, transcript=GOOD, finish="stop"):
    return notes.notes_rejected(transcript, markdown, finish)


def test_faithful_notes_are_accepted():
    assert not rejected(GOOD_MD)
    plain = "the launch is moving to march third and we decided to keep the vendor contract"
    assert not rejected("- Launch moved\n  - to March 3", plain)
    assert not rejected("## Budget and vendor\n- keep the vendor contract", plain)
    assert not rejected("keep the vendor contract", plain)  # a plain paragraph line
    assert not rejected(notes.PLACEHOLDER)
    assert not rejected(notes.PLACEHOLDER, "um uh")
    assert not rejected(GOOD_MD, finish="eos")


def test_prompt_examples_pass_their_own_guards():
    for outline, transcript, markdown in notes.EXAMPLES:
        assert not rejected(markdown, transcript)
        assert notes.notes_user_message(outline, transcript) in notes.NOTES_STYLE


@pytest.mark.parametrize(
    "markdown,finish",
    [
        ("", "stop"),
        ("   ", "stop"),
        (GOOD_MD, "length"),
        (GOOD_MD, None),
        ("# Launch\n- keep the vendor contract", "stop"),  # H1
        ("## Launch\n```\nkeep the vendor contract\n```", "stop"),
        ("<think>hmm</think>\n- keep the vendor contract", "stop"),
        ("## Launch\n| a | b |\n|---|---|", "stop"),
        ("- see [the vendor](http://example.com) contract", "stop"),
        ("- ![vendor](x) contract", "stop"),
        ("Sure, here are the notes\n- keep the vendor contract", "stop"),
        ("Here is the summary\n- keep the vendor contract", "stop"),
        ("## Launch\n- invented quarterly synergy roadmap review process meeting", "stop"),
        ("- Launch moved to **March 4**", "stop"),  # invented number
        ("- We will hire a contractor this quarter", "stop"),  # dropped negation
        ("- keep the vendor contract " * 40, "stop"),  # length overflow
        ("## One two three four five six seven\n- keep the vendor contract", "stop"),
        ("* keep the vendor contract", "stop"),  # bad bullet marker
        ("1. keep the vendor contract", "stop"),  # ordered list
        ("> keep the vendor contract", "stop"),
        ("    - keep the vendor contract", "stop"),  # too deeply nested
        ("#### Launch\n- keep the vendor contract", "stop"),
        ("  keep the vendor contract", "stop"),  # indented paragraph
    ],
)
def test_bad_outputs_are_rejected(markdown, finish):
    assert rejected(markdown, finish=finish)


def test_openers_are_allowed_when_spoken():
    assert not notes.notes_rejected("sure we should ship", "Sure we should ship", "stop")
    assert notes.notes_rejected("we should ship", "Sure we should ship", "stop")


def test_overlap_floor_allows_paraphrase_but_not_an_unrelated_answer():
    transcript = (
        "the settings page isn't clear and the the save button is way at the bottom so you "
        "have to scroll. also there are two places for notification settings"
    )
    paraphrase = (
        "## Settings\n- Settings page lacks clarity\n- **Issue:** save button only visible "
        "after scrolling\n- Notification settings duplicated in two places"
    )
    assert not rejected(paraphrase, transcript)
    answer = "- Rendering pipelines benefit from memoization, caching layers and lazy hydration"
    assert notes.rejection_reason(transcript, answer, "stop") == "novel"
    # Short outputs are left to the other guards: too few words to measure overlap.
    assert not rejected("- Duplicated notification toggles", transcript)


def test_negation_flip_is_rejected():
    transcript = "we will not ship on friday"
    assert notes.rejection_reason(transcript, "- Ship on Friday", "stop") == "negation"
    assert rejected("- [ ] Ship on Friday", transcript)
    assert rejected("- **Decision:** ship on Friday", transcript)
    assert not rejected("- We will not ship on Friday", transcript)
    assert not rejected("- Not shipping Friday", transcript)
    assert not rejected("- **Decision:** no Friday ship", transcript)
    # Each negated clause is checked on its own, also after a conjunction or condition.
    both = "we cannot ship and we will never go"
    assert rejected("- Cannot ship\n- Will go", both)
    assert not rejected("- Cannot ship\n- Will never go", both)
    dark = "we are not doing dark mode until the design system is done"
    assert rejected("- Doing dark mode this sprint", dark)
    assert not rejected("- Dark mode waits for the design system", dark)


def test_incidental_negations_may_be_left_out():
    transcript = (
        "I don't know whether it supports the locale or not. I didn't really have any problems "
        "with the email sign in, it worked. Brightline can't do the custom firmware and we need "
        "the custom firmware for the warehouse"
    )
    notes_md = (
        "- [ ] Check whether it supports the locale\n"
        "- Email sign in worked\n"
        "- Brightline **cannot** do custom firmware\n"
        "- Custom firmware needed for the warehouse integration"
    )
    assert not rejected(notes_md, transcript)
    # Negative wording counts as negated: "unclear" for "not clear", "lacks", a question.
    unclear = "the pricing page is not clear about the enterprise tier"
    assert not rejected("- Pricing page unclear about the enterprise tier", unclear)
    assert not rejected("- Pricing page lacks detail on the enterprise tier", unclear)
    assert not rejected("- **Question:** is the pricing page clear on enterprise?", unclear)
    assert rejected("- Pricing page clear about the enterprise tier", unclear)
    # A to-do for something not done yet is the to-do, not a flip.
    assert not rejected("- [ ] Call the caterer", "I haven't called the caterer yet")
    assert rejected("- Called the caterer", "I haven't called the caterer yet")


def test_non_negating_idioms_are_not_flips():
    reminder = "we can ship friday. also don't forget to call the caterer. no worries about it"
    assert not rejected("- Ship Friday\n- [ ] Call the caterer", reminder)
    assert not rejected("- [ ] Check whether it works", "check whether it works or not")
    assert rejected("- Ship Friday", "we don't ship friday and don't forget the caterer")


def test_invented_names_are_rejected():
    transcript = "maya will send the spec and the vendor is late. someone should call legal"
    assert not rejected("- [ ] **Maya** to send the spec\n- Vendor is late", transcript)
    assert not rejected("- [ ] Someone to call legal", transcript)
    for markdown in (
        "- [ ] **Sarah** to send the spec",  # bold, sentence-initial
        "- [ ] Sarah to send the spec",  # a to-do's owner
        "- Vendor Acme is late",  # mid-sentence capital
        "- Vendor is late; ask the QA team",  # an acronym
        "## SLA review\n- Vendor is late",  # an acronym in a heading
    ):
        assert notes.rejection_reason(transcript, markdown, "stop") == "name", markdown
    # Labels, Title Case headings, "I", "OK" and bold emphasis of spoken words are fine.
    assert not rejected(
        "## Vendor Status Review\n- **Blocker:** vendor is late\n- I think it's OK\n"
        "- **Not** sent yet: the spec",
        transcript + ". okay i think it's not sent yet",
    )


def test_invented_dates_and_contacts_are_rejected():
    transcript = "the demo moved to monday. email the vendor at sales@vendor.example"
    assert not rejected("- Demo moved to **Monday**\n- Email sales@vendor.example", transcript)
    assert notes.rejection_reason(transcript, "- Demo moved to Tuesday", "stop") == "date"
    assert notes.rejection_reason(transcript, "- Demo moved in june", "stop") == "date"
    for markdown in ("- Email ops@vendor.example", "- See www.vendor.com", "- See vendor.io"):
        assert notes.rejection_reason(transcript, markdown, "stop") == "contact", markdown


def test_number_words_in_the_notes_are_checked():
    transcript = "we have thirty two points and the billing item is thirteen"
    assert not rejected("- Thirty two points\n- Billing item: thirteen", transcript)
    assert rejected("- Thirty four points", transcript)
    assert rejected("- Billing item: eleven", transcript)
    # A lone "one" is a pronoun and ordinals are not counted; adjacent groups stay separate.
    assert not rejected("- Billing item is the big one, first in line", transcript)
    assert not rejected("- Cut to two, three cards", "cut it to two, maybe three cards")
    assert rejected("- Twenty one cards", "twenty cards")


def test_committed_structure_negatives_are_rejected_for_their_reason():
    cases = [
        json.loads(line)
        for line in Path(__file__).with_name("notes_negatives.jsonl").read_text().splitlines()
    ]
    structure = [case for case in cases if case["kind"] == "structure"]
    assert len(structure) >= 15
    assert {"name", "number", "negation", "novel", "contact"} <= {c["why"] for c in structure}
    for case in structure:
        reason = notes.rejection_reason(case["transcript"], case["output"], "stop")
        assert reason == case["why"], case["id"]


def test_messy_eval_set_shape():
    entries = [
        json.loads(line)
        for line in Path(__file__).with_name("notes_messy_eval.jsonl").read_text().splitlines()
    ]
    assert len(entries) >= 10 and len({entry["id"] for entry in entries}) == len(entries)
    for entry in entries:
        assert 600 <= len(entry["transcript"]) <= 2400, entry["id"]
        assert set(entry) == {"id", "outline", "transcript", "keywords"}
        assert all(word.lower() in entry["transcript"].lower() for word in entry["keywords"])


def test_numbers_match_digits_or_words():
    assert not rejected("- Budget is 25", "the budget is twenty five")
    assert not rejected("- Budget is **25**", "the budget is 25")
    assert not rejected("- Meet on the 3rd", "meet on the third")
    assert not rejected("- 1,000 users", "a thousand users")
    assert not rejected("- 2500 users", "two thousand five hundred users")
    assert not rejected("- 105 users", "one hundred and five users")
    assert not rejected("- Call at 3 30", "call at three thirty")
    assert not rejected("- Year 2026", "the year twenty twenty six")
    assert not rejected("- 3 or 5 items", "three or five items")
    assert rejected("- Budget is 5", "the budget is twenty five")
    assert rejected("- Budget is 26", "the budget is twenty five")
    assert rejected("- Budget is 250", "the budget is twenty five")


def test_helper_vocabulary():
    assert notes.spoken_numbers(notes.words_of("two million three hundred thousand")) == {"2300000"}
    assert notes.spoken_numbers(notes.words_of("twenty five or six")) == {"25", "6"}
    assert notes.spoken_numbers(notes.words_of("no numbers here")) == set()


# --- helper pipe protocol ------------------------------------------------------------------


class Tokenizer:
    def __init__(self, length=100):
        self.length, self.messages = length, None

    def apply_chat_template(self, messages, **kwargs):
        self.messages = messages
        assert kwargs["enable_thinking"] is False
        return list(range(self.length))


@pytest.fixture
def mlx(monkeypatch):
    calls, replies = [], []

    def stream_generate(model, tokenizer, **kwargs):
        calls.append(kwargs)

        class Chunk:
            text, finish_reason = "ok", "stop"

        yield Chunk()

    module = type(sys)("mlx_lm")
    module.stream_generate = stream_generate
    monkeypatch.setitem(sys.modules, "mlx_lm", module)
    monkeypatch.setattr(cleanup_worker, "reply", replies.append)
    return calls, replies


def worker_call(request, tokenizer):
    cleanup_worker.generate(json.dumps(request), None, tokenizer, "sampler")


def test_worker_user_override_and_max_tokens(mlx):
    calls, replies = mlx
    tokenizer = Tokenizer()
    worker_call({"text": "", "system": "S", "user": "Notes JSON: {}", "max_tokens": 300}, tokenizer)
    assert tokenizer.messages == [
        {"role": "system", "content": "S"},
        {"role": "user", "content": "Notes JSON: {}"},
    ]
    assert calls[0]["max_tokens"] == 300 and calls[0]["sampler"] == "sampler"
    assert replies == [{"ok": True, "text": "ok", "finish_reason": "stop"}]


def test_worker_legacy_request_is_unchanged(mlx):
    calls, replies = mlx
    tokenizer = Tokenizer()
    worker_call({"text": 'say "hi"', "system": "S"}, tokenizer)
    assert tokenizer.messages[1]["content"] == 'Transcript JSON: "say \\"hi\\""'
    assert calls[0]["max_tokens"] == cleanup_worker.MAX_OUTPUT == 512
    assert replies[0]["ok"] is True


@pytest.mark.parametrize("value", [0, -1, 1025, "300", 3.5, True, None, [300]])
def test_worker_rejects_bad_max_tokens(mlx, value):
    calls, replies = mlx
    worker_call({"text": "", "system": "S", "user": "u", "max_tokens": value}, Tokenizer())
    assert replies == [{"ok": False}] and not calls


@pytest.mark.parametrize("value", [1, 1024])
def test_worker_accepts_max_tokens_bounds(mlx, value):
    calls, replies = mlx
    worker_call({"text": "", "system": "S", "user": "u", "max_tokens": value}, Tokenizer(100))
    assert calls[0]["max_tokens"] == value and replies[0]["ok"] is True


def test_worker_context_budget_uses_the_request_cap(mlx):
    calls, replies = mlx
    # 3000 prompt tokens fit with a 768 cap but not with the 1024 maximum.
    worker_call({"text": "", "system": "S", "user": "u", "max_tokens": 768}, Tokenizer(3000))
    assert replies[-1]["ok"] is True
    worker_call({"text": "", "system": "S", "user": "u", "max_tokens": 1024}, Tokenizer(3200))
    assert replies[-1] == {"ok": False} and len(calls) == 1
    worker_call({"text": "x", "system": "S"}, Tokenizer(3700))  # legacy: 3700 + 512 > 4096
    assert replies[-1] == {"ok": False}


def test_worker_rejects_non_string_user(mlx):
    calls, replies = mlx
    worker_call({"text": "", "system": "S", "user": 5}, Tokenizer())
    assert replies == [{"ok": False}] and not calls


# --- real model (opt-in) -------------------------------------------------------------------


@pytest.mark.model
async def test_real_model_structures_eval_entries():
    try:
        discover(DEFAULT_MODEL)
    except ValueError:
        pytest.skip("cleanup weights missing; explicitly run model fetch --cleanup")
    entries = [
        json.loads(line)
        for line in Path(__file__).with_name("notes_eval.jsonl").read_text().splitlines()
    ][:2]
    corrector = Corrector(
        CorrectionConfig(mode="managed", model=DEFAULT_MODEL, timeout=120, structure_timeout=120)
    )
    try:
        for entry in entries:
            result = await notes.structure(corrector, entry["transcript"], entry.get("outline", []))
            assert result.structured, (entry["id"], result.error)
            assert "- " in result.markdown, entry["id"]
            lowered = result.markdown.lower()
            assert all(word.lower() in lowered for word in entry["keywords"]), entry["id"]
    finally:
        await corrector.close()
