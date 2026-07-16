# SKILL FILE — Returns Reason Hotspot Dashboard · "Not As Described" Mismatch Candidates

date: 2026-07-15

developer: Sarujanan

project: Returns Reason Hotspot Dashboard

project_code: RRHD

phase: Development - phase 02

requirement_id: REQ-01

deliverable_id: D02

status: Completed

evidence_location: /home/led-247/Returns-Reason-Hotspot-Report/ (Dashboard/index.html, sql/returns_hotspot_queries.sql, validation/, duplicate-risk-reports/)

blos_keys_used:

- nad_min_returns          (>= 3 NAD returns to badge a strict candidate)
- nad_min_share            (>= 40% of the SKU's own returns to badge)
- nad_amazon_reason_signal (which Amazon reason code counts as "not as described")
- returns_lookback_window  (3 months)
- ebay_resolution_history_filter (res_his_order = 0)

hardcoded_thresholds:

- nad_min_returns = 3
- nad_min_share = 40%
- nad_amazon_signal = 'AMZ-PG-BAD-DESC'   (the brief specified 'NOT_AS_DESCRIBED', which is near-empty — see GAP-1)
- returns_lookback_window = 3 months
- ebay_variation_split = even (refund + units divided by distinct SKU count on a shared item_id)

> **BLOS GAP:** the NAD threshold (3 returns / 40%) and the Amazon reason-signal choice are
> business decisions hardcoded in SQL and in the embedded dashboard data. Both should move to
> BLOS — the threshold will be tuned, and the reason-signal choice needs DWC ratification.

three_am_standard: TRUE

llm_queryable: TRUE

company_knowledge_candidate: TRUE

domain: Ecommerce Operations — Returns & Refunds / Listing Quality

User: DWC

Benefit status: Pass — the section turns "not as described" refund cost into a ranked, LLM-and-human-queryable list of listings for the design/copy team to review, and it exposed a reason-taxonomy defect and an eBay title-quality problem before either reached a team lead.

---

## 1. SYSTEM STATE

Before today, the RRHD dashboard (delivered D01, 2026-07-14) had four tabs — Amazon/eBay × Reasons/SKUs — with a validated daily PostgreSQL refresh. There was **no per-reason drill-down**. The `public.listing_data` table (product titles, prices, product types) had never been used in this project.

The D01 report already established the two load-bearing rules this deliverable reuses: `res_his_order = 0` on `ebay_returns`, and the eBay SKU bridge on `order_id + item_id` (never `order_id` alone).

---

## 2. WHAT CHANGED TODAY

**Added a "Possible Image/Listing Mismatch Candidates (NOT_AS_DESCRIBED Analysis)" section as a 5th tab inside the existing dashboard file** — not a new file. It ranks SKUs whose returns come back specifically as "not as described," a signal that the listing (photos/title/size/colour) sets the wrong expectation rather than the product being faulty.

The logic, in order:

- **Amazon:** group `amazon_returns` by SKU + ASIN + marketplace over the 3-month window; count returns whose reason is the "not as described" signal; compute that count and its share of the SKU's own returns.
- **eBay:** same, bridged to a SKU via `order_transaction` on `order_id + item_id` (the validated bridge), refund and units split evenly across variation SKUs on a shared item_id.
- **Context:** join `public.listing_data` for title/price — always `wrong_sku = 0`, eBay SKU resolved with `COALESCE(NULLIF(mapped_sku,''), sku)`, deduped to one row per listing preferring `is_child = 1`.
- **Display:** two platform sub-tabs (Amazon / eBay), each with search, column sort, and pagination; every SKU with ≥1 NAD return is listed, and rows meeting the strict threshold (≥3 NAD returns AND ≥40% of the SKU's own returns) carry a 🔴 Review Candidate badge.

The section is embedded static data (`const MISMATCH`); the daily refresh script rewrites only the four main tables (`const DATA`), so this section is a manual snapshot — documented at the top of the appended SQL.

---

## 3. POSTGRESQL / MCP FINDING

**The Amazon "not as described" signal is NOT the literal value the brief specified.** The brief filters `reason = 'NOT_AS_DESCRIBED'`. In the live 3-month window that literal value has only **33 rows and £0.00 recorded refund** — a near-empty legacy code. The real signal is **`AMZ-PG-BAD-DESC`: 194 rows, £4,642 refund**. Following the brief verbatim produces a single £0.00 Amazon candidate; using the real signal yields 3 candidates with genuine refund cost.

**eBay listing titles are extremely sparse, and keyed wrong.** `listing_data.title` for eBay (`which_channel = 2`) is populated on very few rows. Worse, resolving a title by **SKU** (rather than by the listing's **item_id**) can pull the title of a *different* eBay listing that shares the SKU — 2 candidate rows showed a title belonging to another listing than the one they linked to. The correct key is `ref_id = item_id`.

**`listing_data` is one-listing-to-many-SKU-rows.** An eBay item_id has one row per variant SKU. Joining title/price without dedup fans out; `DISTINCT ON (ref_id, market_place)` preferring `is_child` fixes it. ASIN `B0F28YR5JN` returned 6 listing rows.

**Threshold sensitivity, measured:** the `≥3` minimum count is the real filter, not the `≥40%` share. Dropping only the 40% moves Amazon 3→5; dropping the min-count moves it 3→154 (every one-off single return at 100%). No-threshold total: Amazon 175 + eBay 69 = 244 SKUs.

---

## 4. GAP FOUND

**GAP-1 (HIGH) — Amazon reason taxonomy unresolved.** `AMZ-PG-BAD-DESC` is used as the NAD signal (real, populated); the literal `NOT_AS_DESCRIBED` is near-empty. This is disclosed on the dashboard but **DWC has not ratified** which code is authoritative. It is the same open question flagged in D01.

**GAP-2 (HIGH) — eBay title coverage is incomplete.** Even after the corrected lookup, only **48 of 69** eBay candidates have a title; 21 have none in any channel. eBay `listing_data.title` is not reliably populated, so the fallback leans on the Amazon listing title for the same SKU.

**GAP-3 (MEDIUM) — foreign-language and mojibake titles.** Some `listing_data` titles are non-English (French/Italian/Spanish marketplace listings) and a few are character-corrupted (`"c?ble"` for `câble`). The eBay title picker routes around mojibake and prefers the UK/English Amazon title, but 1 genuinely-French title remains where no English alternative exists.

**GAP-4 (MEDIUM) — the mismatch section is not auto-refreshed.** The daily cron updates only the four main tables. The NAD candidates are a static embedded snapshot; they drift from the live window until re-pulled by hand.

**GAP-5 (BLOS) — thresholds and the reason-signal are hardcoded.** See metadata.

---

## 5. VALIDATION RULE ADDED OR CHANGED

**RULE-1 — NAD candidate threshold (denominator is the SKU's OWN returns)**
```
FOR each SKU:
  nad_share = (NAD returns for this SKU) / (ALL returns for this SKU)
  badge as "Review Candidate" IF nad_count >= 3 AND nad_share >= 40%
```
The share must be computed against that SKU's own returns, never against all SKUs.

**RULE-2 — eBay title resolution priority (correctness + readability)**
```
title = COALESCE(
  ebay_listing_title_by_item_id   IF not mojibake,   -- authoritative for the linked listing
  amazon_UK_title_by_sku,                             -- clean English, same product
  ebay_sibling_title_by_sku       IF not mojibake,    -- same-SKU English eBay listing
  amazon_any_marketplace_title,                       -- last resort (may be foreign)
  ebay_listing_title_by_item_id)                      -- absolute last resort (even mojibake)
```
Key on **item_id** first, not SKU — the title must describe the listing the row links to.

**RULE-3 — listing_data safety (unchanged, reasserted)**
```
ALWAYS filter wrong_sku = 0.
Resolve eBay SKU with COALESCE(NULLIF(mapped_sku,''), sku).
Dedup to one listing row (prefer is_child = 1) before joining, or metrics fan out.
```

---

## 6. FAILURE MODE OR EDGE CASE

**Empty result rendered with no structure.** eBay legitimately has 0 strict candidates (max NAD on any single SKU is 2, below the ≥3 threshold). The first build showed only a prose note — no table, no column headers. A zero-row section that omits its own columns reads as broken to a reviewer. Fixed: the table always renders its full column set with a "No qualifying candidates" row spanning it.

**Sticky-header offset pushed the table header into the middle of its own table.** I offset the table's sticky `thead` by the page-header height (`--hdr-h`). But `.twrap` has `overflow-x:auto`, which makes it its own scroll container — so `top` is measured from the table's edge, not the window's. The offset stranded rows 1–3 above a floating header. **Corrected (by the reviewer's tooling) to `top:0`** for the table header, with the page `<header>` handling page-level stickiness separately.

**Mixed currencies per row.** With 175 Amazon + 69 eBay rows across UK/DE/US/etc., Price (listing currency) and Refund (seller-refund currency) can differ within a row. Each cell self-labels its currency; nothing is summed. Honest, but must never be totalled.

**Requirement-brief SQL reintroduced the DR-001 fan-out.** The brief's eBay Step 2 joined `order_transaction` on `order_id` alone. Used the validated `order_id + item_id` bridge instead, per the project's own reconciliation rule.

---

## 7. DECISIONS MADE TODAY

**Stopped and asked before building** when the Amazon reason signal turned out wrong. Rather than silently ship the brief's £0.00 result or silently substitute `AMZ-PG-BAD-DESC`, presented both with evidence and let the user choose (chose `AMZ-PG-BAD-DESC`), then disclosed the deviation on the page itself.

**Removed the threshold on request, but kept the badge meaningful.** Showing all 244 SKUs would make a "Review Candidate" badge on every row meaningless, so the badge is reserved for the strict ≥3/≥40% signal; everything else is listed but unbadged.

**Prioritised the item_id's own title over any SKU-keyed title**, and preferred clean UK English over foreign/mojibake — because the row links to a specific eBay listing and a team lead needs a readable, correct title to identify it.

**Deferred to the reviewer's sticky-header correction.** Their CSS-only fix was more correct than my JS `--hdr-h` offset; kept theirs.

---

## 8. COMPANY KNOWLEDGE EXTRACT

**A reason/category code named in a requirement is not guaranteed to be the populated one.** Always `SELECT reason, COUNT(*)` first. Here the documented `NOT_AS_DESCRIBED` was a near-empty legacy value; the live signal was `AMZ-PG-BAD-DESC`. Requirements describe intent, not the data.

**A title/attribute must be keyed by the identifier the row links to.** The eBay row links to an item_id, so its title must come from that item_id's listing — not from any listing that merely shares the SKU. Keying context by the wrong identifier silently shows a neighbour's data.

**Prefer the channel/market-appropriate language.** A UK-facing dashboard should show English titles; foreign-marketplace listing titles and encoding-corrupted (mojibake) strings are "incorrect display" even when the underlying product is right. Build a language/quality preference into the title fallback chain.

**A zero-row section must still render its structure.** An empty table with headers and a "none found" row communicates "we checked, nothing qualified." A bare note communicates "this is broken."

**`overflow-x:auto` silently creates a vertical scroll container.** Any `position:sticky` child inside it is measured from that container, not the window — a classic sticky-header offset trap.

**Static embedded snapshots drift.** When a section is embedded rather than wired into the refresh, say so at the source — otherwise it silently ages against the live data.

---

## 9. LLM STANDARD CHECK

| Check | |
|---|---|
| Terminology consistent (signal, grain, fan-out, item_id vs SKU keying, mojibake) | TRUE |
| Business rules explicit and executable | TRUE — RULE-1..RULE-3 |
| Assumptions documented | TRUE — AMZ-PG-BAD-DESC choice, even-split, title fallback order |
| Edge cases documented | TRUE — empty-render, sticky offset, mixed currency, DR-001 |
| Evidence referenced | TRUE — 33 vs 194 rows / £0.00 vs £4,642; 48/69 titled, 0 mojibake, 2 mismatches fixed; Amazon 175 / eBay 69 |
| Another developer can continue independently | TRUE — sql/returns_hotspot_queries.sql (nad_amazon_candidates, nad_ebay_candidates), on-page disclosure |
| LLM-queryable | TRUE |

**Escalation flags:** none new. The credential-rotation escalation from D01 (`temp_user` password exposed) still stands and is unresolved. BLOS gap: NAD thresholds + Amazon reason-signal hardcoded.
