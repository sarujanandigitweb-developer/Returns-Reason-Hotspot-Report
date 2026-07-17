# SKILL FILE — Returns Reason Hotspot Dashboard · Mismatch Title Correctness + Auto-Refresh Wiring

date: 2026-07-16

developer: Sarujanan

project: Returns Reason Hotspot Dashboard

project_code: RRHD

phase: Development - phase 03

requirement_id: REQ-01

deliverable_id: D03

status: Completed

evidence_location: /home/led-247/Returns-Reason-Hotspot-Report/ (Dashboard/index.html, scripts/refresh_dashboard.py, sql/returns_hotspot_queries.sql, backups/, logs/dashboard_refresh.log)

blos_keys_used:

- nad_min_returns          (>= 3 NAD returns to badge a strict candidate)
- nad_min_share            (>= 40% of the SKU's own returns to badge)
- nad_amazon_reason_signal (AMZ-PG-BAD-DESC)
- returns_lookback_window  (3 months)
- ebay_resolution_history_filter (res_his_order = 0)

hardcoded_thresholds:

- nad_min_returns = 3
- nad_min_share = 40%
- nad_amazon_signal = 'AMZ-PG-BAD-DESC'
- returns_lookback_window = 3 months
- ebay_variation_split = even (refund + units divided by distinct SKU count on a shared item_id)

> **BLOS GAP (carried):** NAD thresholds and the Amazon reason-signal remain hardcoded in SQL; still pending DWC ratification and a move to BLOS.

three_am_standard: TRUE

llm_queryable: TRUE

company_knowledge_candidate: TRUE

domain: Ecommerce Operations — Returns & Refunds / Listing Quality

User: DWC

Benefit status: Pass — the Mismatch Candidates section is now title-complete and, for the first time, regenerates itself on the daily refresh (deterministically), so the "not as described" review list no longer silently ages against live data. The work also surfaced a live infrastructure defect (two different databases both named order_management_copy).

---

## 1. SYSTEM STATE

Entering today, the RRHD dashboard (D01, 2026-07-14) had four auto-refreshed tabs; D02 (2026-07-15) added the "Possible Image/Listing Mismatch Candidates (NOT_AS_DESCRIBED Analysis)" 5th tab as a **static** `const MISMATCH` snapshot with 21 blank eBay titles and 9 blank Amazon titles, and it was **not** part of the daily refresh (D02 GAP-2 and GAP-4).

Today closed all three gaps: recovered the eBay titles, recovered the Amazon titles, and wired the whole section into the daily refresh — while proving the four main tables and all markup/logic stayed untouched.

---

## 2. WHAT CHANGED TODAY (4 activities)

- **D03-A01 (eBay titles):** Proved the blank eBay titles were a wrong-source-table defect and filled all 21 from `public.order_item_info.oii_item_title` with a title-only edit.
- **D03-A02 (Amazon titles):** Recovered the 9 blank Amazon titles keyed by ASIN; discovered the MCP connection now resolves to a different database than the refresh.
- **D03-A03 (verify + schedule):** Discovered/verified the refresh architecture, compared the automatic output to the Claude-built version, and configured the daily 10:00 cron with no duplicates.
- **D03-A04 (auto-refresh):** Wired `const MISMATCH` into `refresh_dashboard.py` so it regenerates from SQL every run, deterministically.

---

## 3. POSTGRESQL / MCP FINDINGS

**eBay titles live in `order_item_info`, not `listing_data`.** All 21 blank-title SKUs had a clean title in `public.order_item_info.oii_item_title` (100% coverage; counts 2–188 order lines each), while `listing_data` had a usable title for only 16/68 by SKU and 5/68 by item_id. The skill/TABLE docs never named `order_item_info` — it was found only by tracing every candidate table, not by reading the docs.

**Amazon blanks recover by ASIN, from flagged rows.** The 9 blank Amazon SKUs carry variant suffixes (`-SA`, `-UM`, `-MP`, `-SN`) that miss the `listing_data` SKU, but all 9 match by ASIN (`ref_id`). 8 of 9 exist **only** on `wrong_sku = 1` rows (the US-marketplace listing for the same ASIN); the titles are correct product descriptions. `HRBK1` has no English title in any marketplace.

**Two databases, one name.** The `mcp` path (user `postgres`) and the refresh `.env` path (user `temp_user @ 149.28.134.54:5435`) both connect to `order_management_copy`, but they are **different backends**: `temp_user` lacks `order_item_info` / `amz_fba_order_items` (only `listing_data`), while an earlier MCP session had `order_item_info`. Always verify `current_user` / `to_regclass` before trusting cross-session results.

**The Amazon listing-context CTE was silently non-deterministic.** `DISTINCT ON (ref_id, market_place)` had no full tie-break, so title and currency flipped between two consecutive refreshes for 4 ASINs. Adding tie-breakers on every selected column made it stable.

---

## 4. GAPS CLOSED / OPEN

**CLOSED — D02 GAP-2 (eBay title coverage).** 21/21 recovered from `order_item_info`.

**CLOSED — D02 GAP-3 (mojibake/foreign titles).** eBay titles now come from clean order-line text; Amazon uses English/UK-preferred, ASCII-safe selection.

**CLOSED — D02 GAP-4 (mismatch not auto-refreshed).** `const MISMATCH` now regenerates on every refresh, deterministically.

**OPEN — GAP-A (HIGH, infra): dual-backend `order_management_copy`.** MCP and the refresh `.env` resolve to different databases. New eBay SKUs cannot get titles on the refresh backend (no `order_item_info`). Reconcile / pin one authoritative backend.

**OPEN — GAP-B (carried from D01, HIGH): `temp_user` password exposed** and still not rotated.

**OPEN — GAP-C (BLOS): thresholds + reason-signal hardcoded**, DWC ratification pending.

---

## 5. VALIDATION RULES ADDED

**RULE-1 — Title-only edit proof.** A title change must alter only the title field: assert every row-diff is at the title index, no non-blank title is overwritten, and refund/count/ranking/badge aggregates are byte-identical before and after.

**RULE-2 — Deterministic regenerated block.** Two consecutive refreshes with unchanged inputs must produce a byte-identical `const MISMATCH`. Any `DISTINCT ON` or `LIMIT 1` feeding it must have a full tie-break on every selected column; any `LIMIT 1` SKU attribution must `ORDER BY` a stable key.

**RULE-3 — Verify the backend before trusting results.** Check `current_user`, `current_database`, and `to_regclass(<table>)` before depending on a table across a session; connections behind a proxy can resolve to different backends.

**RULE-4 — Carry forward what the refresh DB cannot re-source.** Because `order_item_info` is absent on the refresh backend, titles are carried forward per-SKU (then per stable id) from the previous block; only genuinely new SKUs fall back to a fresh title or blank.

---

## 6. FAILURE MODES / EDGE CASES

**Carry-forward missed a re-attributed SKU.** After wiring the refresh, the non-deterministic eBay `LIMIT 1` mapped one item_id to a different SKU than the snapshot, so its title dropped. Fixed by (a) `ORDER BY o.sku` in the lateral and (b) keying the carry-forward by the stable id (item_id/ASIN) as well as SKU.

**Regenerating from a degraded file.** The carry-forward reads titles from the current file; after a bad run that file already had blanks, so re-running could not self-heal. Restored the clean baseline backup first, then re-ran — a reminder that carry-forward needs a known-good source.

**Two genuinely-new eBay candidates stay blank.** `LDMG125B228APK` and `LDMG95E2782PK` are new NAD candidates whose item_ids were not in the snapshot; with no `order_item_info` on the refresh backend, blank is the correct, honest result.

**wrong_sku=1 is a trust decision, not an automatic fill.** For 8 Amazon blanks the only title lived on flagged (`wrong_sku=1`) US rows. Surfaced the trade-off and let the user decide (fill all) rather than silently using flagged data.

---

## 7. DECISIONS MADE TODAY

**Did not append a duplicate mismatch section.** The validated section already existed in the dashboard; appending would create duplicate truth, so the work was verify-and-wire, not re-add.

**Preferred the validated carried-forward title over the volatile query title.** Keeps known SKUs byte-stable across refreshes and preserves the D03-A01/A02 title work; only new SKUs take a fresh title.

**Made the SQL deterministic rather than accept daily reshuffle.** Added full tie-breakers and stable attribution so rankings and displayed SKUs do not churn morning to morning — consistent with the SQL file's existing determinism philosophy.

**Escalated the dual-backend finding instead of silently papering over it.** The refresh works on `temp_user`; the title-source gap for new SKUs is an infrastructure reconciliation, flagged for the owner.

---

## 8. COMPANY KNOWLEDGE EXTRACT

**Trace an attribute through every table before trusting the documented source.** The eBay title lived in an order-line table the docs never mentioned; only exhaustive tracing found it.

**Re-key by the stable identifier when a SKU-keyed lookup is blank.** Amazon titles recovered by ASIN; eBay carry-forward stabilised by item_id. A variant-suffixed SKU misses; the ASIN/item_id does not.

**A connection string is not a database identity.** Two backends can share a name (`order_management_copy`) yet differ in schema. Verify `current_user`/`to_regclass` before depending on a table.

**`DISTINCT ON` / `LIMIT 1` without a full tie-break is a latent daily-reshuffle bug.** Prove determinism by running the generator twice and comparing byte-for-byte.

**Carry forward values the refresh source cannot reproduce.** When the scheduled DB lacks the authoritative source, pin those values from the last good snapshot rather than regressing them to blank.

---

## 9. LLM STANDARD CHECK

| Check | |
|---|---|
| Terminology consistent (source-of-record, stable-id keying, tie-break, determinism, carry-forward, dual-backend) | TRUE |
| Business rules explicit and executable | TRUE — RULE-1..RULE-4 |
| Assumptions documented | TRUE — carry-forward, ASIN re-key, deterministic tie-break |
| Edge cases documented | TRUE — re-attribution miss, degraded-file re-run, new-SKU blanks, wrong_sku=1 trust |
| Evidence referenced | TRUE — 21/21 order_item_info; 9 Amazon by ASIN; determinism sha 5590a930; DATA sha df9989f8 unchanged |
| Another developer can continue independently | TRUE — refresh_dashboard.py (build_mismatch_rows / replace_const_object), sql nad_* queries |
| LLM-queryable | TRUE |

**Escalation flags:** GAP-A dual-backend `order_management_copy` (new, HIGH); GAP-B `temp_user` password rotation (carried from D01, still open). BLOS gap: NAD thresholds + Amazon reason-signal hardcoded.
