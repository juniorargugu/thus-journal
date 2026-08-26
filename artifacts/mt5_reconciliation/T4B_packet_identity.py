#!/usr/bin/env python3
"""T4B packet identity: generate and verify the migration-ledger digests.

WHY THIS EXISTS
---------------
Revision 1 recorded the ledger checksum as sha256('<version>|packet-revision-1'), computed by the
packet about itself. That token is a restatement of the version string: every byte of executable
SQL could change while the recorded identity stayed constant, which is the opposite of what a
migration checksum is for. It also carried an unrelated T3 fixture digest in
source_artifact_sha256, binding the ledger row to an artifact T4B does not implement.

THE CIRCULARITY, AND HOW IT IS RESOLVED
---------------------------------------
A packet cannot contain the hash of itself. The canonical form solves it: before hashing, the
packet's own digest field is normalised to 64 zeros, and line endings are normalised to LF. The
digest is therefore a function of everything EXCEPT the digest slot, which makes it well defined
and stable under CRLF/LF churn. Stamping the value back in does not disturb it, because the slot
is normalised away again on the next read.

  canonical_bytes := LF(file) with /'[0-9a-f]{64}',(\\s*)--\\s*T4B_CANONICAL_DIGEST_V1/
                                -> /'000…0',\\1-- T4B_CANONICAL_DIGEST_V1/
  canonical_digest := sha256(canonical_bytes)                      lowercase, ledger `checksum`
  contract_digest  := sha256(LF(T4B_1_promotion_contract_v1.md))   UPPERCASE, `source_artifact_sha256`

The ledger's own CHECK constraints require lowercase hex for checksum and uppercase hex for
source_artifact_sha256; both are produced in the required case.

ADVERSARIAL PROPERTY
--------------------
Change one byte of executable SQL while leaving the version and packet revision alone, and
`--check` fails. Probe M1 in T4B_offline_probes.sh does exactly that.

USAGE
-----
  python T4B_packet_identity.py --check     verify every digest; exit 1 on any mismatch
  python T4B_packet_identity.py --write     recompute and stamp the packets, the verifier's
                                            expected identities, and the manifest
  python T4B_packet_identity.py --print     show what the digests would be, change nothing

--write is the ONLY way these values are ever set. They are never hand-edited.
"""
from __future__ import annotations

import hashlib
import json
import pathlib
import re
import sys

HERE = pathlib.Path(__file__).resolve().parent

CONTRACT = HERE / "T4B_1_promotion_contract_v1.md"
MANIFEST = HERE / "T4B_packet_manifest_v1.json"
PACKETS = {
    "mt5_t4b_promotion_schema_v1": HERE / "T4B_promotion_schema_packet.sql",
    "mt5_t4b_promotion_rpc_v1": HERE / "T4B_promotion_rpc_packet.sql",
}
PACKET_REVISION = "6"

ZERO = "0" * 64
CANON_RE = re.compile(r"'([0-9a-f]{64})',(\s*)--(\s*)T4B_CANONICAL_DIGEST_V1")
CONTRACT_RE = re.compile(r"'([0-9A-F]{64})',(\s*)--(\s*)T4B_CONTRACT_DIGEST_V1")

# The read-only verifier carries the EXPECTED identities so it can assert exact values rather than
# merely "two distinct hashes that are not the old T3 one". It is not itself covered by any
# canonical digest, so stamping it introduces no circularity.
VERIFIER = HERE / "T4B_promotion_security_verification_packet.sql"
EXPECT_SCHEMA_RE = re.compile(r"'([0-9a-f]{64})';(\s*)--(\s*)T4B_EXPECT_SCHEMA_CHECKSUM")
EXPECT_RPC_RE = re.compile(r"'([0-9a-f]{64})';(\s*)--(\s*)T4B_EXPECT_RPC_CHECKSUM")
EXPECT_CONTRACT_RE = re.compile(r"'([0-9A-F]{64})';(\s*)--(\s*)T4B_EXPECT_CONTRACT_DIGEST")
EXPECT_BY_VERSION = {
    "mt5_t4b_promotion_schema_v1": (EXPECT_SCHEMA_RE, "T4B_EXPECT_SCHEMA_CHECKSUM"),
    "mt5_t4b_promotion_rpc_v1": (EXPECT_RPC_RE, "T4B_EXPECT_RPC_CHECKSUM"),
}


def stamp_verifier(text: str, packets: dict, contract: str, write: bool,
                   errors: list) -> str:
    """Keep the verifier's expected identities in lockstep with the packets on disk."""
    for version, entry in packets.items():
        rx, tag = EXPECT_BY_VERSION[version]
        if len(rx.findall(text)) != 1:
            errors.append(f"{VERIFIER.name}: expected exactly one {tag} slot")
            continue
        want = entry["canonical_sha256"]
        if write:
            text = rx.sub(lambda m, w=want, g=tag: f"'{w}';{m.group(2)}--{m.group(3)}{g}", text)
        elif rx.search(text).group(1) != want:
            errors.append(f"{VERIFIER.name}: {tag} does not match the packet on disk\n"
                          f"        embedded {rx.search(text).group(1)}\n"
                          f"        actual   {want}")
    if len(EXPECT_CONTRACT_RE.findall(text)) != 1:
        errors.append(f"{VERIFIER.name}: expected exactly one T4B_EXPECT_CONTRACT_DIGEST slot")
    elif write:
        text = EXPECT_CONTRACT_RE.sub(
            lambda m: f"'{contract}';{m.group(2)}--{m.group(3)}T4B_EXPECT_CONTRACT_DIGEST", text)
    elif EXPECT_CONTRACT_RE.search(text).group(1) != contract:
        errors.append(f"{VERIFIER.name}: T4B_EXPECT_CONTRACT_DIGEST does not match "
                      f"{CONTRACT.name}")
    return text


def lf(text: str) -> str:
    """Line-ending normalisation. Identity must not depend on how git checked the file out."""
    return text.replace("\r\n", "\n").replace("\r", "\n")


def sha256_text(text: str) -> str:
    return hashlib.sha256(lf(text).encode("utf-8")).hexdigest()


def canonical_form(text: str) -> str:
    """The packet with its own digest slot blanked — the only self-referential field."""
    return CANON_RE.sub(lambda m: f"'{ZERO}',{m.group(2)}--{m.group(3)}T4B_CANONICAL_DIGEST_V1",
                        lf(text))


def contract_digest() -> str:
    return sha256_text(CONTRACT.read_text(encoding="utf-8")).upper()


def compute(text: str) -> str:
    return hashlib.sha256(canonical_form(text).encode("utf-8")).hexdigest()


def stamp(text: str, canon: str, contract: str) -> str:
    text = CONTRACT_RE.sub(
        lambda m: f"'{contract}',{m.group(2)}--{m.group(3)}T4B_CONTRACT_DIGEST_V1", text)
    return CANON_RE.sub(
        lambda m: f"'{canon}',{m.group(2)}--{m.group(3)}T4B_CANONICAL_DIGEST_V1", text)


def slots_ok(name: str, text: str, errors: list[str]) -> bool:
    ok = True
    if len(CANON_RE.findall(text)) != 1:
        errors.append(f"{name}: expected exactly one T4B_CANONICAL_DIGEST_V1 slot, "
                      f"found {len(CANON_RE.findall(text))}")
        ok = False
    if len(CONTRACT_RE.findall(text)) != 1:
        errors.append(f"{name}: expected exactly one T4B_CONTRACT_DIGEST_V1 slot, "
                      f"found {len(CONTRACT_RE.findall(text))}")
        ok = False
    return ok


def main() -> int:
    mode = sys.argv[1] if len(sys.argv) > 1 else "--check"
    if mode not in ("--check", "--write", "--print"):
        print(__doc__)
        return 2

    if not CONTRACT.exists():
        print(f"FAIL  the frozen contract {CONTRACT.name} is missing")
        return 1

    contract = contract_digest()
    errors: list[str] = []
    manifest = {
        "manifest_version": "T4B_packet_manifest_v1",
        "packet_revision": PACKET_REVISION,
        "digest_domain": (
            "sha256 over LF-normalised bytes; the packet's own T4B_CANONICAL_DIGEST_V1 slot is "
            "normalised to 64 zeros before hashing"
        ),
        "source_artifact": CONTRACT.name,
        "source_artifact_sha256": contract,
        "packets": {},
    }

    for version, path in PACKETS.items():
        if not path.exists():
            errors.append(f"{path.name}: missing")
            continue
        text = path.read_text(encoding="utf-8")
        if not slots_ok(path.name, text, errors):
            continue

        if mode == "--write":
            # Stamp the contract digest first: it is part of the bytes the canonical digest covers.
            text = stamp(text, ZERO, contract)
            canon = compute(text)
            text = stamp(text, canon, contract)
            path.write_text(text, encoding="utf-8", newline="")
            print(f"WROTE {path.name}\n      canonical {canon}\n      contract  {contract}")
        else:
            canon = compute(text)
            embedded_canon = CANON_RE.search(text).group(1)
            embedded_contract = CONTRACT_RE.search(text).group(1)
            if embedded_canon != canon:
                errors.append(f"{path.name}: canonical digest drift — the executable SQL changed "
                              f"but the recorded identity did not\n"
                              f"        embedded {embedded_canon}\n"
                              f"        actual   {canon}")
            if embedded_contract != contract:
                errors.append(f"{path.name}: source-artifact digest does not match "
                              f"{CONTRACT.name}\n"
                              f"        embedded {embedded_contract}\n"
                              f"        actual   {contract}")
            if mode == "--print":
                print(f"{path.name}\n  canonical {canon}\n  contract  {contract}")

        manifest["packets"][version] = {"file": path.name, "canonical_sha256": canon}

    if VERIFIER.exists():
        vtext = stamp_verifier(VERIFIER.read_text(encoding="utf-8"), manifest["packets"],
                               contract, mode == "--write", errors)
        if mode == "--write":
            VERIFIER.write_text(vtext, encoding="utf-8", newline="")
            print(f"WROTE {VERIFIER.name} (expected identities)")
    else:
        errors.append(f"{VERIFIER.name}: missing")

    if mode == "--write":
        MANIFEST.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8", newline="")
        print(f"WROTE {MANIFEST.name}")
        if errors:
            print("T4B PACKET IDENTITY: FAIL")
            for e in errors:
                print("  - " + e)
            return 1
        return 0

    # The manifest is a third witness: packet, ledger row and manifest must all agree.
    if MANIFEST.exists():
        stored = json.loads(MANIFEST.read_text(encoding="utf-8"))
        if stored.get("source_artifact_sha256") != contract:
            errors.append(f"{MANIFEST.name}: source_artifact_sha256 does not match "
                          f"{CONTRACT.name}")
        if stored.get("packet_revision") != PACKET_REVISION:
            errors.append(f"{MANIFEST.name}: packet_revision is not {PACKET_REVISION}")
        for version, entry in manifest["packets"].items():
            if stored.get("packets", {}).get(version, {}).get("canonical_sha256") \
                    != entry["canonical_sha256"]:
                errors.append(f"{MANIFEST.name}: canonical digest for {version} disagrees with the "
                              f"packet on disk")
    else:
        errors.append(f"{MANIFEST.name}: missing — run --write")

    if errors:
        print("T4B PACKET IDENTITY: FAIL")
        for e in errors:
            print("  - " + e)
        return 1
    print("T4B PACKET IDENTITY: OK "
          f"({len(manifest['packets'])} packets bound to {CONTRACT.name})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
