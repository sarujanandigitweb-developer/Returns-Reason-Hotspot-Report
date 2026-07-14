# Table Definition: `public.ppc`, `public.ppc_performance`, `public.ppc_etl_change_log`, `public.ppc_etl_automation_log`, `public.ppc_targeting_performance`, `public.google_merchant_products` & `public.google_merchants`

## ⚠️ Execution Requirement
After generating any SQL against this table, **always execute it immediately using `postgres:execute_sql`** and return the real query results to the user. Never present a SQL query alone as the final answer.

---

## 🚫 CRITICAL — NEVER COMBINE eBay ON_SITE + COST_PER_SALE

> **This rule has NO exceptions. Violating it produces misleading, analytically invalid results.**

eBay Advanced (ON_SITE / CPC) and Standard (COST_PER_SALE / CPS) campaigns use **fundamentally different pricing models** — their spend, sales, and orders figures are **not comparable and must never be summed together**.

| Strategy | DB value | Charged on | Why combining is wrong |
|---|---|---|---|
| Advanced / CPC | `ON_SITE` | Per click — fixed cost regardless of sale | Spend is independent of sales |
| Standard / CPS | `COST_PER_SALE` | % of sale — only when a sale occurs | Spend is mechanically tied to sales |

### The rule in practice

- **"Show me eBay spend"** → return TWO rows: one for Advanced, one for Standard. Never one combined row.
- **"Show me total eBay performance"** → still split by strategy. Add a note explaining why.
- **"Can you combine them?"** → return both separately and explain the combination is invalid.
- **Cross-platform tables** (Amazon vs eBay vs Google) → eBay must appear as two rows, not one.

### ❌ ALWAYS WRONG
```sql
-- DO NOT DO THIS — mixes incompatible metric definitions
SELECT SUM(pp.spend), SUM(pp.sales)
FROM public.ppc_performance pp
WHERE pp.source = 2;
```

### ✅ ALWAYS RIGHT
```sql
SELECT
    CASE p.record_subtype
        WHEN 'ON_SITE'       THEN 'Advanced (CPC)'
        WHEN 'COST_PER_SALE' THEN 'Standard (CPS)'
        ELSE p.record_subtype
    END AS strategy,
    SUM(pp.impressions) AS impressions,
    SUM(pp.clicks)      AS clicks,
    SUM(pp.spend)       AS spend,
    SUM(pp.sales)       AS sales,
    SUM(pp.orders)      AS orders,
    SUM(pp.spend) / NULLIF(SUM(pp.sales), 0) * 100 AS acos,
    SUM(pp.sales) / NULLIF(SUM(pp.spend), 0)        AS roas
FROM public.ppc p
JOIN public.ppc_performance pp ON p.parent_id = pp.parent_id
WHERE pp.source = 2
  AND p.record_main_type = 'campaign'
  AND pp.record_type = 'campaign'
GROUP BY p.record_subtype;
```

---

## Overview

Seven tables form the PPC data model:

| Table | Role |
|-------|------|
| `public.ppc` | Metadata / dimension store — one row per PPC entity (campaign, ad group, ad, asset group, asset). Includes source, marketplace, and sub-source name columns for fast lookups. |
| `public.ppc_performance` | Fact store — one date-grain row per performance event. Self-contained with all name columns. |
| `public.ppc_etl_change_log` | Field-level change audit log — records what changed, from what to what, and when. |
| `public.ppc_etl_automation_log` | Daily automation action log — records every automation rule that fired, what it changed, and why. |
| `public.ppc_targeting_performance` | Keyword, search term and ASIN targeting performance — one date-grain row per keyword / search query / ASIN target. Amazon only (source=1). |
| `public.google_merchant_products` | Google Merchant Center product catalog — title, price, brand, category, availability and custom labels per product. |
| `public.google_merchants` | Google merchant account registry — links `merchant_id` to Google Ads `customer_id` / account name. |

`ppc` and `ppc_performance` share **no FK constraint** but are logically joined via `parent_id` and `child_id`.

Log tables join `ppc` for entity metadata (name, status, type) and `ppc_performance` for metric context — **never** to raw lookup tables.

---

## Table 1: `public.ppc` (Metadata / Dimension)

### Columns

| Column | Type | Description |
|--------|------|-------------|
| `ppc_etl_id` | BIGINT UNSIGNED | Primary key |
| `source` | TINYINT UNSIGNED | 1=Amazon, 2=eBay, 3=Google |
| `source_name` | VARCHAR | Human-readable source label (AMAZON, EBAY, SHOPIFY) |
| `marketplace_id` | TINYINT UNSIGNED | Marketplace identifier |
| `market_place` | VARCHAR | Marketplace name (e.g. UK, Germany, US) |
| `sub_source_id` | TINYINT UNSIGNED | Sub-source / account identifier |
| `ss_name` | VARCHAR | Sub-source / account name |
| `parent_id` | VARCHAR(255) | Parent entity ID — meaning shifts with `record_main_type` and source (see mapping below) |
| `child_id` | VARCHAR(255) | Child entity ID — '0' for top-level (campaign) rows |
| `record_main_type` | VARCHAR(15) | Entity grain: `campaign`, `ad_group`, `ad`, `asset_group`, `asset` |
| `record_subtype` | VARCHAR(30) | Campaign/entity sub-type (e.g. SP, SD, SB, SEARCH, SHOPPING, asset type) |
| `record_name` | VARCHAR(255) | Display name of the entity |
| `record_status` | VARCHAR(20) | Normalised lifecycle state (`active`, `paused`, `archived`, etc.) |
| `bidding_strategy` | VARCHAR(10) | Targeting/bidding indicator — Amazon: `Auto`/`Manual` |
| `bid` | DECIMAL(5,2) | Budget for `campaign` rows; bid value for `ad_group` rows |

### This is `public.ppc` data integrity ways

| Entity | `record_main_type` | `parent_id` | `child_id` | `record_status` examples | `record_subtype` examples | `bidding_strategy` |
|--------|--------------------|-------------|------------|--------------------------|---------------------------|--------------------|
| Amazon campaign | `campaign` | Campaign ID | '0' | paused, archive, active | SP / SD / SB | Auto / Manual |
| Amazon ad group | `ad_group` | Campaign ID | AdGroup ID | paused, archive, active | '0' | '0' |
| Amazon ad | `ad` | AdGroup ID | amzAdId | paused, archived, active | '0' | '0' |
| eBay campaign | `campaign` | Campaign ID | '0' | running, paused, ended, deleted | ON_SITE, COST_PER_SALE, OFF_SITE | MANUAL, SMART |
| eBay ad group | `ad_group` | Campaign ID | AdGroup ID | paused, ended, active, archived | '0' | '0' |
| Google campaign | `campaign` | Campaign ID | '0' | active, paused, removed | PERFORMANCE_MAX, SHOPPING, SEARCH, DISPLAY, etc. | MAXIMIZE_C, MANUAL_CPC, TARGET_ROA, TARGET_CPA, etc. |
| Google ad group | `ad_group` | Campaign ID | AdGroup ID | active, paused, removed | '0' | '0' |
| Google asset group | `asset_group` | Campaign ID | asset_group_id | enabled, paused, removed | '0' | '0' |
| Google asset | `asset` | asset_group_id | asset_id | '0' | LOGO, HEADLINE, YOUTUBE_VIDEO, DESCRIPTION, etc. | '0' |

---

## Table 2: `public.ppc_performance` (Fact / Performance)

### Columns

| Column | Type | Description                                                               |
|--------|------|---------------------------------------------------------------------------|
| `performance_data_id` | BIGINT UNSIGNED | Primary key                                                               |
| `date` | DATE | Performance date                                                          |
| `source` | TINYINT UNSIGNED | 1=Amazon, 2=eBay, 3=Google Ads or it will consider as shopify             |
| `source_name` | VARCHAR | Human-readable source label                                               |
| `marketplace_id` | TINYINT UNSIGNED | Marketplace identifier                                                    |
| `marketplace` | VARCHAR | Marketplace name                                                          |
| `sub_source_id` | TINYINT UNSIGNED | Sub-source / account identifier                                           |
| `ss_name` | VARCHAR | Sub-source name                                                           |
| `ref_id` | VARCHAR(100) | External product/listing reference (ASIN, item_id) — may be '0'           |
| `sku` | VARCHAR(100) | SKU — Amazon only; '0' for others                                         |
| `record_type` | VARCHAR(15) | Fact grain: `ad`, `product`, `asset`, `campaign`                          |
| `record_id` | VARCHAR(100) | Entity ID at the fact grain (ad id, product_item_id, asset_id, campaign_id) |
| `parent_id` | VARCHAR(100) | Campaign ID (or asset_group_id for asset rows)                            |
| `child_id` | VARCHAR(100) | Ad group ID — '0' when not applicable                                     |
| `impressions` | INT UNSIGNED | Impressions count                                                         |
| `clicks` | INT UNSIGNED | Clicks count                                                              |
| `sales` | DECIMAL(10,2) | Attributed revenue / conversion value                                     |
| `orders` | DECIMAL(10,2) | Attributed orders / conversions                                           |
| `spend` | DECIMAL(10,2) | Advertising cost                                                          |
| `category_name` | VARCHAR | Category label                                                            |
| `user_name` | VARCHAR | User/account label                                                        |

### This is `public.ppc_performance` data integrity ways

| Source | `record_type` | `ref_id` | `sku` | `record_id` | `child_id` | `parent_id` |
|--------|---------------|----------|-------|-------------|------------|-------------|
| Amazon | `ad`          | ASIN     | SKU | amzAdId | AdGroup ID | Campaign ID |
| eBay | `campaign`    | '0'       | '0' | Campaign ID | '0' | Campaign ID |
| eBay | `ad`    |  item_id      | '0' | ebayAdId | AdGroup ID | Campaign ID |
| Google campaign-level | `campaign`    | '0'      | '0' | Campaign ID | '0' | Campaign ID |
| Google PMAX asset | `asset`       |  '0'     | '0' | Asset ID | '0' | Asset Group ID |
| Google Shopping Ads | `product`     | Parent ID      | Variation ID | Product Item Id | '0' | Campaign ID |

---

## Table 3: `public.ppc_etl_change_log` (Change Audit Log)

### Purpose

Field-level change audit log for PPC entities. Records what changed, from what value to what value, and on what business date — detected during the daily ETL run. Used to answer questions like:
- "When did this campaign pause/activate?"
- "When was this campaign's budget changed, and from how much to how much?"
- "What was the performance in the 7 days after this campaign was activated?"

### How it works

The ETL runs once daily at 7am SL time. Before overwriting `ppc_etl`, it compares the current state against the incoming source data. Any field that changed gets one row written to `ppc_etl_change_log`.

- `changed_at` = `CURRENT_DATE - 1` → the business day the change happened
- `detected_at` = `NOW()` → exact timestamp the ETL run caught it (ETL/debug use only)
- One row per changed field per entity per day (e.g. if status AND bid both change → 2 rows)

### Columns

| Column | Type | Description |
|--------|------|-------------|
| `id` | BIGINT UNSIGNED | Primary key |
| `source` | TINYINT UNSIGNED | 1=Amazon, 2=eBay, 3=Google |
| `sub_source_id` | TINYINT UNSIGNED | Account identifier |
| `marketplace_id` | TINYINT UNSIGNED | Marketplace identifier |
| `parent_id` | VARCHAR(255) | Campaign ID — always campaign level |
| `child_id` | VARCHAR(255) | Ad group / ad ID. `'0'` for campaigns |
| `record_type` | VARCHAR(15) | `campaign` / `ad_group` / `ad` / `asset_group` |
| `field` | VARCHAR(20) | Which field changed: `status` or `bid` |
| `old_value` | VARCHAR(255) | Field value before the change |
| `new_value` | VARCHAR(255) | Field value after the change |
| `changed_at` | DATE | Business date the change occurred (ETL run date - 1 day) |
| `detected_at` | TIMESTAMP | Exact timestamp when ETL detected this change — ETL audit only, never use in business queries |

### Unique Key

`(source, sub_source_id, marketplace_id, parent_id, child_id, record_type, field, old_value, new_value, changed_at)` — prevents duplicates on ETL re-runs.

### What fields are tracked per source

| Source | record_type | Tracked fields |
|--------|-------------|----------------|
| Amazon | `campaign` | `status`, `bid` (budget) |
| Amazon | `ad_group` | `status`, `bid` (default bid) |
| Amazon | `ad` | `status` |

### Status value reference

| Source | Status values in `old_value` / `new_value` |
|--------|-------------------------------------------|
| Amazon | `active`, `paused`, `archived` |

### Querying Rules for `ppc_etl_change_log`

- **Always use `changed_at`** for date filtering — it is the business date.
- **Never use `detected_at`** in business queries — it is for ETL audit/debug only.
- **Join to `public.ppc`** via `cl.parent_id = p.parent_id` and `cl.source = p.source` to get campaign name, status, `source_name`, `market_place`, `ss_name` — do NOT join raw lookup tables.
- **Join to `public.ppc_performance`** via `cl.parent_id = pp.parent_id` and `cl.source = pp.source` when the user asks for performance context around a change event.
- **Filter `field`** to scope: `field = 'status'` for activation/pause events, `field = 'bid'` for budget/bid changes.
- **Filter `new_value`** for direction: `new_value = 'active'` for activations, `new_value = 'paused'` for pauses.
- **`old_value` and `new_value` are always VARCHAR** — cast to DECIMAL when doing arithmetic: `CAST(cl.new_value AS DECIMAL(10,2))`.

---

## Table 4: `public.ppc_etl_automation_log` (Automation Action Log)

### Purpose

Unified daily automation action log across all PPC automations. Records every automation rule that fired — what action was taken, on which entity, why, and with what performance context. Used to answer questions like:
- "What automation actions ran today for ledsone?"
- "Which campaigns had their budget changed by automation this week?"
- "Why did automation pause this ad group?"
- "What was the spend/sales context when this bid was changed?"

### How it works

Written by the PPC automation engine each time a rule fires. Each row is one automation action on one entity. Performance snapshot columns (`perf_primary_*`, `perf_secondary_*`) capture the metrics that triggered the rule at the time of the action.

- `action_datetime` = exact datetime the automation executed the action
- `detected_at` = timestamp the row was written to MySQL (ETL/debug use only)

### Columns

| Column | Type | Description |
|--------|------|-------------|
| `id` | BIGINT UNSIGNED | Primary key |
| `source` | TINYINT UNSIGNED | 1=Amazon, 2=eBay, 3=Google |
| `sub_source_id` | TINYINT UNSIGNED | Account identifier |
| `marketplace_id` | TINYINT UNSIGNED | Marketplace identifier |
| `parent_id` | VARCHAR(255) | Campaign ID |
| `child_id` | VARCHAR(255) | Ad group ID — `'0'` for campaign-level actions |
| `record_id` | VARCHAR(255) | Unique key of the specific record acted on |
| `record_type` | VARCHAR(20) | `campaign` / `auto_targeting` / `keyword_targeting` / `ad` |
| `action_type` | VARCHAR(20) | `daily_budget_set_logs` / `bid_change_logs` / `ad_pause_logs` / `ad_active_logs` |
| `old_value` | VARCHAR(50) | Value before the automation action |
| `new_value` | VARCHAR(50) | Value after the automation action |
| `rule_triggered` | VARCHAR(50) | Name/identifier of the rule that fired |
| `reason` | TEXT | Human-readable explanation of why the rule fired |
| `applied_by` | VARCHAR(50) | `'0'` = fully automated; user name = manual override |
| `perf_primary_window` | VARCHAR(15) | Primary lookback window used: `30d`, `this_month`, `60d`, `7d` |
| `perf_primary_impressions` | INT UNSIGNED | Impressions in the primary window |
| `perf_primary_clicks` | INT UNSIGNED | Clicks in the primary window |
| `perf_primary_spend` | DECIMAL(10,2) | Spend in the primary window |
| `perf_primary_sales` | DECIMAL(10,2) | Sales in the primary window |
| `perf_primary_orders` | INT UNSIGNED | Orders in the primary window |
| `perf_secondary_window` | VARCHAR(15) | Secondary lookback window: `7d` or `'0'` if not used |
| `perf_secondary_impressions` | INT UNSIGNED | Impressions in the secondary window |
| `perf_secondary_clicks` | INT UNSIGNED | Clicks in the secondary window |
| `perf_secondary_spend` | DECIMAL(10,2) | Spend in the secondary window |
| `perf_secondary_sales` | DECIMAL(10,2) | Sales in the secondary window |
| `perf_secondary_orders` | INT UNSIGNED | Orders in the secondary window |
| `status` | VARCHAR(10) | Outcome: `success` / `failed` / `skipped` |
| `action_datetime` | DATETIME | Exact datetime the automation action was executed |
| `detected_at` | TIMESTAMP | Timestamp the row was written — ETL audit only, never use in business queries |

### Unique Key

`(source, sub_source_id, marketplace_id, parent_id, child_id, record_id, record_type, action_type, status, action_datetime)` — prevents duplicate rows.

### Querying Rules for `ppc_etl_automation_log`

- **Always use `action_datetime`** for date filtering — it is the business datetime of the action.
- **Never use `detected_at`** in business queries — ETL audit/debug only.
- **Join to `public.ppc`** via `al.parent_id = p.parent_id` and `al.source = p.source` to get campaign name, `source_name`, `market_place`, `ss_name` — do NOT join raw lookup tables.
- **Filter `status`** when the user cares only about successful actions: `status = 'success'`.
- **Filter `applied_by`** to distinguish automated vs manual: `applied_by = '0'` for automation, anything else for manual overrides.
- **`old_value` and `new_value` are VARCHAR** — cast to DECIMAL for arithmetic: `CAST(al.new_value AS DECIMAL(10,2))`.

### action_type reference

| `action_type` | Meaning |
|---|---|
| `daily_budget_set_logs` | Campaign daily budget was changed |
| `bid_change_logs` | Keyword or targeting bid was changed |
| `ad_pause_logs` | Ad / targeting was paused |
| `ad_active_logs` | Ad / targeting was activated |

---

## Table 5: `public.ppc_targeting_performance` (Keyword & Search Term Performance)

### Purpose

Stores daily keyword, search term, and ASIN targeting performance data for Amazon (source=1). This is the granular targeting layer — below ad group level. Used to answer questions like:
- "Which keywords are spending the most with low ROAS?"
- "What search terms triggered my ads this week?"
- "Which ASIN targets are converting?"
- "Show me broad match keyword performance vs exact match"
- "What customer search queries triggered my pendant shade keyword?"


### Columns

| Column | Type | Description |
|--------|------|-------------|
| `id` | BIGINT (20) | Primary key |
| `source` | TINYINT (3) | Always 1 (Amazon) — only Amazon has this data |
| `sub_source_id` | TINYINT (3) | Account identifier |
| `marketplace_id` | TINYINT (3) | Marketplace identifier |
| `date` | DATE | Performance date |
| `type` | VARCHAR(15) | Row type: `keyword`, `search_term`, or `asin_target` — see type reference below |
| `campaign_id` | VARCHAR(100) | Amazon campaign ID — join to `public.ppc` via `campaign_id = p.parent_id` |
| `ad_group_id` | VARCHAR(100) | Amazon ad group ID — join to `public.ppc` via `ad_group_id = p.child_id` |
| `keyword_id` | VARCHAR(100) | Amazon keyword ID (amzKeywordId) — populated for `keyword` rows only; `'0'` for search_term and asin_target |
| `term` | VARCHAR(500) | The targeting text — keyword text for `keyword` rows, customer search query for `search_term` rows, ASIN for `asin_target` rows |
| `match_type` | VARCHAR(30) | Match type — see match_type reference below |
| `keyword_text` | VARCHAR(500) | The keyword or auto-targeting expression that triggered the search term — `search_term` rows only; `'0'` for `keyword` and `asin_target` rows. See `keyword_text` reference below for all possible values. |
| `impressions` | INT UNSIGNED | Impressions count |
| `clicks` | INT UNSIGNED | Clicks count |
| `spend` | DECIMAL(10,2) | Advertising cost |
| `sales` | DECIMAL(10,2) | Attributed sales (7d window for keywords; as reported for search terms) |
| `orders` | INT UNSIGNED | Attributed orders (7d window for keywords; as reported for search terms) |

### Type Reference — CRITICAL for correct queries

| `type` | What `term` contains | What `match_type` contains | What `keyword_text` contains | Source |
|--------|---------------------|---------------------------|------------------------------|--------|
| `keyword` | Keyword text (e.g. `pendant shade`) | `BROAD` / `PHRASE` / `EXACT` | `'0'` (not applicable) | `keyword_performance_data` |
| `search_term` | Customer search query (e.g. `metal pendant shade matte white`) | `BROAD` / `PHRASE` / `EXACT` / `TARGETING_EXPRESSION` / `TARGETING_EXPRESSION_PREDEFINED` | **Manual campaigns:** actual keyword that triggered it (e.g. `pendant shade`). **Auto campaigns:** `close-match` / `loose-match` / `substitutes` / `keyword-group="category"`. | `amazon_search_term_performance_data` |
| `asin_target` | Competitor / related ASIN (e.g. `B07QJ6V1N6`) | `TARGETING_EXPRESSION` / `TARGETING_EXPRESSION_PREDEFINED` | The targeting expression used — `substitutes` / `complements` / `category="XXXXXXX"` / `asin-expanded="BXXXXXXXXX"`. **Not `'0'`**. | `amazon_search_term_performance_data` |

### ⚠️ Understanding `keyword_text` — CRITICAL

`keyword_text` stores what Amazon reports as the "keyword" that caused the search term row to appear. Its meaning depends on whether the campaign uses **manual** or **auto** targeting:

#### Manual targeting campaigns (Sponsored Products / Brands with explicit keywords)

`keyword_text` = the actual keyword text that was targeted and triggered the customer's search query.

| `term` (search query) | `keyword_text` (triggered by) | `match_type` |
|---|---|---|
| `metal pendant shade matte white` | `pendant shade` | `Broad` |
| `metal pendant shade matte white` | `pendant shade` | `Phrase` |
| `black pendant shade` | `pendant shade` | `Broad` |

The same search query can appear as **multiple rows** on the same date if it was triggered by different keywords or under different match types. Always `GROUP BY keyword_text` when aggregating search_term rows to avoid double-counting.

#### Auto targeting campaigns (Amazon-managed targeting)

`keyword_text` = the **auto-targeting expression** Amazon used — NOT a real keyword. Possible values for `search_term` auto rows:

| `keyword_text` value | Meaning |
|---|---|
| `close-match` | Amazon auto: query closely matched the product |
| `loose-match` | Amazon auto: query loosely matched the product |
| `substitutes` | Amazon auto: query matched a substitute product |
| `keyword-group="category"` | Amazon auto: query matched via a category keyword group |

For auto campaigns there is no specific keyword — Amazon decides targeting. These values replace the keyword text.

#### `asin_target` rows — `keyword_text` is NOT `'0'`

`asin_target` rows store the **targeting expression** that generated the ASIN target in `keyword_text`. Possible values:

| `keyword_text` value | Meaning |
|---|---|
| `substitutes` | Product targeted as a substitute competitor |
| `complements` | Product targeted as a complementary product |
| `category="248311031"` | Category-level targeting (number = Amazon browse node ID) |
| `asin-expanded="B093HCQGSL"` | Specific ASIN expanded targeting |

#### When `keyword_text` = `'0'`

`keyword_text` is `'0'` only for `type = 'keyword'` rows — it is never applicable for keyword-level data.

#### `keyword_text` value summary by type

| `type` | Possible `keyword_text` values |
|--------|-------------------------------|
| `keyword` | Always `'0'` |
| `search_term` (manual campaign) | Actual keyword text, e.g. `pendant shade`, `black ceiling rose` |
| `search_term` (auto campaign) | `close-match`, `loose-match`, `substitutes`, `keyword-group="category"` |
| `asin_target` | Targeting expression: `substitutes`, `complements`, `category="XXXXXXX"`, `asin-expanded="BXXXXXXXXX"` |

### match_type Reference

| `match_type` value | Applies to `type` | Meaning |
|-------------------|-------------------|---------|
| `EXACT` | `keyword`, `search_term` | Only exact query matches trigger the keyword |
| `PHRASE` | `keyword`, `search_term` | Phrase and exact matches trigger the keyword |
| `BROAD` | `keyword`, `search_term` | Broad, phrase, and related matches trigger the keyword |
| `TARGETING_EXPRESSION` | `search_term`, `asin_target` | Amazon auto/product targeting — dynamically matched by Amazon |
| `TARGETING_EXPRESSION_PREDEFINED` | `search_term`, `asin_target` | Amazon predefined targeting expression (e.g. substitutes, complements, category) |

### Data Integrity — Row Uniqueness

Each row is unique on `(source, sub_source_id, marketplace_id, date, type, campaign_id, ad_group_id, keyword_id, term, keyword_text, match_type)`.

This means the same search term (e.g. `metal pendant shade matte white`) can appear as multiple rows on the same date if:
- It was triggered by different keywords (different `keyword_text`)
- It was triggered under different match types (different `match_type`)
- It was triggered by both a manual keyword AND an auto-targeting expression (different `keyword_text` values across rows)

For `asin_target` rows, uniqueness also depends on `keyword_text` — the same ASIN can appear multiple rows if it was targeted via different expressions (e.g. `substitutes` AND `category="248311031"`).

### Querying Rules for `ppc_targeting_performance`

- **Always filter `type`** when the question is specific: `type = 'keyword'` for keyword analysis, `type = 'search_term'` for search query analysis, `type = 'asin_target'` for product targeting analysis.
- **For keyword questions** (`type = 'keyword'`): `term` = keyword text, `match_type` = Broad/Phrase/Exact, `keyword_text` is irrelevant (`'0'`).
- **For search term questions** (`type = 'search_term'`): `term` = customer query, `keyword_text` = keyword that triggered it (manual) or auto-targeting expression (`close-match` / `loose-match` / `substitutes` / `complements`) for auto campaigns.
- **For ASIN targeting questions** (`type = 'asin_target'`): `term` = competitor ASIN, `match_type` = substitutes/complements/close-match/loose-match.
- **Always `GROUP BY keyword_text`** when aggregating `search_term` rows — the same search query appears multiple rows per day when triggered by different keywords or auto-targeting expressions.
- **To see only manual-campaign search terms**: `AND match_type IN ('BROAD', 'PHRASE', 'EXACT')`
- **To see only auto-campaign search terms**: `AND match_type IN ('TARGETING_EXPRESSION', 'TARGETING_EXPRESSION_PREDEFINED')`
- **`asin_target.keyword_text` is NOT `'0'`** — it contains the targeting expression (`substitutes`, `complements`, `category="XXXXXXX"`, `asin-expanded="BXXXXXXXXX"`). Do not filter `asin_target` rows by `keyword_text = '0'`.
- **Join to `public.ppc`** via `tp.campaign_id = p.parent_id AND p.record_main_type = 'campaign'` to get campaign name, `ss_name`, `market_place`, `record_subtype` (SP/SD/SB).
- **Never join `ppc_targeting_performance` to `ppc_performance`** for the same date range — they represent different grains and summing both would double-count spend.
- **Derived metrics**: ACOS = `spend / sales * 100`, ROAS = `sales / spend`, CTR = `clicks / impressions * 100`, CPC = `spend / clicks`.
- **`keyword_id = '0'`** for `search_term` and `asin_target` rows — do not filter on `keyword_id` for these types.
- This table is **Amazon only** (`source = 1`). Do not query it for eBay or Google.

### Example Queries

#### Keyword performance — top keywords by spend with ACOS
```sql
SELECT
    tp.term                                                              AS keyword,
    tp.match_type,
    p.record_name                                                        AS campaign_name,
    p.record_subtype                                                     AS campaign_type,
    p.ss_name,
    p.market_place,
    SUM(tp.impressions)                                                  AS impressions,
    SUM(tp.clicks)                                                       AS clicks,
    SUM(tp.spend)                                                        AS spend,
    SUM(tp.sales)                                                        AS sales,
    SUM(tp.orders)                                                       AS orders,
    (SUM(tp.spend) / NULLIF(SUM(tp.sales), 0) * 100)::numeric           AS acos,
    (SUM(tp.sales) / NULLIF(SUM(tp.spend), 0))::numeric                 AS roas
FROM public.ppc_targeting_performance tp
JOIN public.ppc p
    ON tp.campaign_id = p.parent_id
    AND p.record_main_type = 'campaign'
WHERE tp.source = 1
  AND tp.type = 'keyword'
  AND tp.date BETWEEN '2026-05-01' AND '2026-05-31'
GROUP BY tp.term, tp.match_type, p.record_name, p.record_subtype, p.ss_name, p.market_place
ORDER BY SUM(tp.spend) DESC;
```

#### Search term analysis — what queries triggered a specific keyword (manual campaigns)
```sql
SELECT
    tp.term                                                              AS search_query,
    tp.match_type,
    tp.keyword_text                                                      AS triggered_by_keyword,
    SUM(tp.impressions)                                                  AS impressions,
    SUM(tp.clicks)                                                       AS clicks,
    SUM(tp.spend)                                                        AS spend,
    SUM(tp.sales)                                                        AS sales,
    SUM(tp.orders)                                                       AS orders,
    (SUM(tp.spend) / NULLIF(SUM(tp.sales), 0) * 100)::numeric           AS acos
FROM public.ppc_targeting_performance tp
JOIN public.ppc p
    ON tp.campaign_id = p.parent_id
    AND p.record_main_type = 'campaign'
WHERE tp.source = 1
  AND tp.type = 'search_term'
  AND tp.keyword_text = 'pendant shade'
  AND tp.date BETWEEN '2026-05-01' AND '2026-05-31'
GROUP BY tp.term, tp.match_type, tp.keyword_text
ORDER BY SUM(tp.spend) DESC;
```

#### Search term analysis — auto-campaign search terms by targeting expression
```sql
SELECT
    tp.keyword_text                                                      AS auto_targeting_type,
    tp.term                                                              AS search_query,
    SUM(tp.impressions)                                                  AS impressions,
    SUM(tp.clicks)                                                       AS clicks,
    SUM(tp.spend)                                                        AS spend,
    SUM(tp.sales)                                                        AS sales,
    SUM(tp.orders)                                                       AS orders,
    (SUM(tp.spend) / NULLIF(SUM(tp.sales), 0) * 100)::numeric           AS acos
FROM public.ppc_targeting_performance tp
WHERE tp.source = 1
  AND tp.type = 'search_term'
  AND tp.keyword_text IN ('close-match', 'loose-match', 'substitutes', 'complements')
  AND tp.date BETWEEN '2026-05-01' AND '2026-05-31'
GROUP BY tp.keyword_text, tp.term
ORDER BY tp.keyword_text, SUM(tp.spend) DESC;
```

#### ASIN targeting — which competitor ASINs are converting
```sql
SELECT
    tp.term                                                              AS target_asin,
    tp.match_type                                                        AS targeting_type,
    p.record_name                                                        AS campaign_name,
    p.ss_name,
    p.market_place,
    SUM(tp.impressions)                                                  AS impressions,
    SUM(tp.clicks)                                                       AS clicks,
    SUM(tp.spend)                                                        AS spend,
    SUM(tp.sales)                                                        AS sales,
    SUM(tp.orders)                                                       AS orders
FROM public.ppc_targeting_performance tp
JOIN public.ppc p
    ON tp.campaign_id = p.parent_id
    AND p.record_main_type = 'campaign'
WHERE tp.source = 1
  AND tp.type = 'asin_target'
  AND tp.date BETWEEN '2026-05-01' AND '2026-05-31'
GROUP BY tp.term, tp.match_type, p.record_name, p.ss_name, p.market_place
ORDER BY SUM(tp.orders) DESC;
```

#### Search term analysis — manual campaigns only (keyword-triggered)
```sql
SELECT
    tp.term                                                              AS search_query,
    tp.keyword_text                                                      AS triggered_by_keyword,
    tp.match_type,
    p.record_name                                                        AS campaign_name,
    p.ss_name,
    p.market_place,
    SUM(tp.impressions)                                                  AS impressions,
    SUM(tp.clicks)                                                       AS clicks,
    SUM(tp.spend)                                                        AS spend,
    SUM(tp.sales)                                                        AS sales,
    SUM(tp.orders)                                                       AS orders,
    (SUM(tp.spend) / NULLIF(SUM(tp.sales), 0) * 100)::numeric           AS acos
FROM public.ppc_targeting_performance tp
JOIN public.ppc p
    ON tp.campaign_id = p.parent_id
    AND p.record_main_type = 'campaign'
WHERE tp.source = 1
  AND tp.type = 'search_term'
  AND tp.match_type IN ('BROAD', 'PHRASE', 'EXACT')   -- manual keyword-triggered only
  AND tp.date BETWEEN '2026-05-01' AND '2026-05-31'
GROUP BY tp.term, tp.keyword_text, tp.match_type, p.record_name, p.ss_name, p.market_place
ORDER BY SUM(tp.spend) DESC;
```

#### Search term analysis — auto campaigns only (Amazon-managed targeting)
```sql
SELECT
    tp.keyword_text                                                      AS auto_targeting_expression,
    tp.term                                                              AS search_query,
    p.record_name                                                        AS campaign_name,
    p.ss_name,
    p.market_place,
    SUM(tp.impressions)                                                  AS impressions,
    SUM(tp.clicks)                                                       AS clicks,
    SUM(tp.spend)                                                        AS spend,
    SUM(tp.sales)                                                        AS sales,
    SUM(tp.orders)                                                       AS orders,
    (SUM(tp.spend) / NULLIF(SUM(tp.sales), 0) * 100)::numeric           AS acos
FROM public.ppc_targeting_performance tp
JOIN public.ppc p
    ON tp.campaign_id = p.parent_id
    AND p.record_main_type = 'campaign'
WHERE tp.source = 1
  AND tp.type = 'search_term'
  AND tp.match_type IN ('TARGETING_EXPRESSION', 'TARGETING_EXPRESSION_PREDEFINED')  -- auto only
  AND tp.date BETWEEN '2026-05-01' AND '2026-05-31'
GROUP BY tp.keyword_text, tp.term, p.record_name, p.ss_name, p.market_place
ORDER BY tp.keyword_text, SUM(tp.spend) DESC;
```

#### ASIN targeting — breakdown by targeting expression type
```sql
SELECT
    tp.keyword_text                                                      AS targeting_expression,
    tp.term                                                              AS target_asin,
    p.record_name                                                        AS campaign_name,
    p.ss_name,
    p.market_place,
    SUM(tp.impressions)                                                  AS impressions,
    SUM(tp.clicks)                                                       AS clicks,
    SUM(tp.spend)                                                        AS spend,
    SUM(tp.sales)                                                        AS sales,
    SUM(tp.orders)                                                       AS orders,
    (SUM(tp.spend) / NULLIF(SUM(tp.sales), 0) * 100)::numeric           AS acos
FROM public.ppc_targeting_performance tp
JOIN public.ppc p
    ON tp.campaign_id = p.parent_id
    AND p.record_main_type = 'campaign'
WHERE tp.source = 1
  AND tp.type = 'asin_target'
  AND tp.date BETWEEN '2026-05-01' AND '2026-05-31'
GROUP BY tp.keyword_text, tp.term, p.record_name, p.ss_name, p.market_place
ORDER BY tp.keyword_text, SUM(tp.spend) DESC;
```

#### Match type breakdown — compare BROAD vs PHRASE vs EXACT keyword performance
```sql
SELECT
    tp.match_type,
    COUNT(DISTINCT tp.term)                                              AS keyword_count,
    SUM(tp.impressions)                                                  AS impressions,
    SUM(tp.clicks)                                                       AS clicks,
    SUM(tp.spend)                                                        AS spend,
    SUM(tp.sales)                                                        AS sales,
    SUM(tp.orders)                                                       AS orders,
    (SUM(tp.spend) / NULLIF(SUM(tp.sales), 0) * 100)::numeric           AS acos,
    (SUM(tp.sales) / NULLIF(SUM(tp.spend), 0))::numeric                 AS roas
FROM public.ppc_targeting_performance tp
WHERE tp.source = 1
  AND tp.type = 'keyword'
  AND tp.date BETWEEN '2026-05-01' AND '2026-05-31'
GROUP BY tp.match_type
ORDER BY SUM(tp.spend) DESC;
```

---

## Table 6: `public.google_merchant_products` (Google Product Catalog)

### Purpose

Stores Google Merchant Center product data synced from `ppc_db.google_merchant_products`. Each row is one product variant per merchant, feed label, and language. Used to enrich Google Shopping product performance with product metadata — title, price, brand, category, availability, and custom labels.

### Columns

| Column | Type | Description |
|--------|------|-------------|
| `id` | BIGINT | Primary key |
| `merchant_id` | BIGINT | Merchant Center account ID |
| `product_id` | TEXT | Google product ID. Values come in multiple formats: Shopify-sourced products use the pattern `shopify_<country>_<item_id>_<variant_id>` where `<country>` is an uppercase marketplace code (e.g. `shopify_GB_4551406878816_31982166212704`); other feeds may use plain numeric IDs (e.g. `7455210569978`, `1531921751963939630`) |
| `source` | VARCHAR(100) | Feed source label |
| `title` | TEXT | Product title |
| `description` | TEXT | Product description |
| `link` | TEXT | Product page URL |
| `image_link` | TEXT | Product image URL |
| `lan` | VARCHAR(100) | Language code (e.g. `en`, `de`) |
| `country` | VARCHAR(200) | Target country |
| `feed_label` | VARCHAR(200) | Merchant Center feed label |
| `channel` | VARCHAR(200) | Distribution channel (e.g. `online`) |
| `availability` | TEXT | Stock status (e.g. `in stock`, `out of stock`) |
| `brand` | TEXT | Product brand |
| `color` | VARCHAR(100) | Product colour |
| `condition` | VARCHAR(200) | Product condition (e.g. `new`) |
| `product_category` | TEXT | Google product category |
| `item_group_id` | BIGINT | Parent item group ID — groups variants (e.g. size/colour variants of the same base product) |
| `mpn` | TEXT | Manufacturer Part Number |
| `price` | DECIMAL(10,2) | Listed price |
| `currency` | VARCHAR(50) | Currency code (e.g. `GBP`, `EUR`) |
| `product_types` | TEXT | Merchant-defined product type path |
| `sale_price` | DECIMAL(10,2) | Sale price (if applicable) |
| `custom_label0` | TEXT | Custom label 0 — merchant-defined segmentation field |
| `custom_label1` | TEXT | Custom label 1 — merchant-defined segmentation field |
| `custom_label2` | TEXT | Custom label 2 — merchant-defined segmentation field |
| `custom_label3` | TEXT | Custom label 3 — merchant-defined segmentation field |
| `custom_label4` | TEXT | Custom label 4 — merchant-defined segmentation field |
| `multipack` | INT | Multipack quantity (if applicable) |

### Unique Key

`(merchant_id, product_id, feed_label, lan)` — one row per product per merchant per feed per language.

---

## Table 7: `public.google_merchants` (Google Merchant Account Registry)

### Purpose

Maps Merchant Center `merchant_id` to the Google Ads account (`customer_id` / `customer_name`). This is the bridge between the product catalog (`google_merchant_products`) and the PPC sub-source/account dimension. Used to filter product performance by Google Ads account or to identify which merchant account owns a product.

### Columns

| Column | Type | Description |
|--------|------|-------------|
| `id` | BIGINT | Primary key |
| `merchant_id` | BIGINT | Merchant Center account ID |
| `customer_id` | BIGINT | Google Ads account ID — equals `google_accounts.account_id`; use to identify or filter by sub-source/account |
| `customer_name` | TEXT | Google Ads account name — equals `google_accounts.account_name` |
| `is_active` | TINYINT(1) | 1 = active merchant account, 0 = inactive |

---

## Google Product Performance — Join Chain

To get Google Shopping product performance enriched with product details and filtered by merchant account:

```
public.ppc_performance  (source = 3, record_type = 'product')
    ↕  LOWER(google_merchant_products.product_id) = ppc_performance.record_id
public.google_merchant_products
    ↕  merchant_id = merchant_id
public.google_merchants
    ↕  customer_id  →  links to the Google Ads sub-source account
```

### Querying Rules for Google product joins

- **Always filter** `pp.source = 3` AND `pp.record_type = 'product'` before joining to `google_merchant_products`.
- **⚠️ All `shopify_<country>_` product IDs require case normalisation before joining** — `google_merchant_products.product_id` stores Shopify products with an uppercase country code (e.g. `shopify_GB_4551406878816_31982166212704`) but `ppc_performance.record_id` stores them fully lowercase. The country code portion can be any marketplace — always use `LOWER(gmp.product_id)` in the JOIN condition so all variants are covered regardless of which marketplace the product belongs to. Plain numeric IDs are unaffected by lowercasing.
- **Filter by merchant/account** using `gm.customer_id` — this maps to the Google Ads sub-source. Do not rely solely on `ppc_performance.ss_name` for account filtering when merchant context is needed; use `google_merchants.customer_id`.
- **Filter `gm.is_active = 1`** to exclude decommissioned merchant accounts unless the user asks for historical data.
- **`custom_label0–4`** are merchant-defined — their meaning varies by account. Ask the user what a custom label represents before filtering on it.
- **`item_group_id`** groups product variants. Aggregate by `item_group_id` for parent-level (base product) performance rather than per-variant.
- **Do not join `ppc` for campaign metadata on product rows** — use `pp.parent_id = p.parent_id AND p.record_main_type = 'campaign'` when campaign name is also needed.

### Example Query — Google Shopping product performance with product details

```sql
SELECT
    gmp.title                                                            AS product_title,
    gmp.brand,
    gmp.product_category,
    gmp.availability,
    gmp.price,
    gmp.currency,
    gm.customer_name                                                     AS account_name,
    p.record_name                                                        AS campaign_name,
    SUM(pp.impressions)                                                  AS impressions,
    SUM(pp.clicks)                                                       AS clicks,
    SUM(pp.spend)                                                        AS spend,
    SUM(pp.sales)                                                        AS sales,
    SUM(pp.orders)                                                       AS orders,
    (SUM(pp.spend) / NULLIF(SUM(pp.sales), 0) * 100)::numeric           AS acos,
    (SUM(pp.sales) / NULLIF(SUM(pp.spend), 0))::numeric                 AS roas
FROM public.ppc_performance pp
JOIN public.google_merchant_products gmp
    ON pp.record_id = LOWER(gmp.product_id)
JOIN public.google_merchants gm
    ON gmp.merchant_id = gm.merchant_id
JOIN public.ppc p
    ON pp.parent_id = p.parent_id
    AND p.record_main_type = 'campaign'
WHERE pp.source = 3
  AND pp.record_type = 'product'
  AND gm.is_active = 1
  AND pp.date BETWEEN '2026-05-01' AND '2026-05-31'
GROUP BY gmp.title, gmp.brand, gmp.product_category, gmp.availability,
         gmp.price, gmp.currency, gm.customer_name, p.record_name
ORDER BY SUM(pp.spend) DESC;
```

### Example Query — filter product performance by merchant account (customer_id)

```sql
SELECT
    gmp.product_id,
    gmp.title,
    gmp.availability,
    gmp.price,
    gmp.currency,
    SUM(pp.impressions)                                                  AS impressions,
    SUM(pp.clicks)                                                       AS clicks,
    SUM(pp.spend)                                                        AS spend,
    SUM(pp.sales)                                                        AS sales,
    SUM(pp.orders)                                                       AS orders,
    (SUM(pp.spend) / NULLIF(SUM(pp.sales), 0) * 100)::numeric           AS acos
FROM public.ppc_performance pp
JOIN public.google_merchant_products gmp
    ON pp.record_id = LOWER(gmp.product_id)
JOIN public.google_merchants gm
    ON gmp.merchant_id = gm.merchant_id
WHERE pp.source = 3
  AND pp.record_type = 'product'
  AND gm.customer_id = 123456789        -- replace with actual Google Ads account ID
  AND gm.is_active = 1
  AND pp.date BETWEEN '2026-05-01' AND '2026-05-31'
GROUP BY gmp.product_id, gmp.title, gmp.availability, gmp.price, gmp.currency
ORDER BY SUM(pp.spend) DESC;
```

---

## SQL Generation Rules

### Sub-source / store name filter — always use `=`, never `LIKE`

When filtering by `ss_name` in `public.ppc` or `public.ppc_performance`, always use exact match (`=`). Using `LIKE` risks matching REPLACEMENT/RESEND suffix variants and cross-platform name overlaps.

```sql
-- ❌ WRONG — matches 'ledsone', 'ledsone_shopify', 'ledsone_shopify_replacement' etc.
WHERE pp.ss_name LIKE '%ledsone%'

-- ✅ CORRECT — exact store + platform
WHERE pp.ss_name = 'ledsone' AND pp.source = 3
```

---

### ROUND() is forbidden — cast to numeric instead

PostgreSQL has no `ROUND(double precision, integer)` overload. Even though `spend` and `sales` are `numeric`, arithmetic chains involving `NULLIF()` and multiplication can promote the result to `double precision`, breaking `ROUND()`.

```sql
-- ❌ NEVER — will error if result is promoted to double precision
ROUND(SUM(pp.spend) / NULLIF(SUM(pp.sales), 0) * 100, 2)

-- ✅ ALWAYS — cast to numeric before any rounding or truncation
(SUM(pp.spend) / NULLIF(SUM(pp.sales), 0) * 100)::numeric

-- ✅ If decimal places are needed, use TRUNC after casting
TRUNC((SUM(pp.spend) / NULLIF(SUM(pp.sales), 0) * 100)::numeric, 2)
```

## SB (Sponsored Brands) Campaign — Include vs Exclude Rule

**Why SB is special:** Amazon does not provide ad-level data for SB campaigns. Only one ASIN gets mapped to the SB campaign in the DB, but the campaign actually covers multiple ASINs. This means SB spend/sales cannot be accurately attributed to any specific ASIN or SKU — the mapped ASIN is not representative.

**Exclude SB** (`AND p.record_subtype != 'SB'`) when the user mentions a specific ASIN or SKU value in their question — filtering by a specific ASIN/SKU against SB data returns misleading numbers because the mapped ASIN does not reflect all products in the campaign.

**Include SB** (no filter needed) for all other Amazon questions — totals, campaign-wise, sub-source, marketplace, date range, or any question that is not scoped to a specific ASIN or SKU value.

| User question | SB included? |
|---------------|-------------|
| "ledsone uk amazon total metrics last 30 days" | ✅ Yes |
| "amazon UK campaign wise spend" | ✅ Yes |
| "dcv amazon performance this month" | ✅ Yes |
| "spend for ASIN B08V5MK449" | ❌ No — specific ASIN mentioned |
| "campaign wise for B08V5MK449" | ❌ No — specific ASIN mentioned |
| "top SKUs by spend" | ❌ No — SKU-level question |

---

## Joining the Tables

### Campaign-level join (ppc + ppc_performance)

```sql
-- Amazon: campaign totals (aggregating ad-grain rows)
SELECT p.record_name AS campaign_name,
       p.record_subtype, p.record_status, p.bidding_strategy,
       p.source_name, p.market_place, p.ss_name,
       SUM(pp.impressions) AS impressions,
       SUM(pp.clicks)      AS clicks,
       SUM(pp.spend)       AS spend,
       SUM(pp.sales)       AS sales,
       SUM(pp.orders)      AS orders
FROM public.ppc p
JOIN public.ppc_performance pp
  ON p.parent_id = pp.parent_id
  AND p.record_main_type = 'campaign'
  AND pp.record_type = 'ad'
WHERE pp.source = 1
GROUP BY p.record_name, p.record_subtype, p.record_status, p.bidding_strategy,
         p.source_name, p.market_place, p.ss_name;


-- eBay: campaign totals (always include record_subtype for Advanced/Standard distinction)
SELECT p.record_name,
       p.record_subtype,                  -- ON_SITE = Advanced, COST_PER_SALE = Standard
       p.record_status,
       p.source_name, p.market_place, p.ss_name,
       SUM(pp.impressions) AS impressions,
       SUM(pp.clicks)      AS clicks,
       SUM(pp.spend)       AS spend,
       SUM(pp.sales)       AS sales,
       SUM(pp.orders)      AS orders
FROM public.ppc p
JOIN public.ppc_performance pp
  ON p.parent_id = pp.parent_id
  AND p.record_main_type = 'campaign'
  AND pp.record_type = 'campaign'
WHERE pp.source = 2
GROUP BY p.record_name, p.record_subtype, p.record_status, p.source_name, p.market_place, p.ss_name;


-- Google Ads: campaign totals
SELECT p.record_name, p.record_subtype, p.record_status, p.bidding_strategy,
       p.source_name, p.market_place, p.ss_name,
       SUM(pp.impressions) AS impressions,
       SUM(pp.clicks)      AS clicks,
       SUM(pp.spend)       AS spend,
       SUM(pp.sales)       AS sales,
       SUM(pp.orders)      AS orders
FROM public.ppc p
JOIN public.ppc_performance pp
  ON p.parent_id = pp.parent_id
  AND p.record_main_type = 'campaign'
  AND pp.record_type = 'campaign'
WHERE pp.source = 3
GROUP BY p.record_name, p.record_subtype, p.record_status, p.bidding_strategy,
         p.source_name, p.market_place, p.ss_name;
```

### Ad-group-level join

`public.ppc.child_id` (AdGroup ID) ↔ `public.ppc_performance.child_id`

```sql
-- Amazon: ad group totals
SELECT p.record_name AS ad_group_name, p.record_status,
       SUM(pp.impressions) AS impressions,
       SUM(pp.clicks)      AS clicks,
       SUM(pp.spend)       AS spend,
       SUM(pp.sales)       AS sales
FROM public.ppc p
JOIN public.ppc_performance pp ON p.child_id = pp.child_id
  AND p.record_main_type = 'ad_group'
  AND pp.record_type = 'ad'
WHERE pp.source = 1
GROUP BY p.record_name, p.record_status;
```

```sql
-- eBay: enrich ad performance with ad group metadata
SELECT p.record_name AS ad_group_name, p.record_status, pp.*
FROM public.ppc p
JOIN public.ppc_performance pp ON p.child_id = pp.child_id
  AND p.record_main_type = 'ad_group'
  AND pp.record_type = 'ad'
WHERE pp.source = 2;
```

### Asset-group-level join (Google PMAX only)

`public.ppc.child_id` (Asset Group ID) ↔ `public.ppc_performance.parent_id`

```sql
SELECT p.record_name AS asset_group_name, p.record_status,
       SUM(pp.impressions) AS impressions,
       SUM(pp.clicks)      AS clicks,
       SUM(pp.spend)       AS spend,
       SUM(pp.sales)       AS sales
FROM public.ppc p
JOIN public.ppc_performance pp
  ON p.child_id = pp.parent_id
WHERE pp.source = 3
  AND p.record_main_type = 'asset_group'
  AND pp.record_type = 'asset';
```

### Asset-level join (Google PMAX only)

```sql
SELECT p.record_name AS asset_value,
       p.record_subtype AS asset_type,
       SUM(pp.impressions) AS impressions,
       SUM(pp.clicks)      AS clicks,
       SUM(pp.spend)       AS spend,
       SUM(pp.sales)       AS sales
FROM public.ppc p
JOIN public.ppc_performance pp
  ON p.parent_id = pp.parent_id
  AND p.child_id = pp.record_id
WHERE pp.source = 3
  AND p.record_main_type = 'asset'
  AND pp.record_type = 'asset';
```

### Product-level join (Google Shopping/Search only)

`public.ppc.parent_id` (Campaign ID) ↔ `public.ppc_performance.parent_id`
Product details live only in `public.ppc_performance` — `ref_id` (parent_id of that product), `sku` (variation_id), `record_id` (product_item_id).

> ⚠️ Google product rows have **no matching metadata row** in `public.ppc` at the product grain. Join goes through the **campaign** record in `ppc` to get campaign name/status, then product fields come straight from `ppc_performance`.

```sql
SELECT p.record_name AS campaign_name,
       p.record_subtype AS campaign_type,
       p.record_status,
       pp.ref_id AS product_parent_id,
       pp.sku AS variation_id,
       pp.record_id AS product_item_id,
       SUM(pp.impressions) AS impressions,
       SUM(pp.clicks)      AS clicks,
       SUM(pp.spend)       AS spend,
       SUM(pp.sales)       AS sales,
       SUM(pp.orders)      AS orders
FROM public.ppc p
JOIN public.ppc_performance pp
  ON p.parent_id = pp.parent_id
  AND p.record_main_type = 'campaign'
  AND pp.record_type = 'product'
WHERE pp.source = 3
GROUP BY p.record_name, p.record_subtype, p.record_status,
         pp.ref_id, pp.sku, pp.record_id;
```

### Log table joins — use `ppc` for names, `ppc_performance` for metrics

```sql
-- Change log: get entity name + recent performance context after a status change
SELECT p.record_name   AS campaign_name,
       p.ss_name,
       p.market_place,
       cl.field,
       cl.old_value,
       cl.new_value,
       cl.changed_at,
       SUM(pp.impressions) AS impressions,
       SUM(pp.clicks)      AS clicks,
       SUM(pp.spend)       AS spend,
       SUM(pp.sales)       AS sales
FROM public.ppc_etl_change_log cl
JOIN public.ppc p
    ON cl.parent_id = p.parent_id
   AND cl.source    = p.source
   AND p.record_main_type = 'campaign'
JOIN public.ppc_performance pp
    ON cl.parent_id = pp.parent_id
   AND cl.source    = pp.source
   AND pp.date BETWEEN cl.changed_at AND cl.changed_at + INTERVAL '7 days'
WHERE cl.source = 1
  AND cl.field = 'status'
  AND cl.new_value = 'active'
GROUP BY p.record_name, p.ss_name, p.market_place,
         cl.field, cl.old_value, cl.new_value, cl.changed_at;
```

---

## ⚠️ Cross-Platform Granularity Mismatch — Ask Before Querying

The three platforms expose **different fact grains** in `public.ppc_performance`. When a user asks for cross-platform comparison using a generic term (like "ads", "performance", "spend"), the term does NOT map cleanly across platforms. Claude MUST ask a clarifying question before generating SQL.

### Available Grains by Platform

| Platform | Available `record_type` values | Notes |
|----------|-------------------------------|-------|
| Amazon (source=1) | `ad` | Only ad-grain available |
| eBay (source=2) | `campaign`, `ad` | `ad` exists only for `COST_PER_SALE` strategy; `ON_SITE` has campaign-grain only |
| Google/Shopify (source=3) | `campaign`, `product`, `asset` | Different grains for Search/Shopping vs PMAX |

### Trigger Words That Require Clarification

If a user asks for any of these across multiple platforms, **STOP and ask** before writing SQL:

- **"ads"** → Amazon has ads; eBay only for CPS campaigns; Google has no `ad` grain at all (has products/assets instead)
- **"products"** → Only Google has product-grain; Amazon's product info is on the `ad` row via `ref_id`/`sku`; eBay has `ebayListingId` on the `ad` row
- **"performance"** / **"data"** / **"results"** → too generic; ask which grain
- **"campaigns"** → safe-ish (all three have campaign-grain), but eBay needs strategy split (see eBay rule)
- **"all platforms" / "compare all" / "across channels"** → always confirm grain choice

### Required Clarification Pattern

When ambiguity exists, Claude should respond with a short question listing the realistic options, **not** guess. Example:

> User: "Show me ads performance across Amazon, eBay, and Google for the last 30 days."
>
> Claude: "Before I run this — the platforms don't share the same 'ad' grain:
> - **Amazon** has ad-level data (per ASIN/SKU)
> - **eBay** has ad-level data only for Standard/CPS campaigns; Advanced/CPC campaigns are campaign-grain only
> - **Google** has no ad grain — it has product-grain (Shopping/Search) and asset-grain (PMAX)
>
> How would you like me to compare?
> 1. **Campaign-level totals** across all three (most apples-to-apples)
> 2. **Best available grain per platform** (Amazon: ads, eBay: split by strategy, Google: products)
> 3. **Custom mapping** — tell me which grain you want for each"

### When NOT to Ask

Skip the clarification step when:
1. The user names the grain explicitly ("campaign-level", "by product", "ad-by-ad")
2. The user names only one platform — use that platform's natural grain
3. The user asks for "total spend/sales" cross-platform — default to campaign-grain and state the assumption inline



## ⚠️ eBay Campaign Type Translation Rule (CRITICAL — prevents hallucination)

Users describe eBay campaigns in **business terminology**, but the database stores **raw eBay API values**. You MUST translate user terms before querying.

### Terminology Mapping

| User says (any of these) | Actual DB value (`record_subtype`) | What it is |
|--------------------------|------------------------------------|------------|
| **Advanced** / **Priority** / **CPC** / **Cost Per Click** / **priority strategy** / **on-site** | `ON_SITE` | eBay's premium ad placement, charged per click |
| **Standard** / **General** / **CPS** / **Cost Per Sale** / **general strategy** | `COST_PER_SALE` | eBay's basic promoted listing, charged on attributed sale |
| **Off-site** / **External** | `OFF_SITE` | eBay external traffic ads |

### Translation Rules for eBay Queries

1. **Always filter by `record_subtype`** when the user mentions any of the above terms.
2. **Always join `public.ppc` to read `record_subtype`** — `public.ppc_performance` does not store campaign type.
3. The user's word is NOT a search term — do not use `record_name LIKE '%advanced%'`. Use `p.record_subtype = 'ON_SITE'`.



### Example Queries with Terminology Translation

#### "Show me advanced campaign performance" → ON_SITE
```sql
SELECT p.record_name AS campaign_name,
       p.record_subtype AS campaign_type,
       p.record_status,
       SUM(pp.impressions) AS impressions,
       SUM(pp.clicks)      AS clicks,
       SUM(pp.spend)       AS spend,
       SUM(pp.sales)       AS sales,
       SUM(pp.orders)      AS units_sold
FROM public.ppc p
JOIN public.ppc_performance pp ON p.parent_id = pp.parent_id
WHERE pp.source = 2
  AND p.record_main_type = 'campaign'
  AND pp.record_type = 'campaign'
  AND p.record_subtype = 'ON_SITE'           -- ← "advanced" / "priority" / "CPC"
GROUP BY p.record_name, p.record_subtype, p.record_status;
```


#### "Show me standard campaign performance" → COST_PER_SALE
```sql
SELECT p.record_name AS campaign_name,
       p.record_subtype AS campaign_type,
       p.record_status,
       SUM(pp.impressions) AS impressions,
       SUM(pp.clicks)      AS clicks,
       SUM(pp.spend)       AS spend,
       SUM(pp.sales)       AS sales,
       SUM(pp.orders)      AS units_sold
FROM public.ppc p
JOIN public.ppc_performance pp ON p.parent_id = pp.parent_id
WHERE pp.source = 2
  AND p.record_main_type = 'campaign'
  AND pp.record_type = 'campaign'
  AND p.record_subtype = 'COST_PER_SALE'     -- ← "standard" / "general" / "CPS"
GROUP BY p.record_name, p.record_subtype, p.record_status;
```

### 🚫 CRITICAL — Never Sum ON_SITE + COST_PER_SALE Together (see top of file for full rule)

eBay's two campaign strategies (`ON_SITE` / Advanced and `COST_PER_SALE` / Standard) come from **different upstream tables with different metric definitions**. **Do NOT sum them into a single eBay total — ever, under any circumstances.**

**Rules:**
1. When the user asks for "total eBay spend/sales/orders", **always break it out by `record_subtype`** — return two rows (Advanced and Standard), not one combined number.
2. If the user explicitly asks for one combined number, **still return both separately** and explain why combining is analytically invalid.
3. Cross-platform totals (Amazon vs eBay vs Google) must keep eBay split into two rows — eBay never collapses to a single row.


---

## ⚠️ "Metrics" Keyword Expansion Rule

When a user asks for **"metrics"**, **"all metrics"**, **"full metrics"**, **"KPIs"**, or **"performance metrics"**, Claude MUST return the complete metric set below — not a subset, and not just spend/sales.

### Required Metric Set

| Metric | Source | Formula |
|--------|--------|---------|
| `impressions` | `pp.impressions` | `SUM(pp.impressions)` |
| `clicks` | `pp.clicks` | `SUM(pp.clicks)` |
| `spend` | `pp.spend` | `SUM(pp.spend)` |
| `sales` | `pp.sales` | `SUM(pp.sales)` |
| `orders` | `pp.orders` | `SUM(pp.orders)` |
| `acos` | derived | `spend / sales × 100` (Advertising Cost of Sale, %) |
| `roas` | derived | `sales / spend` (Return on Ad Spend, multiplier) |

### When NOT to Apply This Rule

Skip the expansion when the user names specific metrics:
- "Show me spend and sales" → return only spend and sales (and currency context)
- "Just impressions please" → return only impressions
- "What's the ROAS?" → return only ROAS (with sales/spend for context)
---

## Source Reference

| `source` | Platform   | `source_name` |
|----------|------------|---------------|
| 1        | Amazon     | AMAZON        |
| 2        | eBay       | EBAY          |
| 3        | Google Ads | SHOPIFY (legacy label — actually means Google Ads) |

`source_name` and `ss_name` are available in both `public.ppc` and `public.ppc_performance`. Note: the marketplace column is named **`market_place`** in `public.ppc` and **`marketplace`** in `public.ppc_performance` — use the correct name for the table being queried. Use `ppc` when joining log tables or doing entity-only lookups. Use `ppc_performance` columns directly when the query is already hitting that table for metrics.

---

## Reference Lists

**Platforms (`source_name`):** AMAZON, EBAY, SHOPIFY (SHOPIFY means Google Ads)

**Sub-Sources (`ss_name`) by Platform:**

- **AMAZON:** amazon Dcvoltage, amazon Ledsone, amazon SRM Amazon, Neighbour Market

- **EBAY:** electricalsone, huettenlampen, led_sone, ledsonede, so_926407

- **SHOPIFY:** 045e77-2, electricalsoneuk, jedsz8-km, ledsone, ledsone-de, ledsone-us, vintage-light-web

**Marketplaces (`marketplace`):** Austria, Belgium, Belgium_Dutch, Belgium_French, Canada, France, Germany, Ireland, Italy, Mexico, Netherlands, Poland, Saudi Arabia, Spain, Sweden, Switzerland, UK, United Arab Emirates, US

**Categories:** Artificial Flowers, Batton Aluminium lighting, Belts, Cable tie, Cables, Ceiling light - Cone Shade Set, Ceiling light - Wide Shade Set, Ceiling light Curvy set, Ceiling light Dome shade set, Ceiling light Flat shade, Ceiling roses, Chains, Clip boards, Clocks, Conduit lighting, Connector, Crystal Glass Lamp Shades, Fabric Shades, Gift Bags, Glass Lamp Shades, Hemp set, Holder Rings, Injection module & C, Lamp holders, Laundry Bag, LED Bulbs, Mail Bag, Metal Lamp Shades, Mortar and pestle, Mosque and Tear Drop shades, Panel Lights, Peel and stick, Pendant lights, Pipe Lightings, Plug in Pendants, Reducer Plates, Shade Rings, Spare parts, Spot Lights, Storage Bag, Table Lamps, Tapes, Thread rods, Tile's spare parts, Transformer, Wall lamps, Wall Plugs, Screws, Water proof Junction box, White boards, Wire Cages

**Users:** Abinayaa, anoja, Arudchelvi, Dilani, Illakkiya, Jasmini, Jubista, kobitharsan, mothajini, Nithushana, paulr, Poovitha, prasath, preethi, Renuha, Saranya, Shanthini, shimee, thanucha, thanusha, Tharshana, Tharsiga(nelli), Tharsika(jaffna), Theepana, Thojika, thuwaraga, utharsika
