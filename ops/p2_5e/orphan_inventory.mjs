#!/usr/bin/env node
// ============================================================================
// P2-5-E  Phase A — trade-images Storage ORPHAN INVENTORY  (READ-ONLY DRY-RUN)
// ----------------------------------------------------------------------------
// Out-of-band ADMIN tool. Run LOCALLY on Junior's PC only. Uses the Supabase
// service_role key from the environment — NEVER ship this key (or this script's
// privileges) to the browser, app runtime, or Netlify/client code.
//
// WHAT IT DOES (and ONLY this):
//   1. Reads every trades row's `raw` (service_role bypasses RLS) and builds the
//      exact-path REFERENCE SET — the only safe orphan predicate (see below).
//   2. Recursively LISTS objects in the private `trade-images` bucket (read-only).
//   3. Classifies each object: referenced / orphan-candidate / malformed and
//      labels orphan candidates by the 7-day retention window.
//   4. Prints a counts + capped-sample report. Optional --out writes the same
//      report as JSON to a LOCAL file.
//
// WHAT IT NEVER DOES (Phase A has NO deletion path — by design):
//   - No object delete. No object upload. No object overwrite/move.
//   - No SQL. No schema/policy change. No writes to Supabase of any kind.
//   - No image-content download. No logging of raw JSON or signed URLs.
//   The only network calls are: GET /rest/v1/trades (read) and
//   POST /storage/v1/object/list/<bucket> (the read-only enumeration endpoint).
//
// ORPHAN PREDICATE (the design lock reviewed in P2-5-E):
//   An object is an orphan-candidate ONLY IF its EXACT path string is referenced
//   by NO trades row anywhere. We do NOT use "the {tradeId} folder segment no
//   longer has a trade" — handleDuplicate copies image PATH refs into a new trade
//   id (and externalizeTradeImages skips existing paths), so one object can be
//   referenced by a trade whose id differs from the path's tradeId segment.
//   Using folder/id existence would delete a LIVE image. Exact-reference only.
//
// DELETION is a SEPARATE, GATED Phase C (its own service_role script, --dry-run
// default, fresh review). This file intentionally contains no part of it.
//
// Usage:
//   SUPABASE_URL=... SUPABASE_SERVICE_KEY=...  node ops/p2_5e/orphan_inventory.mjs [--out report.json] [--retention-days N>=7]
// ============================================================================

import { argv, env, exit } from "node:process";
import { writeFileSync } from "node:fs";

const BUCKET = "trade-images";
const SAMPLE_CAP = 20;            // cap on sample paths printed/recorded per category
const TRADES_PAGE = 200;          // raw can carry legacy base64 → keep pages modest
const LIST_PAGE = 1000;

// Strict 4-segment convention: {uid}/{tradeId}/{pre|post}/{imageId}.{ext}
const STRICT_PATH_RE = /^[A-Za-z0-9_-]+\/[A-Za-z0-9_-]+\/(?:pre|post)\/[A-Za-z0-9_-]+\.(?:jpg|jpeg|png|webp|gif)$/i;
// Non-anchored scanners for extracting refs out of a stringified raw blob.
// A literal "." before the ext + "_"/"-" charset never appear inside standard
// base64 image data, so scanning raw (incl. base64) cannot yield a false ref.
const PATH_SCAN_RE = /[A-Za-z0-9_-]+\/[A-Za-z0-9_-]+\/(?:pre|post)\/[A-Za-z0-9_-]+\.(?:jpg|jpeg|png|webp|gif)/gi;
// Defensive: paths embedded inside any /object/sign|public/trade-images/<path> URL.
const URL_EMBED_RE = /\/trade-images\/([^"'\s?#\\)]+)/gi;

function die(msg) { console.error("ERROR: " + msg); exit(1); }

// ---- args -----------------------------------------------------------------
const args = argv.slice(2);
if (args.includes("--help") || args.includes("-h")) {
  console.log("P2-5-E Phase A orphan inventory (READ-ONLY). Flags: --out <file.json>  --retention-days <N>=7>  --help");
  exit(0);
}
function argVal(name, dflt) { const i = args.indexOf(name); return i >= 0 && args[i + 1] ? args[i + 1] : dflt; }
const OUT = argVal("--out", null);
let RETENTION_DAYS = parseInt(argVal("--retention-days", "7"), 10);
if (!Number.isFinite(RETENTION_DAYS) || RETENTION_DAYS < 7) {
  console.warn(`[note] retention-days clamped to 7 (policy floor for live cleanup; never lower for normal use). got=${argVal("--retention-days", "7")}`);
  RETENTION_DAYS = 7;
}

// ---- env / auth -----------------------------------------------------------
const SUPABASE_URL = (env.SUPABASE_URL || "").replace(/\/+$/, "");
const SERVICE_KEY = env.SUPABASE_SERVICE_KEY || env.SUPABASE_SERVICE_ROLE_KEY || "";
if (!SUPABASE_URL) die("SUPABASE_URL env var not set");
if (!SERVICE_KEY) die("SUPABASE_SERVICE_KEY env var not set (service_role; LOCAL/admin only — never ship to browser)");
const H = { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}` };

// ---- 1) reference set from all trades.raw ---------------------------------
async function buildReferenceSet() {
  const refs = new Set();
  let offset = 0, totalRows = 0;
  for (;;) {
    const url = `${SUPABASE_URL}/rest/v1/trades?select=id,raw&order=id.asc&limit=${TRADES_PAGE}&offset=${offset}`;
    const res = await fetch(url, { headers: { ...H, Accept: "application/json" } });
    if (!res.ok) die(`trades read failed: HTTP ${res.status} ${await safeText(res)}`);
    const rows = await res.json();
    if (!Array.isArray(rows) || rows.length === 0) break;
    for (const row of rows) {
      totalRows++;
      let s = "";
      try { s = typeof row.raw === "string" ? row.raw : JSON.stringify(row.raw ?? ""); } catch { s = ""; }
      let m;
      PATH_SCAN_RE.lastIndex = 0;
      while ((m = PATH_SCAN_RE.exec(s))) refs.add(m[0]);
      URL_EMBED_RE.lastIndex = 0;
      while ((m = URL_EMBED_RE.exec(s))) {
        let p = m[1];
        try { p = decodeURIComponent(p); } catch { /* keep raw on bad encoding */ }
        p = p.split("?")[0].split("#")[0];
        if (STRICT_PATH_RE.test(p)) refs.add(p);
      }
    }
    if (rows.length < TRADES_PAGE) break;
    offset += TRADES_PAGE;
  }
  return { refs, totalRows };
}

// ---- 2) recursive read-only listing of the bucket -------------------------
async function listAllObjects() {
  const objects = []; // {path, size, created}
  async function listPrefix(prefix) {
    let offset = 0;
    for (;;) {
      const res = await fetch(`${SUPABASE_URL}/storage/v1/object/list/${BUCKET}`, {
        method: "POST",
        headers: { ...H, "Content-Type": "application/json" },
        body: JSON.stringify({ prefix, limit: LIST_PAGE, offset, sortBy: { column: "name", order: "asc" } }),
      });
      if (!res.ok) die(`storage list failed at "${prefix}": HTTP ${res.status} ${await safeText(res)}`);
      const items = await res.json();
      if (!Array.isArray(items) || items.length === 0) break;
      for (const it of items) {
        const full = prefix + it.name;
        if (it.id == null) { await listPrefix(full + "/"); continue; } // folder → recurse
        const size = (it.metadata && (it.metadata.size ?? it.metadata.contentLength)) || 0;
        const created = it.created_at || (it.metadata && it.metadata.lastModified) || null;
        objects.push({ path: full, size, created });
      }
      if (items.length < LIST_PAGE) break;
      offset += LIST_PAGE;
    }
  }
  await listPrefix("");
  return objects;
}

// ---- 3) classify (NO deletion — labels only) ------------------------------
function classify(objects, refs) {
  const nowMs = Date.now();
  const retentionMs = RETENTION_DAYS * 86400000;
  const out = { referenced: [], orphanEligible: [], orphanWithinRetention: [], malformed: [] };
  for (const o of objects) {
    if (!STRICT_PATH_RE.test(o.path)) { out.malformed.push(o); continue; }   // report-only forever
    if (refs.has(o.path)) { out.referenced.push(o); continue; }              // exact-reference → LIVE
    const createdMs = o.created ? Date.parse(o.created) : NaN;
    const ageOk = Number.isFinite(createdMs) ? (nowMs - createdMs) >= retentionMs : false; // unknown age → conservative (within-retention)
    (ageOk ? out.orphanEligible : out.orphanWithinRetention).push(o);
  }
  return out;
}

// ---- helpers --------------------------------------------------------------
async function safeText(res) { try { return (await res.text()).slice(0, 200); } catch { return ""; } }
function sumBytes(list) { return list.reduce((s, o) => s + (Number(o.size) || 0), 0); }
function human(n) { const u = ["B", "KB", "MB", "GB"]; let i = 0, v = n; while (v >= 1024 && i < u.length - 1) { v /= 1024; i++; } return `${v.toFixed(i ? 1 : 0)} ${u[i]}`; }
function samplePaths(list) { return list.slice(0, SAMPLE_CAP).map((o) => o.path); }

// ---- main -----------------------------------------------------------------
(async () => {
  console.log("== P2-5-E Phase A — trade-images orphan inventory (READ-ONLY DRY-RUN) ==");
  console.log(`project: ${SUPABASE_URL.replace(/^https?:\/\//, "").split(".")[0]}   bucket: ${BUCKET}   retention: ${RETENTION_DAYS}d`);
  const { refs, totalRows } = await buildReferenceSet();
  const objects = await listAllObjects();
  const c = classify(objects, refs);

  const report = {
    kind: "p2_5e_phase_a_orphan_inventory",
    readOnly: true,
    bucket: BUCKET,
    retentionDays: RETENTION_DAYS,
    tradesScanned: totalRows,
    distinctReferencedPaths: refs.size,
    totals: {
      objects: objects.length,
      referenced: c.referenced.length,
      orphanCandidates: c.orphanEligible.length + c.orphanWithinRetention.length,
      orphanEligible_retentionPassed: c.orphanEligible.length,
      orphanWithinRetention_wouldBeSkipped: c.orphanWithinRetention.length,
      malformed_reportOnly: c.malformed.length,
    },
    bytes: {
      orphanEligible: sumBytes(c.orphanEligible),
      orphanWithinRetention: sumBytes(c.orphanWithinRetention),
      malformed: sumBytes(c.malformed),
    },
    samples: {
      orphanEligible: samplePaths(c.orphanEligible),
      orphanWithinRetention: samplePaths(c.orphanWithinRetention),
      malformed: samplePaths(c.malformed),
    },
  };

  console.log("\n--- TOTALS ---");
  console.log(`trades scanned ............. ${report.tradesScanned}`);
  console.log(`distinct referenced paths .. ${report.distinctReferencedPaths}`);
  console.log(`objects in bucket .......... ${report.totals.objects}`);
  console.log(`  referenced (LIVE) ........ ${report.totals.referenced}`);
  console.log(`  orphan-candidates ........ ${report.totals.orphanCandidates}`);
  console.log(`    retention-passed (≥${RETENTION_DAYS}d)  ${report.totals.orphanEligible_retentionPassed}   [${human(report.bytes.orphanEligible)}]`);
  console.log(`    within-retention (<${RETENTION_DAYS}d)  ${report.totals.orphanWithinRetention_wouldBeSkipped}   [${human(report.bytes.orphanWithinRetention)}]`);
  console.log(`  malformed (report-only) .. ${report.totals.malformed_reportOnly}   [${human(report.bytes.malformed)}]`);

  const showSample = (label, paths) => { if (paths.length) { console.log(`\n${label} (sample, capped ${SAMPLE_CAP}):`); paths.forEach((p) => console.log("  " + p)); } };
  showSample("orphan-candidates: retention-passed", report.samples.orphanEligible);
  showSample("orphan-candidates: within-retention", report.samples.orphanWithinRetention);
  showSample("malformed (NEVER auto-delete)", report.samples.malformed);

  console.log("\nREAD-ONLY: nothing was deleted, uploaded, or modified. Deletion is a separate, gated Phase C.");
  if (OUT) { writeFileSync(OUT, JSON.stringify(report, null, 2)); console.log(`report written: ${OUT} (paths only — no raw JSON, no signed URLs, no image content)`); }
})().catch((e) => die(e && e.message ? e.message : String(e)));
