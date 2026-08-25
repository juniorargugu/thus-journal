#!/usr/bin/env python3
"""T4A copy-contract validation — makes t4a_copy_contract_v1.json EXECUTABLE, not prose.

The contract freezes bot acknowledgement SEMANTICS (clause ids per action x outcome cell)
before T4A-1 wires the Telegram callbacks. The exact Thai stays formatter-owned; what this
suite pins is the semantic layer:

  * the action vocabulary is EXACTLY the committed T3 vocabulary — labels are imported from
    t3_capture_prompt.ACTION_LABELS, never duplicated here, so any T3 add/remove/rename/label
    change fails this suite until the contract is intentionally updated;
  * every journal_add cell carries BOTH frozen clauses: the REQUEST meaning (recorded intent,
    not completed work) AND journal_not_modified — no cell may ever imply Journal promotion
    happened (that is T4B);
  * already_logged / no_record keep their action-specific terminal semantics;
  * the action-independent outcome rows (matrix-reject, validated error, transport-unknown,
    db-success-then-answer-failure) keep their frozen clause lists, including decision_stands
    + no_rollback + never_classified_failed on the answer-failure row.

Cells are compared EXACTLY against the frozen clause lists (the contract is clause ids, not
prose, so exact equality IS the semantic pin), plus explicit labeled checks for the clauses
the T4 Rev-3 order names, plus a promotion-claim scan that guards the checker itself.

NEGATIVE CONTROLS (permanent, run on every invocation): a missing action, a journal_add
replay cell that lost journal_not_modified, and a drifted T3.ACTION_LABELS are each fed to
the same checker in-process and MUST produce failures — proving this suite actually detects
the drift classes it exists for.
"""
from __future__ import annotations

import copy
import json
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import t3_capture_prompt as t3                                      # noqa: E402

CONTRACT_PATH = pathlib.Path(__file__).resolve().parent / "fixtures" / "t4a_copy_contract_v1.json"

CHECKS = [0]
FAILS: list[str] = []

EXPECTED_VERSION = "t4a-copy-contract/1"
EXPECTED_TOP_KEYS = {"version", "comment", "action_labels",
                     "forbidden_generic_success_in_journal_add_context",
                     "cells", "action_independent_outcomes"}
EXPECTED_CELL_KEYS = {"first_insert", "same_action_replay", "as_existing_in_conflict"}

FROZEN_CELLS = {
    "journal_add": {
        "first_insert": ["request_recorded", "journal_not_modified"],
        "same_action_replay": ["request_was_already_recorded", "journal_not_modified"],
        "as_existing_in_conflict": ["existing_journal_add_request_named",
                                    "journal_not_modified",
                                    "replacement_refused_with_new_label"],
    },
    "already_logged": {
        "first_insert": ["terminal_fact_stated"],
        "same_action_replay": ["decision_already_recorded_with_label"],
        "as_existing_in_conflict": ["existing_decision_named_with_label",
                                    "replacement_refused_with_new_label"],
    },
    "no_record": {
        "first_insert": ["terminal_fact_stated"],
        "same_action_replay": ["decision_already_recorded_with_label"],
        "as_existing_in_conflict": ["existing_decision_named_with_label",
                                    "replacement_refused_with_new_label"],
    },
}

FROZEN_INDEPENDENT = {
    "ERR_ACTION_NOT_ALLOWED": ["cannot_record_this_action_for_this_evidence",
                               "no_success_claim"],
    "validated_rpc_error": ["no_success_claim", "specific_refusal_copy"],
    "transport_or_malformed": ["outcome_unknown", "no_success_claim", "no_auto_retry",
                               "session_survives_ttl_for_explicit_retry"],
    "db_success_then_answer_failure": ["decision_stands", "no_rollback",
                                       "never_classified_failed",
                                       "next_tap_resolves_idempotently"],
}

FROZEN_FORBIDDEN_GENERIC = ["บันทึกแล้ว", "เรียบร้อยแล้ว", "เพิ่มแล้ว"]

#: Clause tokens that would claim the Journal write happened. Guards the CHECKER itself:
#: even a future "intentional" edit of FROZEN_CELLS cannot quietly smuggle a promotion claim.
PROMOTION_CLAIM_TOKENS = ("journal_written", "journal_updated", "journal_saved",
                          "promotion_completed", "promoted", "trade_created",
                          "trade_added")


def check(cond, label, collector=None):
    CHECKS[0] += 1
    if not cond:
        (collector if collector is not None else FAILS).append(label)


def run_contract_checks(contract, t3_labels, collector=None):
    """The full validation, parameterized so negative controls can run it in-process."""
    c = lambda cond, label: check(cond, label, collector)  # noqa: E731

    c(contract.get("version") == EXPECTED_VERSION,
      f"version is exactly {EXPECTED_VERSION!r}")
    c(set(contract) == EXPECTED_TOP_KEYS, "top-level key set is exactly the frozen six")

    labels = contract.get("action_labels", {})
    cells = contract.get("cells", {})
    c(set(labels) == set(t3_labels),
      "contract action ids == committed T3.ACTION_LABELS ids (no missing, no unknown)")
    c(set(cells) == set(t3_labels),
      "cells cover exactly the committed T3 action ids (complete coverage, no strays)")
    c(labels == t3_labels,
      "action labels agree EXACTLY with committed T3.ACTION_LABELS (imported, not retyped)")
    c(set(t3_labels) == {"journal_add", "already_logged", "no_record"},
      "the committed T3 action vocabulary is the frozen three")

    for action, outcomes in cells.items():
        c(set(outcomes) == EXPECTED_CELL_KEYS,
          f"{action}: outcome cells are exactly first_insert/replay/conflict")
        for outcome, clauses in outcomes.items():
            c(isinstance(clauses, list) and clauses
              and all(isinstance(x, str) for x in clauses)
              and len(set(clauses)) == len(clauses),
              f"{action}.{outcome}: a non-empty list of unique clause ids")
            c(not any(tok in clause.lower() for clause in clauses
                      for tok in PROMOTION_CLAIM_TOKENS),
              f"{action}.{outcome}: no clause claims a Journal promotion happened")

    c(cells == FROZEN_CELLS,
      "every action x outcome cell equals its frozen clause list exactly")

    ja = cells.get("journal_add", {})
    for outcome in EXPECTED_CELL_KEYS:
        c("journal_not_modified" in ja.get(outcome, []),
          f"journal_add.{outcome}: carries journal_not_modified (the Journal write has NOT "
          f"happened until T4B)")
    c(any("request" in x for x in ja.get("first_insert", [])),
      "journal_add.first_insert: explicit REQUEST/intent meaning")
    c(any("request" in x for x in ja.get("same_action_replay", [])),
      "journal_add.same_action_replay: explicit REQUEST-was-already-recorded meaning")
    c(any("request" in x for x in ja.get("as_existing_in_conflict", [])),
      "journal_add.as_existing_in_conflict: names the EXISTING request explicitly")

    for action in ("already_logged", "no_record"):
        c(cells.get(action, {}).get("first_insert") == ["terminal_fact_stated"],
          f"{action}.first_insert: action-specific terminal semantics")

    forb = contract.get("forbidden_generic_success_in_journal_add_context", [])
    c(forb == FROZEN_FORBIDDEN_GENERIC,
      "forbidden generic success words are exactly the frozen list")
    c(all(word not in label for word in forb for label in labels.values()),
      "no action label is itself a forbidden bare generic success word")

    indep = contract.get("action_independent_outcomes", {})
    c(set(indep) == set(FROZEN_INDEPENDENT),
      "action-independent outcome rows are exactly the frozen four")
    c(indep == FROZEN_INDEPENDENT,
      "every action-independent outcome row equals its frozen clause list exactly")
    dbrow = indep.get("db_success_then_answer_failure", [])
    for clause in ("decision_stands", "no_rollback", "never_classified_failed"):
        c(clause in dbrow, f"db_success_then_answer_failure: carries {clause}")
    for row in ("ERR_ACTION_NOT_ALLOWED", "validated_rpc_error", "transport_or_malformed"):
        c("no_success_claim" in indep.get(row, []),
          f"{row}: never claims success")
    c("no_auto_retry" in indep.get("transport_or_malformed", []),
      "transport_or_malformed: outcome unknown means NO automatic retry")


def load_contract():
    return json.loads(CONTRACT_PATH.read_text(encoding="utf-8"))


def t_contract_is_valid():
    run_contract_checks(load_contract(), dict(t3.ACTION_LABELS))


def _negative(mutate_contract=None, mutate_labels=None):
    """Run the checker against a deliberately broken input; it MUST record failures."""
    contract = copy.deepcopy(load_contract())
    labels = dict(t3.ACTION_LABELS)
    if mutate_contract:
        mutate_contract(contract)
    if mutate_labels:
        mutate_labels(labels)
    caught: list[str] = []
    before = CHECKS[0]
    run_contract_checks(contract, labels, collector=caught)
    CHECKS[0] = before          # negative-control sub-checks don't inflate the total
    return caught


def t_negative_controls_prove_detection():
    def drop_action(con):
        del con["cells"]["no_record"]
        del con["action_labels"]["no_record"]
    check(bool(_negative(mutate_contract=drop_action)),
          "NEGATIVE CONTROL: a contract missing an action MUST fail (probe I)")

    def drop_not_modified(con):
        con["cells"]["journal_add"]["same_action_replay"] = ["request_was_already_recorded"]
    check(bool(_negative(mutate_contract=drop_not_modified)),
          "NEGATIVE CONTROL: journal_add replay without journal_not_modified MUST fail "
          "(probe J)")

    def promotion_claim(con):
        con["cells"]["journal_add"]["first_insert"] = ["request_recorded",
                                                       "journal_not_modified",
                                                       "trade_created"]
    check(bool(_negative(mutate_contract=promotion_claim)),
          "NEGATIVE CONTROL: a promotion-claiming clause MUST fail")

    def rename_action(labels):
        labels["skip_it"] = labels.pop("no_record")
    check(bool(_negative(mutate_labels=rename_action)),
          "NEGATIVE CONTROL: drifted T3.ACTION_LABELS MUST fail this suite (probe K)")

    def relabel_action(labels):
        labels["no_record"] = "บันทึกแล้ว"
    check(bool(_negative(mutate_labels=relabel_action)),
          "NEGATIVE CONTROL: a T3 label changed to a forbidden generic MUST fail")


ALL = [
    t_contract_is_valid,
    t_negative_controls_prove_detection,
]


def main():
    for test in ALL:
        test()
    if FAILS:
        for f in FAILS:
            print(f"FAIL: {f}")
        print(f"t4a copy contract: {CHECKS[0]} checks, {len(FAILS)} FAILED")
        return 1
    print(f"t4a copy contract: {CHECKS[0]} checks, PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
