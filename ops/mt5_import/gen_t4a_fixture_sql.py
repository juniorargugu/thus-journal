#!/usr/bin/env python3
"""T4A-0 fixture -> SQL generator. ONE fixture authority, structurally propagated.

Reads the canonical repository fixture (ops/mt5_import/fixtures/t3_kind_fixtures_v1.json),
re-verifies its digest, and deterministically emits the SQL parity FRAGMENT — a single DO
block that executes every fixture case against the installed T4A helpers.

The fragment lives in TWO places, and the release-critical one is the first:

  1. EMBEDDED inside artifacts/mt5_reconciliation/T4A_decisions_rpc_packet.sql, between the
     BEGIN/END markers, INSIDE the packet's transaction, BEFORE the migration-ledger insert
     and COMMIT. If any fixture case fails, the whole RPC migration rolls back: no functions,
     no grants, no ledger row. SQL behavioral parity is therefore ATOMIC with the install —
     there is no window where the RPC is live-and-recorded but unproven.
  2. As the standalone review artifact T4A_t3_kind_fixture_v1.generated.sql (header + the
     same fragment). This file is for review and optional post-apply re-verification only;
     it is NOT the release-correctness step anymore.

`--check` (the default) proves both copies are byte-identical to a fresh generation from the
repository fixture, and that the embedded copy sits before the ledger insert. `--write`
regenerates both in place. A matching sha literal alone is deliberately NOT the proof:
structural equality is regeneration + byte comparison (test_t3_kind_fixture.py runs the same
checks in the suite).

Digest domain (frozen in the T4 Rev-3 contract): canonical_json({"version", "cases"}) with
the repo's committed canonical-JSON rule — sort_keys, compact separators, ensure_ascii=False,
UTF-8 — exactly the rule t2_capture_adapter.canonical_payload_json and
t3_capture_prompt.canonical_prompt_json already use. The physical file's sha256 field is
metadata and is NOT part of its own digest. Fixture content is ASCII-only by contract.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent
FIXTURE_PATH = HERE / "fixtures" / "t3_kind_fixtures_v1.json"
GENERATED_PATH = (HERE.parent.parent / "artifacts" / "mt5_reconciliation"
                  / "T4A_t3_kind_fixture_v1.generated.sql")
RPC_PACKET_PATH = (HERE.parent.parent / "artifacts" / "mt5_reconciliation"
                   / "T4A_decisions_rpc_packet.sql")

#: The dedicated SQLSTATE for stored-evidence violations of the frozen T3 contract.
#: Pinned by the T4A-0 packet; the decision RPC translates ONLY this state.
EVIDENCE_SQLSTATE = "MT4E1"

#: Marker prefixes for the embedded fragment. Version+sha complete each marker line, but
#: extraction matches on the PREFIX so a stale embedded copy is still found (and then fails
#: the byte comparison, which is the point).
MARKER_BEGIN_PREFIX = "-- BEGIN GENERATED T4A T3 PARITY FIXTURE "
MARKER_END_PREFIX = "-- END GENERATED T4A T3 PARITY FIXTURE "

#: The ledger insert the embedded fragment must precede (atomicity: parity runs BEFORE the
#: migration is recorded, inside the same transaction).
LEDGER_INSERT_LINE = "insert into public.mt5_schema_migrations("


def load_fixture():
    physical = json.loads(FIXTURE_PATH.read_text(encoding="utf-8"))
    logical = {"version": physical["version"], "cases": physical["cases"]}
    canonical = json.dumps(logical, sort_keys=True, separators=(",", ":"),
                           ensure_ascii=False)
    canonical.encode("ascii")            # the fixture is ASCII-only by contract
    sha = hashlib.sha256(canonical.encode("utf-8")).hexdigest()
    if physical.get("sha256") != sha:
        raise SystemExit(f"fixture sha mismatch: file says {physical.get('sha256')!r}, "
                         f"canonical {{version,cases}} digest is {sha}")
    return logical, sha


def sql_text_array(values):
    if not values:
        return "array[]::text[]"
    quoted = ", ".join("'" + v.replace("'", "''") + "'" for v in values)
    return f"array[{quoted}]::text[]"


def render_fragment(logical, sha):
    """The parity DO block, wrapped in its BEGIN/END markers. Deterministic."""
    lines = []
    add = lines.append
    add(f"{MARKER_BEGIN_PREFIX}{logical['version']} sha256:{sha}")
    add("-- Generated from ops/mt5_import/fixtures/t3_kind_fixtures_v1.json — DO NOT EDIT.")
    add("-- Regenerate + re-embed with: python -X utf8 "
        "ops/mt5_import/gen_t4a_fixture_sql.py --write")
    add(f"-- A valid case failing raises; an invalid case must raise SQLSTATE "
        f"{EVIDENCE_SQLSTATE}.")
    add("do $t4a_fixture$")
    add("declare")
    add("  v_kind    text;")
    add("  v_actions text[];")
    add("begin")
    n_valid = n_invalid = 0
    for case in logical["cases"]:
        name = case["name"]
        seq = sql_text_array(case["event_types"])
        if case["valid"]:
            n_valid += 1
            add(f"  -- {name}")
            add(f"  v_kind := public.mt5_t3_kind_v1({seq});")
            add(f"  if v_kind is distinct from '{case['kind']}' then")
            add(f"    raise exception 'T4A FIXTURE {name}: derived kind %, expected "
                f"{case['kind']}', v_kind;")
            add("  end if;")
            add("  v_actions := public.mt5_t3_allowed_actions_v1(v_kind);")
            add(f"  if v_actions is distinct from {sql_text_array(case['actions'])} then")
            add(f"    raise exception 'T4A FIXTURE {name}: allowed actions %, expected %',")
            add(f"      v_actions, {sql_text_array(case['actions'])};")
            add("  end if;")
        else:
            n_invalid += 1
            add(f"  -- {name} (must raise SQLSTATE {EVIDENCE_SQLSTATE})")
            add("  begin")
            add(f"    perform public.mt5_t3_kind_v1({seq});")
            add(f"    raise exception 'T4A FIXTURE {name}: invalid sequence was accepted';")
            add(f"  exception when sqlstate '{EVIDENCE_SQLSTATE}' then null;")
            add("  end;")
    add(f"  raise notice 'T4A fixture verification: % valid + % invalid cases PASS "
        f"(sha {sha})', {n_valid}, {n_invalid};")
    add("end $t4a_fixture$;")
    add(f"{MARKER_END_PREFIX}{logical['version']} sha256:{sha}")
    return "\n".join(lines)


def render_standalone(logical, sha):
    """Header + fragment: the review/re-verification artifact (NOT the release step)."""
    lines = []
    add = lines.append
    add("-- ============================================================================")
    add("-- T4A T3 KIND/ACTION FIXTURE VERIFICATION — GENERATED FILE, DO NOT EDIT.")
    add("-- Regenerate with: python -X utf8 ops/mt5_import/gen_t4a_fixture_sql.py --write")
    add("-- Source fixture : ops/mt5_import/fixtures/t3_kind_fixtures_v1.json")
    add(f"-- Fixture version: {logical['version']}")
    add(f"-- fixture_sha256 : {sha}")
    add("--   (canonical {version,cases} digest; the sha literal here is audit metadata —")
    add("--    structural equality is proven by regeneration + byte comparison in")
    add("--    test_t3_kind_fixture.py, never by comparing hash strings.)")
    add("--")
    add("-- RELEASE CORRECTNESS DOES NOT DEPEND ON THIS FILE. The same fragment is EMBEDDED")
    add("-- in T4A_decisions_rpc_packet.sql inside the packet transaction, BEFORE the ledger")
    add("-- insert, so parity failure rolls the whole RPC migration back. This standalone")
    add("-- copy exists for review and optional post-apply re-verification (it is read-only:")
    add("-- it calls the helpers and writes nothing).")
    add("-- ============================================================================")
    add("")
    add(render_fragment(logical, sha))
    add("")
    return "\n".join(lines)


def extract_embedded(packet_text):
    """Return (fragment_text, begin_line_index) for the ONE marked region in the packet."""
    lines = packet_text.split("\n")
    begins = [i for i, ln in enumerate(lines) if ln.startswith(MARKER_BEGIN_PREFIX)]
    ends = [i for i, ln in enumerate(lines) if ln.startswith(MARKER_END_PREFIX)]
    if len(begins) != 1 or len(ends) != 1:
        raise SystemExit(f"rpc packet must contain exactly one embedded parity region "
                         f"(found {len(begins)} BEGIN / {len(ends)} END markers)")
    if ends[0] <= begins[0]:
        raise SystemExit("rpc packet parity markers are out of order")
    return "\n".join(lines[begins[0]:ends[0] + 1]), begins[0]


def check_embedded_position(packet_text):
    """The embedded region must sit INSIDE the transaction, BEFORE the ledger insert."""
    lines = packet_text.split("\n")
    begin_idx = next(i for i, ln in enumerate(lines)
                     if ln.startswith(MARKER_BEGIN_PREFIX))
    end_idx = next(i for i, ln in enumerate(lines) if ln.startswith(MARKER_END_PREFIX))
    txn_idx = next((i for i, ln in enumerate(lines) if ln.strip() == "begin;"), None)
    ledger_idx = next((i for i, ln in enumerate(lines)
                       if ln.strip().startswith(LEDGER_INSERT_LINE)), None)
    commit_idx = next((i for i, ln in enumerate(lines) if ln.strip() == "commit;"), None)
    if txn_idx is None or ledger_idx is None or commit_idx is None:
        raise SystemExit("rpc packet lost its transaction/ledger/commit structure")
    if not (txn_idx < begin_idx < end_idx < ledger_idx < commit_idx):
        raise SystemExit(
            f"embedded parity fragment is NOT inside the transaction before the ledger "
            f"insert (begin;@{txn_idx + 1}, fragment@{begin_idx + 1}..{end_idx + 1}, "
            f"ledger@{ledger_idx + 1}, commit;@{commit_idx + 1})")


def splice_embedded(packet_text, fragment):
    lines = packet_text.split("\n")
    _, begin_idx = extract_embedded(packet_text)
    end_idx = next(i for i, ln in enumerate(lines) if ln.startswith(MARKER_END_PREFIX))
    return "\n".join(lines[:begin_idx] + fragment.split("\n") + lines[end_idx + 1:])


def run_check(generated_path, rpc_packet_path):
    logical, sha = load_fixture()
    ok = True
    standalone = render_standalone(logical, sha)
    committed = generated_path.read_text(encoding="utf-8")
    if committed != standalone:
        ok = False
        print(f"STALE: {generated_path.name} != fresh generation from the fixture")
    packet_text = rpc_packet_path.read_text(encoding="utf-8")
    embedded, _ = extract_embedded(packet_text)
    fragment = render_fragment(logical, sha)
    if embedded != fragment:
        ok = False
        print(f"STALE: embedded parity region in {rpc_packet_path.name} != fresh "
              f"generation from the fixture")
    check_embedded_position(packet_text)
    if not ok:
        raise SystemExit("parity artifacts are stale — run with --write, then re-run tests")
    print(f"parity check OK: {len(logical['cases'])} cases, sha {sha}; standalone artifact "
          f"and embedded rpc-packet region both byte-identical to a fresh generation; "
          f"embedded region precedes the ledger insert inside the transaction")


def run_write(generated_path, rpc_packet_path):
    logical, sha = load_fixture()
    generated_path.write_text(render_standalone(logical, sha), encoding="utf-8",
                              newline="\n")
    packet_text = rpc_packet_path.read_text(encoding="utf-8")
    new_packet = splice_embedded(packet_text, render_fragment(logical, sha))
    check_embedded_position(new_packet)
    rpc_packet_path.write_text(new_packet, encoding="utf-8", newline="\n")
    print(f"wrote {generated_path.name} and re-embedded the parity region in "
          f"{rpc_packet_path.name}: {len(logical['cases'])} cases, sha {sha}")


def main(argv=None):
    parser = argparse.ArgumentParser(description="T4A parity fragment generator/checker")
    parser.add_argument("--check", action="store_true",
                        help="verify both parity copies are byte-identical to a fresh "
                             "generation (this is also the default action)")
    parser.add_argument("--write", action="store_true",
                        help="regenerate the standalone artifact AND re-embed the rpc "
                             "packet region (default: check only)")
    parser.add_argument("--generated", type=pathlib.Path, default=GENERATED_PATH,
                        help="standalone artifact path override (probes/tests)")
    parser.add_argument("--rpc-packet", type=pathlib.Path, default=RPC_PACKET_PATH,
                        help="rpc packet path override (probes/tests)")
    args = parser.parse_args(argv)
    if args.write and args.check:
        parser.error("--write and --check are mutually exclusive")
    if args.write:
        run_write(args.generated, args.rpc_packet)
    else:
        run_check(args.generated, args.rpc_packet)
    return 0


if __name__ == "__main__":
    sys.exit(main())
