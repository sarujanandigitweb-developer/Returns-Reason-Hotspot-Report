---
name: ppc-stock-lookup
description: "Use this skill when the user wants to find stock/inventory levels for ASINs or eBay item_ids or Shopify products that come from PPC data. All channels use ppc_performance as the source table. Covers the full bridge logic via listing_data (wrong_sku check, mapped_sku fallback) → location_wise_inv_stock or inv_final_stock filtered by warehouse location. Amazon & eBay bridge on ref_id; Shopify bridges on sku column. Applies to Amazon (which_channel=1), eBay (which_channel=2), Shopify (which_channel=3). After the mapped_sku/sku resolution there is a MANDATORY, LLM-SUPERVISED clean-SKU step that strips listing-variant suffixes (marketplace + FBA/FB + AM-family codes) down to the base inventory SKU — because a resolved value can still be a listing SKU that won't match inventory; ambiguous 1–2 letter tokens must be judged by the LLM before the stock query runs. ALSO handles ranked/bulk lookups — 'top N ASINs/SKUs by spend with their stock', and 'zero-stock / out-of-stock listings that are still spending in campaigns' — via the aggregate-first spend ranking pattern, SB exclusion for SKU/ASIN-scoped questions, LEFT-JOIN zero-stock detection, and spend de-duplication across the one-ASIN→many-SKU bridge."
---

# PPC → Stock Lookup Skill

## Overview

When a user wants stock for PPC listings, **do not use `order_transaction` as a bridge**. Use the `listing_data` table — it is the correct mapping table linking `ref_id` (ASIN / item_id) or Shopify SKU to inventory SKU, per channel and marketplace.

> ⚠️ Shopify uses a **different PPC source table grain** and a **different bridge key** — see the Shopify section below.

---

## ‼️ Decide the lookup MODE first

Before writing any SQL, classify the request into one of two modes. They use different query shapes and getting this wrong is the #1 cause of broken results.

| Mode | Trigger phrasing | Starting point | Stock is a… |
|---|---|---|---|
| **A. Single / known-ID lookup** | "stock for ASIN B0…", "stock for these item_ids", a specific list of IDs | You already know the `ref_id`(s) / `sku`(s) | **output** (just report it) |
| **B. Ranked / bulk lookup** | "top 10 by spend", "high spend", "zero stock SKUs that spend", "out-of-stock but still advertising", "which spending products have no stock" | You must **aggregate spend across the whole account first**, then discover the IDs | **filter and/or output** |

- **Mode A** → use the single-ID flow + examples (Amazon / eBay / Shopify sections below). Unchanged.
- **Mode B** → use the **Ranked & Bulk Lookups** section. This is required for "top N spend" and "zero stock" questions. Do **not** try to hand-pick ref_ids for Mode B.

---

## Channel Quick Reference

| Channel | Source Table | Bridge Key into listing_data | which_channel |
|---|---|---|---|
| Amazon | `ppc_performance` | `ref_id` | 1 |
| eBay | `ppc_performance` | `ref_id` | 2 |
| Shopify | `ppc_performance` | `sku` column (not `ref_id`) | 3 |

---

## Full Lookup Flow — Amazon & eBay (Mode A)

```
ppc_performance  (ref_id + marketplace + source + sub_source)
        ↓
   JOIN ON:
   ppc.ref_id        = listing_data.ref_id
   ppc.source        = listing_data.which_channel
   ppc.sub_source_id = listing_data.sub_source
   ppc.marketplace   = listing_data.market_place
   + wrong_sku = 0
        ↓
listing_data  (resolve SKU → mapped_sku if not NULL, else sku)
        ↓
warehouse location mapping (marketplace → UK / Germany / US)
        ↓
location_wise_inv_stock  (default, by location)
inv_final_stock          (only if specific warehouse asked)
```

---

## Step 1 — Get ref_id from PPC

From `public.ppc_performance`, extract:
- `ref_id` — ASIN (Amazon) or item_id (eBay)
- `marketplace` — used later for warehouse location mapping
- `source` — 1 = Amazon, 2 = eBay, 3 = Shopify
- `sub_source_id` — sub-source identifier

Filter: `WHERE "ref_id" != '0'`

---

## Step 2 — Look Up SKU in `listing_data`

Table: `public.listing_data`

### Key Columns

| Column | Description |
|---|---|
| `ref_id` | ASIN or eBay item_id |
| `which_channel` | 1 = Amazon, 2 = eBay |
| `market_place` | Marketplace (e.g. UK, Germany) |
| `sub_source` | Sub-source ID |
| `sku` | Listing SKU (may be a listing/variant SKU) |
| `mapped_sku` | Inventory SKU — use this if not NULL (Amazon only mismatch issue) |
| `wrong_sku` | 0 = valid, 1 = invalid — ALWAYS filter `wrong_sku = 0` |

### Lookup Rules

```
WHERE ref_id     = '<ref_id from ppc>'
  AND which_channel = <1 for Amazon, 2 for eBay>
  AND wrong_sku  = 0
```

### SKU Resolution Logic

```
IF mapped_sku IS NOT NULL AND mapped_sku != ''
    → use mapped_sku   (inventory SKU — corrected mapping)
ELSE
    → use sku          (use as-is)
```

> ⚠️ The `mapped_sku` exists because Amazon PPC listings may use a **listing SKU** that differs from the **inventory SKU** in the warehouse system. This mismatch does NOT occur for eBay or Shopify.

> 🛑 **Resolving `mapped_sku`/`sku` is NOT the final SKU.** Either value can *still* be a listing SKU carrying variant suffixes (e.g. `LSFT220BG3PK-IDE-FBA`, `12UK3P2A__AMZ`). Before you touch any stock table you MUST run the resolved value through **Step 2.5 — Clean SKU (LLM-supervised)**. Querying inventory with an un-cleaned listing SKU returns 0 rows and you will wrongly report "out of stock."

### Channel-Specific Notes

| Channel | which_channel | SKU variations | mapped_sku needed? |
|---|---|---|---|
| Amazon | 1 | Usually one SKU per ASIN | Yes — check mapped_sku always |
| eBay | 2 | Can have **multiple SKU rows** per item_id (variants) | No — use sku directly |

For eBay: collect **all valid SKUs** (all rows with `wrong_sku = 0`) and look up stock for each one individually.

---

## Step 2.5 — Clean the resolved SKU → base inventory SKU (🧑‍✈️ LLM-SUPERVISED)

The value from Step 2 may still be a **listing SKU** with one or more trailing variant suffixes. Strip it down to the **base inventory SKU** before any stock query. This step is **supervised**: the deterministic stripper below handles the clear cases, but ambiguous tokens MUST be confirmed by the LLM — do not blind-run it and pass the output straight into the stock table.

### What counts as a strippable suffix

A suffix is the token after the **last** `_`, `-`, or space. Strip it only if it is one of:

| Family | Matches | Examples |
|---|---|---|
| Marketplace short code | 1–2 uppercase letters | `UK`, `DE`, `CA`, `FR`, `IT`, `ES`, `NL` |
| Marketplace 3-letter | exactly `ADE`, `AFR` | `ADE`, `AFR` |
| FBA / FB family | `FB` + one letter | `FBA`, `FBM`, `FBE` |
| AM family | `AM` + 0–4 alphanumerics | `AM`, `AMZ`, `AMUK`, `AM123` |

Rules:
- **Separator priority: `_` first, then `-`, then space.** Underscore is checked first because a mid-SKU hyphen segment (e.g. `-JK`, `-LV`) is part of the *base* SKU and must NOT be stripped when an underscore suffix is also present.
- **Run up to two passes** to catch double suffixes, e.g. `LSFT220BG3PK-IDE-FBA` → strip `-FBA` → strip `-IDE` → `LSFT220BG3PK`.
- **Trailing-junk trim:** remove any dangling `_` or space left behind (e.g. `12UK3P2A__` → `12UK3P2A`).
- **`amzn.gr.*`** → no inventory equivalent (platform alias). Return nothing and exclude from the stock lookup.
- **Combo SKUs keep `+`** — `+` marks a bundle and is never a separator (e.g. `CRSF100BM+PHTT1PBRBM` stays intact).
- **No separator present** → already a base SKU, use as-is.

### ⚠️ Where the LLM MUST supervise (do not trust the regex blindly)

The 1–2 letter rule is **ambiguous**. A trailing `-DE` is almost certainly a marketplace code to strip; a trailing `-JK` or `-LV` may be a genuine part of the base SKU. The deterministic stripper cannot tell them apart. So:

1. Run the stripper to get a **candidate** base SKU.
2. **LLM judgement:** does the stripped token look like a real marketplace/fulfillment suffix, or like a base-SKU component? If unsure, keep the longer (less-stripped) form as a second candidate.
3. **Verify against inventory** before committing: query the stock table for the candidate(s). The candidate that returns an inventory row is the correct base SKU. If the cleaned candidate returns **0 rows but the original did too**, reconsider — you may have over-stripped (a real `-JK` removed) or under-stripped.
4. Only after a candidate is confirmed (or genuinely confirmed absent from inventory) do you report stock. A "0 / out of stock" verdict is only valid once the SKU is confirmed to be a true base inventory SKU — never off an un-verified strip.

### Deterministic helper (first pass — supervise the output)

```python
import re

# Suffix allowlist: AM-family | FB-family | ADE/AFR | 1–2 letter marketplace codes
_SUFFIX_RE = re.compile(r'^(AM[A-Z0-9]{0,4}|FB[A-Z]|ADE|AFR|[A-Z]{1,2})$')

def _strip_one_pass(sku: str) -> str:
    for sep in ('_', '-', ' '):          # underscore first (protects mid-SKU hyphens)
        if sep not in sku:
            continue
        token = sku.rsplit(sep, 1)[-1].strip()
        if _SUFFIX_RE.match(token):
            return sku.rsplit(sep, 1)[0].rstrip('_').strip()
    return sku

def resolve_base_sku(raw_sku: str) -> str | None:
    if not raw_sku or not raw_sku.strip():
        return None
    sku = raw_sku.strip()
    if sku.startswith('amzn.gr.'):        # platform alias — no inventory match
        return None
    if not re.search(r'[-_ ]', sku):      # already clean (+ combos allowed)
        return sku
    sku = _strip_one_pass(sku)            # pass 1
    if re.search(r'[-_ ]', sku):
        sku = _strip_one_pass(sku)        # pass 2 — double suffixes
    sku = sku.rstrip('_').strip()
    return sku or None
```

> This is the **first pass only**. Its 1–2 letter rule will sometimes over-strip a real base component — that is exactly why the verify-against-inventory checkpoint above is mandatory.

---

## Step 3 — Map PPC Marketplace → Warehouse Location

`inv_final_stock` is filtered by `warehouse_location`; `location_wise_inv_stock` by `location`. Use this mapping from PPC `marketplace`:

| PPC Marketplace | warehouse_location / location |
|---|---|
| UK | UK |
| US, Canada, Mexico | US |
| Germany, France, Spain, Italy, Austria, Netherlands, Belgium, Belgium_Dutch, Belgium_French, Poland, Sweden, Switzerland, Saudi Arabia, United Arab Emirates, Ireland | Germany |

---

## Step 4 — Choose the Right Stock Table

| User asks for... | Table to use |
|---|---|
| Stock by **location / region** (e.g. "UK stock", "Germany stock") | `public.location_wise_inv_stock` |
| Stock by **warehouse** (e.g. "UK Unit3", "Duisburg warehouse") or general stock | `public.inv_final_stock` |

> **Default:** If the user does not mention a specific warehouse, use `location_wise_inv_stock` first.

### Table A — `public.location_wise_inv_stock` (Location Level)

| Column | Type | Description |
|---|---|---|
| `id` | bigint | Primary key |
| `sku` | text | SKU |
| `stock` | bigint | Stock quantity at this location |
| `location` | text | `UK`, `Germany`, `US` |
| `updated_at` | timestamp | Last updated timestamp |

```sql
SELECT "sku", SUM(COALESCE("stock", 0)) AS total_stock
FROM public.location_wise_inv_stock
WHERE "sku" IN (<resolved SKU(s)>)
  AND "location" = '<mapped location>'
GROUP BY "sku"
```

### Table B — `public.inv_final_stock` (Warehouse Level)

Use **only** when the user explicitly asks about a specific warehouse.

```sql
SELECT "sku", "warehouse_name", SUM(COALESCE("stock", 0)) AS total_stock
FROM public.inv_final_stock
WHERE "sku" IN (<resolved SKU(s)>)
  AND "warehouse_location" = '<mapped location>'
GROUP BY "sku", "warehouse_name"
```

If zero rows returned → SKU not stocked in that location; report as 0.

---

# ⭐ Ranked & Bulk Lookups (Mode B) — Top-N Spend & Zero-Stock

This section handles the two questions the single-ID flow cannot:

1. **"Top N ASINs/SKUs by spend, and their stock"** — stock is decoration.
2. **"Zero-stock / out-of-stock SKUs that are still spending in campaigns"** — stock is the **filter**.

The mental model flips: you do **not** know the IDs up front. You **aggregate spend across the whole account first**, then bridge the entire result set to stock, then rank/filter.

## Mode B golden rules (read before writing SQL)

1. **Aggregate spend first, rank/limit LAST.** Build a `ppc_spend` CTE grouped by ASIN; apply `ORDER BY spend DESC LIMIT N` only in the final SELECT, after the stock join.
2. **Exclude SB for any SKU/ASIN-scoped question.** Join `ppc` and filter `p.record_subtype != 'SB'`. SB maps only one representative ASIN to a multi-ASIN campaign, so its spend cannot be attributed to a SKU.
3. **Drop non-product SKUs in the spend CTE:** `sku != '0'` and `sku NOT LIKE 'amzn.gr.%'`.
4. **"which spend in campaigns" → `HAVING SUM(pp.spend) > 0`.** Only listings that actually spent in the window.
5. **Zero-stock MUST use `LEFT JOIN` + `COALESCE(stock,0) = 0`.** A SKU with *no* stock record is the most common true zero — an `INNER JOIN` silently deletes it and produces a wrong, short list. This is the single biggest source of "mess."
6. **Never SUM spend after the bridge.** One ASIN explodes into multiple `listing_data`/inventory SKU rows; summing spend across them multiplies it. Compute **spend per ASIN** and **stock per ASIN** in separate CTEs, then join once at the end.
7. **Zero-stock for a multi-SKU ASIN = ALL its resolved inventory SKUs total to 0** (i.e. `SUM` of stock across resolved SKUs `= 0`).
8. **Account filter is `ss_name`** (e.g. `ss_name = 'amazon Ledsone'` for "ledsone"), `marketplace` for the region, `source` for the channel.
9. **The resolved bridge SKU is not the final SKU — clean it (Step 2.5) under supervision.** For bulk runs this means the resolution is **two-phase**: (phase 1) aggregate spend + bridge to get the distinct *resolved* SKUs; (phase 2, supervised) clean each to a base SKU and confirm it against inventory; then feed the **verified base SKUs** into the stock join. Do not collapse this into a single blind CTE that trusts `COALESCE(mapped_sku, sku)` — an un-cleaned listing SKU silently returns 0 and falsely lands in the "zero-stock" list.

## Output-grain note (resolves the "top10 sku" ambiguity)

"Top 10 SKU" is ambiguous because spend lives at the ASIN/listing-SKU grain while stock lives at the inventory-SKU grain, and the bridge is many-to-many.
- **Default to ASIN-anchored rows** (one row per advertised ASIN): show the ASIN, its resolved inventory SKU(s), its spend, and its summed stock. For Amazon this is effectively SKU-level because Amazon is usually one SKU per ASIN.
- Only roll up to a pure inventory-SKU grain if the user explicitly asks for it — and then state that spend from multiple ASINs sharing a SKU has been summed.

---

## Full Mode-B Example — Amazon, "zero-stock top 10 SKUs that spend, ledsone UK, last 7 days"

```sql
WITH ppc_spend AS (                      -- (1) spend per ASIN, account-wide, SB excluded
    SELECT
        pp.ref_id        AS asin,
        pp.marketplace,
        pp.sub_source_id,
        SUM(pp.spend)    AS spend_7d,
        SUM(pp.sales)    AS sales_7d,
        SUM(pp.clicks)   AS clicks_7d
    FROM public.ppc_performance pp
    JOIN public.ppc p
      ON p.parent_id        = pp.parent_id
     AND p.record_main_type = 'campaign'
    WHERE pp.source        = 1                 -- Amazon
      AND pp.record_type   = 'ad'              -- only Amazon grain
      AND pp.marketplace   = 'UK'
      AND pp.ss_name       = 'amazon Ledsone'  -- ledsone account
      AND p.record_subtype <> 'SB'             -- exclude SB (SKU-scoped question)
      AND pp.ref_id        <> '0'
      AND pp.sku           <> '0'
      AND pp.sku NOT LIKE 'amzn.gr.%'
      AND pp.date >= CURRENT_DATE - INTERVAL '7 days'
    GROUP BY pp.ref_id, pp.marketplace, pp.sub_source_id
    HAVING SUM(pp.spend) > 0                    -- "which spend in campaigns"
),
asin_skus AS (                            -- (2) bridge each ASIN → RESOLVED (not yet clean) SKU(s)
    SELECT DISTINCT
        ps.asin,
        COALESCE(NULLIF(ep.mapped_sku, ''), ep.sku) AS resolved_sku
    FROM ppc_spend ps
    JOIN public.listing_data ep
      ON ep.ref_id        = ps.asin
     AND ep.which_channel = 1
     AND ep.market_place  = ps.marketplace
     AND ep.sub_source    = ps.sub_source_id
     AND ep.wrong_sku     = 0
),
-- ┌─────────────────────────────────────────────────────────────────────┐
-- │ 🧑‍✈️ SUPERVISED CHECKPOINT (Step 2.5) — DO NOT SKIP                    │
-- │ The asin_skus CTE above gives RESOLVED listing SKUs, which may still  │
-- │ carry suffixes. Materialise SELECT DISTINCT resolved_sku, run each    │
-- │ through resolve_base_sku(), and CONFIRM each base SKU exists in       │
-- │ location_wise_inv_stock. Build the verified mapping below from that   │
-- │ confirmed output. Only then run the stock join.                       │
-- └─────────────────────────────────────────────────────────────────────┘
clean_map AS (                            -- (2.5) resolved_sku → verified base inventory SKU
    -- Populate from the supervised clean+verify step (one row per resolved_sku).
    -- Example shape — replace with the confirmed pairs:
    SELECT * FROM (VALUES
        ('LSFT220BG3PK-IDE-FBA', 'LSFT220BG3PK'),
        ('12UK3P2A__AMZ',        '12UK3P2A')
        -- ('CRSF100BM+PHTT1PBRBM', 'CRSF100BM+PHTT1PBRBM')  -- combo kept intact
    ) AS m(resolved_sku, base_sku)
),
loc_stock AS (                            -- (3) UK stock per BASE inventory SKU
    SELECT sku, SUM(COALESCE(stock, 0)) AS sku_stock
    FROM public.location_wise_inv_stock
    WHERE location = 'UK'
    GROUP BY sku
),
asin_stock AS (                           -- (4) roll stock up to ASIN (LEFT JOIN keeps true zeros)
    SELECT
        a.asin,
        STRING_AGG(DISTINCT COALESCE(cm.base_sku, a.resolved_sku), ', ') AS inv_skus,
        SUM(COALESCE(s.sku_stock, 0))                                    AS uk_stock
    FROM asin_skus a
    LEFT JOIN clean_map cm ON cm.resolved_sku = a.resolved_sku
    LEFT JOIN loc_stock s  ON s.sku = COALESCE(cm.base_sku, a.resolved_sku)
    GROUP BY a.asin
)
SELECT                                    -- (5) join once, filter zero, rank, limit
    ps.asin,
    ast.inv_skus,
    ps.spend_7d,
    ps.sales_7d,
    ps.clicks_7d,
    COALESCE(ast.uk_stock, 0) AS uk_stock
FROM ppc_spend ps
LEFT JOIN asin_stock ast ON ast.asin = ps.asin
WHERE COALESCE(ast.uk_stock, 0) = 0       -- ZERO-STOCK filter (incl. no-record SKUs)
ORDER BY ps.spend_7d DESC
LIMIT 10;
```

### The sister query — "Top 10 ASINs by spend + their stock" (stock NOT a filter)

Identical CTEs; only the final SELECT changes — **drop the `WHERE uk_stock = 0`** so stock is reported, not filtered:

```sql
SELECT ps.asin, ast.inv_skus, ps.spend_7d, COALESCE(ast.uk_stock, 0) AS uk_stock
FROM ppc_spend ps
LEFT JOIN asin_stock ast ON ast.asin = ps.asin
ORDER BY ps.spend_7d DESC
LIMIT 10;
```

> Run both with the **same** `ppc_spend` CTE to present the two lists side by side (covered vs. burning-spend-while-out-of-stock).

---

## Mode-B notes for eBay & Shopify

- **eBay (source = 2):** `record_type = 'ad'` exists only for `COST_PER_SALE`; `ON_SITE` is campaign-grain with no `ref_id`/SKU — exclude `ON_SITE` from SKU-level zero-stock rankings or state it can't be SKU-attributed. One item_id legitimately maps to many SKU rows (variants); the multi-SKU zero-stock rule (ALL variants sum to 0) is essential here.
- **Shopify (source = 3):** bridge on the `ppc_performance.sku` column → `listing_data.ref_id` with `which_channel = 3`; filter `sku <> '0'` instead of `ref_id`.
- SB exclusion is Amazon-only (`record_subtype` is an Amazon attribute).

---

## ⚠️ Live-stock disclaimer (Mode A and B)

`location_wise_inv_stock` and `inv_final_stock` hold **current live stock only** — there are no historical snapshots. When the question carries a date window (e.g. "last 7 days"), the spend is windowed but the stock is **as of today**. State this in the output: a "zero-stock" result reflects today's inventory against the windowed spend, not stock as it was during the window.

---

## SQL Rules (all modes)

- Always `wrong_sku = 0` on `listing_data` — never skip.
- Always resolve `mapped_sku` before using `sku` (`COALESCE(NULLIF(mapped_sku,''), sku)`).
- **Always clean the resolved SKU (Step 2.5) before any stock query, and supervise it** — strip marketplace/FBA/AM suffixes to the base inventory SKU, judge ambiguous 1–2 letter tokens, and confirm the base SKU against inventory. Never report stock (especially "zero stock") off an un-cleaned or unverified listing SKU.
- Always filter stock tables by location/warehouse — never return global stock for a marketplace query.
- Always `SUM(COALESCE("stock", 0))` — never bare SUM.
- For eBay/multi-SKU: collect ALL valid SKU rows and look up each.
- **Mode B specifics:** aggregate spend first / rank last; exclude `SB` for SKU/ASIN questions; drop `sku='0'` and `amzn.gr.*`; `HAVING SUM(spend)>0` for "which spend"; **`LEFT JOIN` for zero-stock**; compute spend and stock in separate CTEs to avoid bridge-fanout inflation.
- **No `ROUND(double precision, int)`** — cast to numeric first (`(...)::numeric`), use `TRUNC` for decimals.
- Execute via `postgres:execute_sql` — never present SQL alone as the final answer.
