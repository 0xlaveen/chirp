"""POST /v1/notes/edit: validation, refusals, guards, selection, fail-closed mapping, privacy.

All notes are synthetic. The managed path runs the real pipe supervision against
`fake_cleanup_helper.py`; no model is loaded outside the opt-in `model` tests.
"""

import asyncio
import json
import logging
import time
from pathlib import Path

import httpx
import pytest
from conftest import HEADERS, TOKEN
from starlette.testclient import TestClient
from test_notes import COMMAND, endpoint_corrector, read_log, reply, wait_for

from chirp_server import notes_edit
from chirp_server.app import create_app
from chirp_server.cleanup_models import DEFAULT_MODEL, discover
from chirp_server.config import CorrectionConfig
from chirp_server.correction import Corrector
from chirp_server.engine import FakeEngine
from chirp_server.managed_cleanup import ManagedCleanup

URL = "/v1/notes/edit"
FIXTURES = Path(__file__).parent

NOTES = (
    "## Launch plan\n"
    "- Beta ships on **March 3** to **200** testers\n"
    "- we will **not** open the waitlist before the docs are done\n"
    "- [ ] **Priya** to finish the onboarding guide by **Friday**\n"
    "## Pricing\n"
    "- Starter tier **$12** a month, Team tier **$40**\n"
    "- maybe a **20%** discount for annual plans\n"
    "- **Decision:** no free tier for now\n"
    "## Support\n"
    "- Two people on support rotation during the beta\n"
    "- [x] Omar set up the help inbox"
)
DELETE = "remove the pricing section"
DELETED = (
    "## Launch plan\n"
    "- Beta ships on **March 3** to **200** testers\n"
    "- we will **not** open the waitlist before the docs are done\n"
    "- [ ] **Priya** to finish the onboarding guide by **Friday**\n"
    "## Support\n"
    "- Two people on support rotation during the beta\n"
    "- [x] Omar set up the help inbox"
)


def service(*extra, **kwargs):
    config = CorrectionConfig(mode="managed", **kwargs)
    corrector = Corrector(config)
    if "--reply-edit" not in extra:
        extra = (*extra, "--reply-edit", DELETED)
    corrector.managed = ManagedCleanup(config, command=[*COMMAND, *extra])
    return corrector


def run(settings, corrector):
    return TestClient(create_app(settings, FakeEngine(), TOKEN, corrector=corrector))


def post(client, body, headers=HEADERS):
    return client.post(URL, headers=headers, json=body)


def counting(content, finish="stop"):
    seen = []

    def handle(request):
        seen.append(json.loads(request.content))
        return reply(content, finish)

    return seen, handle


# --- auth, off, health ---------------------------------------------------------------------


@pytest.mark.parametrize("headers", [{}, {"Authorization": "Bearer wrong"}])
def test_auth(client, headers):
    response = post(client, {"notes": NOTES, "instruction": DELETE}, headers)
    assert response.status_code == 401 and response.json()["code"] == "auth"
    assert response.headers["www-authenticate"] == "Bearer"


def test_off_is_409(client):
    response = post(client, {"notes": NOTES, "instruction": DELETE})
    assert response.status_code == 409 and response.json()["code"] == "notes_off"


def test_health_advertises_edit(client):
    assert client.get("/v1/health", headers=HEADERS).json()["notes_edit"] is True
    assert client.get("/v1/health").json() == {"ok": True}


# --- validation ----------------------------------------------------------------------------

VALID = {"notes": NOTES, "instruction": DELETE}
INVALID = {
    "non-object": [],
    "unknown key": {**VALID, "outline": []},
    "missing instruction": {"notes": NOTES},
    "missing notes": {"instruction": DELETE},
    "empty instruction": {**VALID, "instruction": "  "},
    "non-string instruction": {**VALID, "instruction": 3},
    "instruction too long": {**VALID, "instruction": "a " * 201},
    "empty notes": {**VALID, "notes": "\n"},
    "notes too long": {**VALID, "notes": "a" * 3501},
    "selection not string": {**VALID, "selection": 5},
    "selection not in notes": {**VALID, "selection": "## Marketing"},
    "selection twice": {"notes": "- a\n- b\n- a", "instruction": DELETE, "selection": "- a"},
    "selection too long": {"notes": "a" * 4000, "instruction": DELETE, "selection": "a" * 3501},
    "document too long": {"notes": "b" * 32001, "instruction": DELETE, "selection": "b"},
}


@pytest.mark.parametrize("body", INVALID.values(), ids=INVALID)
def test_invalid_requests_are_400(settings, body):
    with run(settings, service(timeout=1)) as client:
        response = post(client, body)
    assert response.status_code == 400 and response.json()["code"] == "bad_notes"


def test_limits_are_inclusive():
    request = notes_edit.validate_edit_request(
        {"notes": f" {'a' * 3500} ", "instruction": "  remove   the\nfirst bit " + "x" * 300}
    )
    assert len(request.notes) == 3500 and request.instruction.startswith("remove the first bit")
    long = "c" * 31000 + "\n## Tail\n- last line"
    request = notes_edit.validate_edit_request(
        {"notes": long, "instruction": DELETE, "selection": " ## Tail\n- last line "}
    )
    assert request.selection == "## Tail\n- last line" and request.text == request.selection
    assert notes_edit.MAX_EDIT_CHARS == 3500 and notes_edit.EDIT_MAX_TOKENS == 1024


# --- the pass ------------------------------------------------------------------------------


def test_managed_edits(settings, tmp_path):
    log = tmp_path / "requests.jsonl"
    with run(settings, service("--log", str(log), timeout=2)) as client:
        response = post(client, {"notes": NOTES, "instruction": DELETE})
    body = response.json()
    assert response.status_code == 200
    assert body["markdown"] == DELETED and body["edited"] is True and body["changed"] is True
    assert set(body) == {"markdown", "edited", "changed", "error", "timings_ms"}
    assert body["error"] is None and body["timings_ms"]["edit"] > 0
    (request,) = read_log(log)
    assert request["kind"] == "edit" and request["max_tokens"] == 1024
    assert json.loads(request["user"].removeprefix("Edit JSON: ")) == {
        "instruction": DELETE,
        "notes": NOTES,
    }


def test_endpoint_sends_the_edit_prompt(settings):
    seen, handle = counting(DELETED)
    with run(settings, endpoint_corrector(handle)) as client:
        body = post(client, {"notes": NOTES, "instruction": DELETE}).json()
    assert body["edited"] is True and body["markdown"] == DELETED
    (sent,) = seen
    assert sent["max_tokens"] == 1024 and sent["temperature"] == 0
    assert sent["messages"][0]["content"] == notes_edit.edit_system_prompt()
    assert sent["messages"][1]["content"] == notes_edit.edit_user_message(DELETE, NOTES)


def test_system_prompt_is_the_core_sandwich():
    prompt = notes_edit.edit_system_prompt()
    assert prompt.startswith(notes_edit.EDIT_CORE) and prompt.endswith(notes_edit.EDIT_CORE)
    assert len(prompt) <= 5200


def test_identical_reply_is_unchanged(settings):
    echoed = NOTES.replace("## Pricing", "\n## Pricing  ")
    with run(settings, service("--reply-edit", echoed, timeout=2)) as client:
        body = post(client, {"notes": NOTES, "instruction": "clean up the support bit"}).json()
    assert body["markdown"] == NOTES
    assert body["edited"] is True and body["changed"] is False and body["error"] is None


@pytest.mark.parametrize(
    "text,reason",
    [
        ("REFUSE: adds_content", "adds_content"),
        ("`REFUSE: unclear`", "unclear"),
        ("REFUSE: not_an_edit", "not_an_edit"),
        ("REFUSE: because I said so", "unclear"),
    ],
)
def test_model_refusals_are_reported(settings, text, reason):
    seen, handle = counting(text)
    with run(settings, endpoint_corrector(handle)) as client:
        body = post(client, {"notes": NOTES, "instruction": "delete the marketing part"}).json()
    assert body == body | {"markdown": None, "edited": False, "changed": False}
    assert body["error"] == "refused" and body["reason"] == reason and len(seen) == 1


@pytest.mark.parametrize(
    "instruction",
    [
        "add a summary of the things we didn't talk about",
        "explain why we picked the beta date",
        "brainstorm some launch ideas",
        "what should the price be, answer that",
        "translate it into French",
    ],
)
def test_requests_for_new_writing_are_refused_before_the_model(settings, instruction):
    seen, handle = counting(DELETED)
    with run(settings, endpoint_corrector(handle)) as client:
        body = post(client, {"notes": NOTES, "instruction": instruction}).json()
    assert body["error"] == "refused" and body["reason"] == "adds_content" and seen == []


def test_a_word_naming_an_existing_section_is_not_a_refusal(settings):
    text = NOTES + "\n## Summary\n- Beta first, pricing later"
    moved = "## Summary\n- Beta first, pricing later\n" + NOTES
    seen, handle = counting(moved)
    with run(settings, endpoint_corrector(handle)) as client:
        body = post(client, {"notes": text, "instruction": "move the summary to the top"}).json()
    assert body["edited"] is True and body["markdown"] == moved and len(seen) == 1


def test_a_selection_is_edited_alone_and_spliced_back(settings):
    selection = "## Support\n- Two people on support rotation during the beta"
    edited = "## Support\n- [ ] Two people on support rotation during the beta"
    seen, handle = counting(edited)
    body = {"notes": NOTES, "instruction": "make this a checklist", "selection": selection}
    with run(settings, endpoint_corrector(handle)) as client:
        result = post(client, body).json()
    assert result["edited"] is True and result["changed"] is True
    assert result["markdown"] == NOTES.replace(selection, edited)
    sent = json.loads(seen[0]["messages"][1]["content"].removeprefix("Edit JSON: "))
    assert sent == {"instruction": "make this a checklist", "notes": selection}


@pytest.mark.parametrize(
    "handle,error,reason",
    [
        (lambda request: httpx.Response(500), "http", None),
        (lambda request: reply("```\n" + DELETED + "\n```"), "rejected", "forbidden"),
        (lambda request: reply(DELETED, "length"), "rejected", "finish"),
        (lambda request: reply(DELETED.replace("200", "250")), "rejected", None),
        (lambda request: httpx.Response(200, json={"unexpected": True}), "rejected", None),
    ],
)
def test_endpoint_failures_fail_closed(settings, handle, error, reason):
    with run(settings, endpoint_corrector(handle)) as client:
        body = post(client, {"notes": NOTES, "instruction": DELETE}).json()
    assert body["markdown"] is None and body["edited"] is False and body["error"] == error
    if reason:
        assert body["reason"] == reason


def test_endpoint_timeout_uses_the_reorganize_budget(settings):
    async def slow(request):
        await asyncio.sleep(1)
        return reply(DELETED)

    config = CorrectionConfig(
        mode="endpoint", base_url="http://127.0.0.1:1234/v1", timeout=2, reorganize_timeout=0.1
    )
    with run(settings, Corrector(config, httpx.MockTransport(slow))) as client:
        assert post(client, VALID).json()["error"] == "timeout"


@pytest.mark.parametrize("text,error", [("hang", "timeout"), ("crash", "rejected")])
def test_managed_failures_fail_closed(settings, text, error):
    with run(settings, service(timeout=1, reorganize_timeout=1.5)) as client:
        response = post(client, {"notes": text, "instruction": "clean that up"})
        again = post(client, VALID)
    assert response.json()["edited"] is False and response.json()["error"] == error
    assert again.json()["edited"] is True  # the helper restarts after a failure


def test_rejections_name_their_guard_in_the_response_and_log(settings, caplog):
    caplog.set_level(logging.INFO)
    wrong = DELETED.replace("- Two people on support rotation during the beta\n", "")
    with run(settings, service("--reply-edit", wrong, timeout=2)) as client:
        body = post(client, VALID).json()
    assert body["error"] == "rejected" and body["reason"] == "dropped_unasked"
    assert "notes_edit chars=" in caplog.text and "reason=dropped_unasked" in caplog.text


async def test_edit_shares_the_notes_lock(settings):
    corrector = service("--slow-structure", "0.5")
    app = create_app(settings, FakeEngine(), TOKEN, corrector=corrector)
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t") as c:
        first = asyncio.create_task(
            c.post("/v1/notes/reorganize", headers=HEADERS, json={"notes": NOTES})
        )
        await asyncio.sleep(0.15)
        second = await c.post(URL, headers=HEADERS, json=VALID)
        assert second.status_code == 503 and second.json()["code"] == "busy"
        assert (await first).status_code == 200
        assert (await c.post(URL, headers=HEADERS, json=VALID)).json()["edited"] is True
    await corrector.close()


async def test_a_queued_correction_preempts_a_running_edit(tmp_path):
    log = tmp_path / "requests.jsonl"
    corrector = service("--slow-structure", "3.0", "--log", str(log), timeout=8)
    try:
        request = notes_edit.EditRequest(NOTES, DELETE)
        running = asyncio.create_task(notes_edit.edit(corrector, request))
        await wait_for(log, 1)
        started = time.monotonic()
        assert (await corrector.process("please send the schedule")).corrected
        assert time.monotonic() - started < 2.5
        assert await running == notes_edit.EditResult(None, False, False, "preempted")
        assert [entry["kind"] for entry in read_log(log)] == ["edit", "correction"]
    finally:
        await corrector.close()


# --- privacy -------------------------------------------------------------------------------


def test_edit_writes_nothing_and_logs_no_text(settings, tmp_path, caplog):
    settings.debug_retain = True
    sentinel = "zyxwvu quixotic marmalade"
    caplog.set_level(logging.DEBUG)
    with run(settings, service("--reply-edit", DELETED + f"\n- {sentinel}", timeout=2)) as client:
        before = set(tmp_path.rglob("*"))
        body = post(
            client, {"notes": NOTES + f"\n- {sentinel}", "instruction": DELETE + " secretword"}
        ).json()
        assert body["edited"] is True
        assert set(tmp_path.rglob("*")) == before
    assert "notes_edit chars=" in caplog.text
    for secret in (sentinel, "secretword", "pricing", "Priya", "Launch"):
        assert secret not in caplog.text


# --- guards --------------------------------------------------------------------------------


def reason(output, instruction=DELETE, source=NOTES, finish="stop"):
    return notes_edit.edit_rejection_reason(source, instruction, output, finish)


def test_prompt_examples_pass_the_guards():
    for instruction, text, output in notes_edit.EDIT_EXAMPLES:
        if notes_edit.refusal(output):
            assert notes_edit.refused_upfront(instruction, text) == notes_edit.refusal(output)
        else:
            assert reason(output, instruction, text) is None, instruction


def test_a_requested_delete_is_accepted_and_an_unrequested_one_is_not():
    assert reason(DELETED) is None
    assert reason(DELETED, "clean up the pricing section") == "dropped_number"
    assert reason(DELETED, "remove the support section") == "dropped_unasked"


def test_a_place_only_delete_stays_in_one_section():
    last = NOTES.removesuffix("\n- [x] Omar set up the help inbox")
    assert reason(last, "delete the last line") is None
    both = last.replace("- maybe a **20%** discount for annual plans\n", "")
    assert reason(both, "delete the last line") == "dropped_unasked"


def test_a_checklist_may_add_tasks_but_not_tick_them():
    checklist = NOTES.replace("- Two people", "- [ ] Two people")
    assert reason(checklist, "make the support section a checklist") is None
    ticked = checklist.replace("- [ ] **Priya**", "- [x] **Priya**")
    assert reason(ticked, "make the support section a checklist") == "task_state"
    assert reason(checklist, "clean up the support section") == "task_invented"


def test_done_changes_only_the_named_task():
    done = NOTES.replace("- [ ] **Priya**", "- [x] **Priya**")
    assert reason(done, "mark Priya's onboarding guide as done") is None
    both = done.replace("- [x] Omar", "- [ ] Omar")
    assert reason(both, "mark Priya's onboarding guide as done") == "task_state"
    assert reason(both, "mark everything as open") is None


def test_a_replacement_from_the_instruction_is_accepted():
    renamed = NOTES.replace("**Friday**", "**Thursday**")
    assert reason(renamed, "change Friday to Thursday") is None
    assert reason(renamed, "clean that up") == "novel_date"


def test_a_requested_numbered_list_is_markup_not_numbers():
    numbered = NOTES.replace(
        "- Two people on support rotation during the beta\n- [x] Omar",
        "1. Two people on support rotation during the beta\n2. [x] Omar",
    )
    assert reason(numbered, "make the support section a numbered list") is None
    assert reason(numbered, "tidy the support section") is not None


def test_a_summary_section_is_rejected_even_when_asked_for_in_other_words():
    summary = NOTES + "\n## Summary\n- Beta ships on **March 3**"
    assert reason(summary, "wrap it up with a summary at the end") == "summary"


def test_unfinished_output_is_rejected():
    assert reason(DELETED, finish="length") == "finish"


def test_edit_negatives_fixture_is_rejected():
    path = FIXTURES / "notes_edit_negatives.jsonl"
    cases = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
    assert len(cases) >= 25
    for case in cases:
        assert reason(case["output"], case["instruction"], case["notes"]), case["id"]


def test_edit_eval_set_shape():
    path = FIXTURES / "notes_edit_eval.jsonl"
    cases = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
    assert {case["expect"] for case in cases} == {"edit", "refuse"}
    for case in cases:
        assert set(case) == {"id", "notes", "instruction", "expect", "expect_gone", "expect_kept"}
        notes_edit.validate_edit_request(
            {"notes": case["notes"], "instruction": case["instruction"]}
        )
        source = case["notes"].lower()
        assert all(word.lower() in source for word in case["expect_gone"]), case["id"]
    ids = {case["id"] for case in cases}
    for required in (
        "launch-delete-pricing",
        "messy-tidy-top",
        "messy-checklist",
        "launch-summary",
    ):
        assert required in ids


# --- real model (opt-in) -------------------------------------------------------------------


def real_model():
    try:
        return discover(DEFAULT_MODEL)
    except ValueError:
        pytest.skip("cleanup weights missing; explicitly run model fetch --cleanup")


@pytest.mark.model
def test_real_prompt_fits_the_context_budget():
    from transformers import AutoTokenizer

    from chirp_server import cleanup_worker

    tokenizer = AutoTokenizer.from_pretrained(str(real_model()), local_files_only=True)
    path = FIXTURES / "notes_reorganize_eval.jsonl"
    largest = max(
        (json.loads(line)["notes"] for line in path.read_text().splitlines() if line.strip()),
        key=len,
    )
    text = (largest + "\n" + largest)[: notes_edit.MAX_EDIT_CHARS]
    instruction = "x " * (notes_edit.MAX_INSTRUCTION_CHARS // 2)
    tokens = tokenizer.apply_chat_template(
        [
            {"role": "system", "content": notes_edit.edit_system_prompt()},
            {"role": "user", "content": notes_edit.edit_user_message(instruction, text)},
        ],
        tokenize=True,
        add_generation_prompt=True,
        enable_thinking=False,
    )
    tokens = tokens["input_ids"] if hasattr(tokens, "keys") else tokens
    assert len(tokens) + notes_edit.EDIT_MAX_TOKENS <= cleanup_worker.MAX_CONTEXT, len(tokens)
    print(f"edit prompt tokens at the cap: {len(tokens)}")


@pytest.mark.model
async def test_real_model_edits_and_refuses():
    real_model()
    path = FIXTURES / "notes_edit_eval.jsonl"
    cases = {json.loads(line)["id"]: json.loads(line) for line in path.read_text().splitlines()}
    corrector = Corrector(
        CorrectionConfig(mode="managed", model=DEFAULT_MODEL, timeout=120, reorganize_timeout=120)
    )
    try:
        for name in ("launch-delete-pricing", "messy-tidy-top", "launch-answer"):
            case = cases[name]
            request = notes_edit.EditRequest(case["notes"], case["instruction"])
            result = await notes_edit.edit(corrector, request)
            if case["expect"] == "refuse":
                assert result.error == "refused", (name, result)
                continue
            assert result.edited and result.changed, (name, result)
            lowered = result.markdown.lower()
            assert all(word.lower() not in lowered for word in case["expect_gone"]), name
            assert all(word.lower() in lowered for word in case["expect_kept"]), name
    finally:
        await corrector.close()
