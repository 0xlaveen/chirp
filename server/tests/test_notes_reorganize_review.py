"""Review regressions for feat/notes-edit (issue #17): reorganize guards."""

from chirp_server.notes import reorganize_rejection_reason

# A faithful merge of two `## Budget` sections. The notes hold an affirmative line and a negated
# line about the same thing, which is ordinary in meeting notes.
NOTES = (
    "## Budget\n- Book the venue for June\n## Speakers\n- Two keynotes confirmed\n"
    "## Budget\n- Do not book the venue before the deposit clears\n- Deposit is 500"
)
MERGED = (
    "## Budget\n- Book the venue for June\n- Do not book the venue before the deposit clears\n"
    "- Deposit is 500\n\n## Speakers\n- Two keynotes confirmed"
)


def test_a_faithful_merge_with_an_existing_affirmative_line_is_accepted():
    # Fails: check_flips reads "Book the venue for June" (already in the input) as a flip of
    # "do not book the venue ...", so every reorganize of these notes is rejected.
    assert reorganize_rejection_reason(NOTES, MERGED, "stop") is None


def test_a_negation_may_not_become_a_hedge():
    notes = "## Hiring\n- We will not hire contractors for the stage\n- Two keynotes confirmed"
    flipped = "## Hiring\n- Maybe we will hire contractors for the stage\n- Two keynotes confirmed"
    # Fails: guard 7 accepts any negation-or-hedge on the matching line, so "not" -> "maybe" passes.
    assert reorganize_rejection_reason(notes, flipped, "stop") is not None


def test_numbers_may_not_swap_between_items():
    notes = (
        "## Budget\n- Venue quote is $1,200\n- Catering quote is $4,200\n- Two keynotes confirmed"
    )
    swapped = (
        "## Budget\n- Venue quote is $4,200\n- Catering quote is $1,200\n- Two keynotes confirmed"
    )
    # Fails: a number only needs one shared content word ("quote") on its output line.
    assert reorganize_rejection_reason(notes, swapped, "stop") is not None


# --- further review cases (N2, N5) ---------------------------------------------------------


def test_a_real_flip_is_still_rejected_next_to_an_affirmative_line():
    flipped = MERGED.replace("Do not book the venue before", "Book the venue before")
    assert reorganize_rejection_reason(NOTES, flipped, "stop") == "negation"


def test_an_unchanged_copy_of_affirmative_and_negated_lines_is_accepted():
    for notes in (
        "## Crew\n- Hire a contractor for the stage\n- We won't hire a contractor for lighting",
        "## Beta\n- Ship the beta to testers next week\n- We will not ship the beta on Friday",
    ):
        assert reorganize_rejection_reason(notes, notes.replace("## ", "## ", 1), "stop") is None


# Enough other content that a one-word change stays above the coverage floors.
CONTEXT = (
    "\n- Two keynotes confirmed for the morning session\n- Venue holds eighty people with parking"
    "\n- Catering offers vegetarian and vegan menus"
)


def test_a_hedge_may_stay_a_hedge_or_become_a_negation():
    notes = "## Trip\n- Not sure whether the grant covers travel for the team" + CONTEXT
    for output in (
        "## Trip\n- Unsure whether the grant covers travel for the team" + CONTEXT,
        "## Trip\n- We do not know whether the grant covers travel for the team" + CONTEXT,
    ):
        assert reorganize_rejection_reason(notes, output, "stop") is None, output
    plain = "## Trip\n- The grant covers travel for the team" + CONTEXT
    assert reorganize_rejection_reason(notes, plain, "stop") == "negation"


def test_a_number_must_stay_on_its_own_line():
    notes = "## Budget\n- Venue quote is $1,200\n- Catering quote is $4,200"
    merged = "## Budget\n- Venue quote is $1,200 and catering quote is $4,200"
    assert reorganize_rejection_reason(notes, merged, "stop") is None


def test_a_task_owner_must_survive():
    notes = "## Food\n- [ ] Jo to confirm the caterer by Monday" + CONTEXT
    output = "## Food\n- [ ] Confirm the caterer by Monday" + CONTEXT
    assert reorganize_rejection_reason(notes, output, "stop") == "task_owner"
    bold = "## Food\n- [ ] **Maya** to send the draft budget by Friday" + CONTEXT
    assert reorganize_rejection_reason(bold, bold.replace("**Maya** to", "To"), "stop") == (
        "task_owner"
    )
    moved = "## Food" + CONTEXT + "\n\n## Action items\n- [ ] Jo to confirm the caterer by Monday"
    assert reorganize_rejection_reason(notes, moved, "stop") is None


def test_apostrophe_less_negations_are_negations():
    notes = "## Trip\n- dont book the bus until the headcount is final" + CONTEXT
    fixed = notes.replace("dont", "don't")
    assert reorganize_rejection_reason(notes, fixed, "stop") is None
    assert reorganize_rejection_reason(notes, notes.replace("dont book", "book"), "stop") == (
        "negation"
    )
