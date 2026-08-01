// ─────────────────────────────────────────────────────────────────────────────────────────────
// R0.5A MT5↔Journal reconciliation — deterministic fixture harness (read-only, no drift)
// ─────────────────────────────────────────────────────────────────────────────────────────────
// Extracts the EXACT production reconciliation core from index.html (the block between the
// `// ── <RECON-CORE>` / `// ── </RECON-CORE>` markers) and eval's it in a sandbox. The classifier
// under test is byte-for-byte the shipped code — there is NO parallel rewrite to drift against.
//
// Guarantees: no Supabase, no credentials, no network, no browser, no writes, no filesystem writes.
// Journal fixtures use PRODUCTION-STYLE product ids ("gold_next" / "s50_next") + contract codes.
//
// Run:  node ops/mt5_reconciliation/run_fixtures.mjs
// Exit: 0 = all pass, 1 = any failure.
// ─────────────────────────────────────────────────────────────────────────────────────────────
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));
const INDEX = resolve(__dirname, "..", "..", "index.html");

// ── Extract the RECON-CORE block verbatim ────────────────────────────────────────────────────
const html = readFileSync(INDEX, "utf8");
const START = "// ── <RECON-CORE>";
const END = "// ── </RECON-CORE>";
const iStart = html.indexOf(START);
const iEnd = html.indexOf(END);
if (iStart < 0 || iEnd < 0 || iEnd < iStart) {
  console.error("FIXTURES: FAIL — RECON-CORE markers not found in index.html");
  process.exit(1);
}
const coreSrc = html.slice(iStart, iEnd);

// Evaluate the extracted core in an isolated function scope and export the symbols we exercise.
const factory = new Function(
  coreSrc +
    "\nreturn { reconcileMt5Report, _reconMatchKind, _reconSizeCompatible, _reconVolEq, _reconBaseId," +
    " _reconFindSubsets, _reconReportStale, _reconSnapshotFresh, _RECON_POOL_CAP, _RECON_SUBSET_MAX };"
);
const core = factory();
const { reconcileMt5Report, _reconMatchKind, _reconSizeCompatible, _reconReportStale, _reconSnapshotFresh } = core;

// ── Tiny assert harness ──────────────────────────────────────────────────────────────────────
let pass = 0, fail = 0;
function check(name, cond, detail) {
  if (cond) { pass++; console.log("  ok   " + name); }
  else { fail++; console.log("  FAIL " + name + (detail ? "  → " + detail : "")); }
}
function counts(r) {
  return `A=${r.classA.length} D=${r.classD.length} B=${r.classB.length} amb=${r.ambiguous.length} noEv=${r.noEvidence.length} C=${r.classC.length} OOS=${r.outOfScope.length}`;
}

// ── Fixtures: products (production-shaped) ───────────────────────────────────────────────────
const P = [
  { id: "s50", baseSymbol: "S50", currentContract: "S50U26", contractSize: 200 },
  { id: "gold", baseSymbol: "GO", currentContract: "GOU26", contractSize: 300 },
];

const closedLeg = (id, cc, pid, dir, vol, entry, exit, exitDT, profit) => ({
  mt5PositionId: id, contractCode: cc, productId: pid, direction: dir, contracts: vol,
  entryPrice: entry, exitPrice: exit, openDateTime: null, exitDateTime: exitDT,
  brokerProfit: profit || 0, commission: 0, status: "closed",
});
const openLeg = (id, cc, pid, dir, vol, entry, openDT) => ({
  mt5PositionId: id, contractCode: cc, productId: pid, direction: dir, contracts: vol,
  entryPrice: entry, exitPrice: null, openDateTime: openDT, exitDateTime: null, status: "open",
});

// Production-style Journal: S50 open, GOU26 3-lot open, GOU26 5-lot closed control.
const J_MAIN = [
  { productId: "s50_next", contractCode: "S50U26", direction: "Long", contracts: 15, entryPrice: 1069.9, status: "open", openDateTime: "2026-07-01T10:00" },
  { productId: "gold_next", contractCode: "GOU26", direction: "Long", contracts: 3, entryPrice: 4222.73, status: "open", openDateTime: "2026-07-05T10:00" },
  { productId: "gold_next", contractCode: "GOU26", direction: "Long", contracts: 5, entryPrice: 4156.26, status: "closed", openDateTime: "2026-07-02T10:00", exitDateTime: "2026-07-08T21:37" },
];
const CLOSED_MAIN = [
  closedLeg("306282129", "S50U26", "s50", "Long", 15, 1069.9, 1095.00, "2026-07-20T15:00", 5000),   // → J1 (open) Class A field
  closedLeg("306282734", "GOU26", "gold", "Long", 1, 4222.73, 4098.10, "2026-07-15T21:37", -100),   // ┐
  closedLeg("306283898", "GOU26", "gold", "Long", 1, 4222.73, 4098.10, "2026-07-15T21:37", -100),   // ├ → J2 (open) Class A aggregate
  closedLeg("306310942", "GOU26", "gold", "Long", 1, 4222.73, 4098.10, "2026-07-15T21:38", -100),   // ┘
  closedLeg("306157499", "GOU26", "gold", "Long", 3, 4156.26, 4098.10, "2026-07-08T21:37", -50),    // ┐
  closedLeg("306161085", "GOU26", "gold", "Long", 1, 4156.26, 4098.10, "2026-07-08T21:37", -50),    // ├ → J3 (closed) Class D aggregate, disjoint
  closedLeg("306161739", "GOU26", "gold", "Long", 1, 4156.26, 4098.10, "2026-07-08T21:38", -50),    // ┘
];
const OPEN_MAIN = [
  openLeg("306676142", "DELTAU26", null, "Long", 1, 60, "2026-07-10T10:00"),   // SSF, no stock preset → Class B
  openLeg("308292939", "DELTAU26", null, "Long", 1, 61, "2026-07-11T10:00"),
  openLeg("310290054", "DELTAU26", null, "Long", 1, 62, "2026-07-12T10:00"),
];
const REPORT_MAIN = {
  closed: CLOSED_MAIN, open: OPEN_MAIN,
  meta: { account: "301102520", generatedAt: "2026-07-31T21:44" },
  hasPositionsSection: true, hasOpenSection: true,
};

console.log("── Production fixture (F1–F4: S50 Class A, GOU 3-lot Class A, GOU 5-lot Class D, coexist) ──");
{
  const r = reconcileMt5Report(J_MAIN, REPORT_MAIN, P);
  console.log("     " + counts(r));
  check("F1+F2 classA = 2 (S50 field + GOU aggregate)", r.classA.length === 2, counts(r));
  check("F3 classD = 1 (GOU 5-lot, disjoint)", r.classD.length === 1, counts(r));
  check("classB = 3 (DELTAU26 opens)", r.classB.length === 3, counts(r));
  check("ambiguous = 0", r.ambiguous.length === 0, counts(r));
  check("noEvidence = 0 (both current opens matched)", r.noEvidence.length === 0, counts(r));
  check("classC = 0 (all legs consumed)", r.classC.length === 0, counts(r));
  const s50 = r.classA.find(e => e.journal.contractCode === "S50U26");
  const gou3 = r.classA.find(e => e.journal.contracts === 3);
  const gou5 = r.classD[0];
  check("S50 confidence = EXACT_FIELD_MATCH", s50 && s50.confidence === "EXACT_FIELD_MATCH", s50 && s50.confidence);
  check("GOU 3-lot confidence = EXACT_AGGREGATE_MATCH (3 legs)", gou3 && gou3.confidence === "EXACT_AGGREGATE_MATCH" && gou3.legs.length === 3, gou3 && `${gou3.confidence}/${gou3.legs.length}`);
  check("GOU 5-lot confidence = EXACT_AGGREGATE_MATCH (3 legs 3+1+1)", gou5 && gou5.confidence === "EXACT_AGGREGATE_MATCH" && gou5.legs.length === 3, gou5 && `${gou5.confidence}/${gou5.legs.length}`);
  check("GOU 3-lot and 5-lot leg sets disjoint", gou3 && gou5 && gou3.legs.every(l => !gou5.legs.some(k => k.mt5PositionId === l.mt5PositionId)), "");
}

console.log("── F0: EXACT_ID_MATCH when Journal stores mt5PositionId ──");
{
  const J = [{ productId: "gold_next", contractCode: "GOU26", mt5PositionId: "306157499", direction: "Long", contracts: 5, entryPrice: 9999, status: "closed", openDateTime: "2026-07-02T10:00" }];
  // entryPrice intentionally wrong (9999) — id match must win regardless of price band.
  const r = reconcileMt5Report(J, REPORT_MAIN, P);
  const m = r.classD[0];
  check("id match classifies despite wrong entry price", !!m && m.confidence === "EXACT_ID_MATCH", m && m.confidence);
}

console.log("── F7: reverse Journal order → identical classification ──");
{
  const a = reconcileMt5Report(J_MAIN, REPORT_MAIN, P);
  const b = reconcileMt5Report([...J_MAIN].reverse(), REPORT_MAIN, P);
  check("reverse Journal: same counts", counts(a) === counts(b), `${counts(a)} vs ${counts(b)}`);
}
console.log("── F8: reverse report row order → identical classification ──");
{
  const a = reconcileMt5Report(J_MAIN, REPORT_MAIN, P);
  const rep2 = { ...REPORT_MAIN, closed: [...CLOSED_MAIN].reverse(), open: [...OPEN_MAIN].reverse() };
  const b = reconcileMt5Report(J_MAIN, rep2, P);
  check("reverse report: same counts", counts(a) === counts(b), `${counts(a)} vs ${counts(b)}`);
}

console.log("── F5: two valid equal subsets → AMBIGUOUS (MULTIPLE) ──");
{
  const J = [{ productId: "gold_next", contractCode: "GOU26", direction: "Long", contracts: 2, entryPrice: 100, status: "open", openDateTime: "2026-07-01T10:00" }];
  const closed = ["a", "b", "c", "d"].map((id, i) => closedLeg("L" + id, "GOU26", "gold", "Long", 1, 100, 98, "2026-07-05T10:0" + i, -1));
  const r = reconcileMt5Report(J, { closed, open: [], meta: { account: "1", generatedAt: "2026-07-31T21:44" }, hasPositionsSection: true, hasOpenSection: true }, P);
  check("classA/D empty", r.classA.length === 0 && r.classD.length === 0, counts(r));
  check("ambiguous = 1, reason MULTIPLE", r.ambiguous.length === 1 && r.ambiguous[0].reason === "MULTIPLE", r.ambiguous[0] && r.ambiguous[0].reason);
}

console.log("── F6: two Journal trades claim the same single leg → CONFLICT (order-independent) ──");
{
  const J = [
    { productId: "gold_next", contractCode: "GOU26", direction: "Long", contracts: 1, entryPrice: 100, status: "open", openDateTime: "2026-07-01T10:00" },
    { productId: "gold_next", contractCode: "GOU26", direction: "Long", contracts: 1, entryPrice: 100, status: "closed", openDateTime: "2026-07-01T10:00" },
  ];
  const closed = [closedLeg("Lonly", "GOU26", "gold", "Long", 1, 100, 98, "2026-07-05T10:00", -1)];
  const rep = { closed, open: [], meta: { account: "1", generatedAt: "2026-07-31T21:44" }, hasPositionsSection: true, hasOpenSection: true };
  const r = reconcileMt5Report(J, rep, P);
  const r2 = reconcileMt5Report([...J].reverse(), rep, P);
  check("no confident match", r.classA.length === 0 && r.classD.length === 0, counts(r));
  check("both trades CONFLICT", r.ambiguous.length === 2 && r.ambiguous.every(a => a.reason === "CONFLICT"), counts(r));
  check("conflict is order-independent", counts(r) === counts(r2), `${counts(r)} vs ${counts(r2)}`);
}

console.log("── F9: candidate pool over cap → SEARCH_LIMIT (fail closed) ──");
{
  const J = [{ productId: "gold_next", contractCode: "GOU26", direction: "Long", contracts: 1, entryPrice: 100, status: "open", openDateTime: "2026-07-01T10:00" }];
  const closed = Array.from({ length: core._RECON_POOL_CAP + 1 }, (_, i) => closedLeg("P" + i, "GOU26", "gold", "Long", 1, 100, 98, "2026-07-05T10:00", -1));
  const r = reconcileMt5Report(J, { closed, open: [], meta: { account: "1", generatedAt: "2026-07-31T21:44" }, hasPositionsSection: true, hasOpenSection: true }, P);
  check("pool>cap → ambiguous SEARCH_LIMIT (never a silent pick)", r.ambiguous.length === 1 && r.ambiguous[0].reason === "SEARCH_LIMIT", r.ambiguous[0] && r.ambiguous[0].reason);
}

console.log("── F10: subset-size bound reached below target → SEARCH_LIMIT (not silent no-match) ──");
{
  const need = core._RECON_SUBSET_MAX + 1;   // requires more legs than the subset bound allows
  const J = [{ productId: "gold_next", contractCode: "GOU26", direction: "Long", contracts: need, entryPrice: 100, status: "open", openDateTime: "2026-07-01T10:00" }];
  const closed = Array.from({ length: need }, (_, i) => closedLeg("S" + i, "GOU26", "gold", "Long", 1, 100, 98, "2026-07-05T10:00", -1));
  const r = reconcileMt5Report(J, { closed, open: [], meta: { account: "1", generatedAt: "2026-07-31T21:44" }, hasPositionsSection: true, hasOpenSection: true }, P);
  check("subset-bound → ambiguous SEARCH_LIMIT, not noEvidence", r.ambiguous.length === 1 && r.ambiguous[0].reason === "SEARCH_LIMIT" && r.noEvidence.length === 0, counts(r));
}

console.log("── F11: decimal volumes (epsilon, not float ==) ──");
{
  const Jm = [{ productId: "gold_next", contractCode: "GOU26", direction: "Long", contracts: 0.3, entryPrice: 100, status: "open", openDateTime: "2026-07-01T10:00" }];
  const closedM = [closedLeg("D1", "GOU26", "gold", "Long", 0.1, 100, 98, "2026-07-05T10:00", -1), closedLeg("D2", "GOU26", "gold", "Long", 0.2, 100, 98, "2026-07-05T10:01", -1)];
  const rm = reconcileMt5Report(Jm, { closed: closedM, open: [], meta: { account: "1", generatedAt: "2026-07-31T21:44" }, hasPositionsSection: true, hasOpenSection: true }, P);
  check("0.1 + 0.2 == 0.3 → aggregate match (2 legs)", rm.classA.length === 1 && rm.classA[0].legs.length === 2, counts(rm));

  const Jn = [{ productId: "gold_next", contractCode: "GOU26", direction: "Long", contracts: 0.3, entryPrice: 100, status: "open", openDateTime: "2026-07-01T10:00" }];
  const closedN = [closedLeg("N1", "GOU26", "gold", "Long", 0.1, 100, 98, "2026-07-05T10:00", -1), closedLeg("N2", "GOU26", "gold", "Long", 0.15, 100, 98, "2026-07-05T10:01", -1), closedLeg("N3", "GOU26", "gold", "Long", 0.35, 100, 98, "2026-07-05T10:02", -1)];
  const rn = reconcileMt5Report(Jn, { closed: closedN, open: [], meta: { account: "1", generatedAt: "2026-07-31T21:44" }, hasPositionsSection: true, hasOpenSection: true }, P);
  check("nearby-but-unequal decimal volume → no match (noEvidence)", rn.classA.length === 0 && rn.classD.length === 0 && rn.noEvidence.length === 1, counts(rn));
}

console.log("── F12: report freshness — missing generatedAt is stale-safe ──");
{
  const now = Date.parse("2026-07-31T22:00");
  check("missing generatedAt → stale", _reconReportStale({ generatedAt: null }, now) === true, "");
  check("generatedAt < 24h → fresh", _reconReportStale({ generatedAt: "2026-07-31T21:00" }, now) === false, "");
  check("generatedAt > 24h → stale", _reconReportStale({ generatedAt: "2026-07-01T21:00" }, now) === true, "");
  check("unparseable generatedAt → stale", _reconReportStale({ generatedAt: "not-a-date" }, now) === true, "");
}

console.log("── F13: staging snapshot freshness — newest write, never mt5_time ──");
{
  const now = Date.parse("2026-07-31T22:00");
  const fresh = _reconSnapshotFresh([{ updated_at: "2026-07-31T20:00", created_at: "2026-06-01T00:00", mt5_time: "2026-07-31T21:59" }], now);
  const stale = _reconSnapshotFresh([{ updated_at: "2026-06-10T00:00", created_at: "2026-06-01T00:00", mt5_time: "2026-07-31T21:59" }], now);
  check("recent updated_at → fresh", fresh.fresh === true, "");
  check("old snapshot → stale even if mt5_time is recent", stale.fresh === false, "");
}

console.log("── F14: contract-size / instrument-class incompatibility → no match ──");
{
  // Same base id, different contract size (stock csize 1 vs SSF csize 1000) and no contract code to fall back on.
  const Psz = [{ id: "delta_stock", _baseId: "delta", contractSize: 1 }, { id: "delta_ssf", _baseId: "delta", contractSize: 1000 }];
  const jtStock = { productId: "delta_stock", direction: "Long", contracts: 1, entryPrice: 60 };
  const legSsf = { mt5PositionId: "x", productId: "delta_ssf", direction: "Long", contracts: 1, entryPrice: 60, exitPrice: 65, exitDateTime: "2026-07-10T10:00", status: "closed" };
  check("_reconSizeCompatible(stock, ssf) = false", _reconSizeCompatible(jtStock, legSsf, Psz) === false, "");
  check("_reconMatchKind(stock, ssf) = null (base match but size differs)", _reconMatchKind(jtStock, legSsf, Psz) === null, String(_reconMatchKind(jtStock, legSsf, Psz)));
  // And with differing contract codes (DELTA stock vs DELTAU26 SSF) the code gate alone blocks it.
  check("_reconMatchKind blocks DELTA vs DELTAU26 by code", _reconMatchKind({ productId: "delta_stock", contractCode: "DELTA", direction: "Long", contracts: 1, entryPrice: 60 }, { productId: "delta_ssf", contractCode: "DELTAU26", direction: "Long", contracts: 1, entryPrice: 60 }, Psz) === null, "");
}

console.log("── F15: Class C scope split (after vs before earliest Journal date) ──");
{
  const J = [{ productId: "gold_next", contractCode: "GOU26", direction: "Long", contracts: 1, entryPrice: 4000, status: "open", openDateTime: "2026-06-01T10:00" }];
  const closed = [
    closedLeg("AFTER", "GOU26", "gold", "Long", 1, 5000, 5100, "2026-06-15T10:00", 100),   // unmatched (entry off-band), exit after adoption → Class C
    closedLeg("BEFORE", "GOU26", "gold", "Long", 1, 5000, 5100, "2026-05-01T10:00", 100),  // unmatched, exit before adoption → OUT_OF_SCOPE
  ];
  const r = reconcileMt5Report(J, { closed, open: [], meta: { account: "1", generatedAt: "2026-07-31T21:44" }, hasPositionsSection: true, hasOpenSection: true }, P);
  check("in-scope close → classC (1)", r.classC.length === 1 && r.classC[0].mt5PositionId === "AFTER", counts(r));
  check("older close → outOfScope (1)", r.outOfScope.length === 1 && r.outOfScope[0].mt5PositionId === "BEFORE", counts(r));

  const r0 = reconcileMt5Report([], { closed, open: [], meta: { account: "1", generatedAt: "2026-07-31T21:44" }, hasPositionsSection: true, hasOpenSection: true }, P);
  check("no Journal date → all unmatched are OUT_OF_SCOPE, classC empty", r0.classC.length === 0 && r0.outOfScope.length === 2, counts(r0));
}

// ── Summary ──────────────────────────────────────────────────────────────────────────────────
console.log("\n" + (fail === 0 ? "FIXTURES: PASS" : "FIXTURES: FAIL") + `  (${pass} passed, ${fail} failed)`);
process.exit(fail === 0 ? 0 : 1);
