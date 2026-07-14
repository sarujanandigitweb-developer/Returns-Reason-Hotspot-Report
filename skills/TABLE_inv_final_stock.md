# Table Definition: Inventory Stock Tables

## ⚠️ Execution Requirement
After generating any SQL against these tables, **always execute it immediately using `postgres:execute_sql`** and return the real query results to the user. Never present a SQL query alone as the final answer.

---

## ⚠️ Mandatory Live-Data Statement (every stock answer)

For **every** stock question the user asks, the response **must explicitly state — in bold font — that the figures are based on live data (not past records)**. This applies to all stock answers without exception, regardless of whether a date is involved.

Use this bold line in the output:

> **These Stock figures are based on live data, not past records.**

**Rules:**
- Include this **bold** statement in **every** stock answer — never omit it.
- This is separate from the date-range disclaimer below; for past date / date-range questions, show **both** this bold live-data statement **and** the live stock disclaimer.

---

## Table Selection — Priority Rule

| User Intent | Table to Use |
|---|---|
| General stock check / "how much stock?" / "is X in stock?" / "low stock?" / country-level stock | **`public.location_wise_inv_stock`** ← **DEFAULT** |
| Asks about a specific warehouse by name (e.g. "UK Unit3", "Duisburg") or wants warehouse-level breakdown | **`public.inv_final_stock`** |

> **Always default to `location_wise_inv_stock` unless the user explicitly mentions a warehouse name or wants warehouse-level breakdown.**

---

## Table 1 (Default): `public.location_wise_inv_stock`

### Purpose
Country/location-level stock snapshot. Use for all general stock queries — availability, low stock, out-of-stock analysis — grouped by country/region.

### Schema

| Column | Type | Description |
|---|---|---|
| `id` | bigint | Primary key |
| `sku` | text | Internal SKU |
| `stock` | bigint | Current stock quantity at this location |
| `location` | text | Country/region name (e.g. `US`, `UK`, `Germany`) |
| `updated_at` | timestamp | Last updated timestamp |

### Known Location Values
`US`, `UK`, `Germany`

### Key Business Rules
- **Primary identifier** = `sku`
- Filter by country/region → `location`
- Has `updated_at` — can be used for recency checks (e.g. "updated today")
- **No warehouse-level detail** — use `inv_final_stock` if user needs that
- Aggregate across locations: `SUM(COALESCE("stock", 0))`

### Stock Level Query Patterns

| Goal | Condition |
|---|---|
| Out of stock | `WHERE "stock" = 0` |
| Low stock | `WHERE "stock" < threshold AND "stock" > 0` |
| In stock | `WHERE "stock" > 0` |
| Total stock by SKU | `GROUP BY "sku"` with `SUM(COALESCE("stock", 0))` |
| Total stock by location | `GROUP BY "location"` with `SUM(COALESCE("stock", 0))` |
| Filter by country | `WHERE "location" = 'US'` / `'UK'` / `'Germany'` |

---

## Table 2 (Warehouse-specific): `public.inv_final_stock`

### Purpose
Warehouse-level stock snapshot. Use **only** when the user explicitly asks about a specific warehouse or wants stock broken down by individual warehouse.

### Schema

| Column | Type | Description |
|---|---|---|
| `id` | bigint | Primary key |
| `sku` | text | Internal SKU |
| `stock` | bigint | Current stock quantity in the warehouse |
| `warehouse_name` | text | Warehouse name (e.g. `UK Unit3`, `Duisburg warehouse`) |
| `warehouse_location` | text | Country/region of the warehouse (e.g. `UK`, `Germany`, `US`) |

### Known Warehouses

| warehouse_name | warehouse_location |
|---|---|
| UK Unit3 | UK |
| UK Unit18 | UK |
| UK Unit4 | UK |
| Trossingen kronen str | Germany |
| Trossingen schmutter str | Germany |
| Duisburg warehouse | Germany |
| US1 | US |

### Key Business Rules
- **Primary identifier** = `sku`
- Filter by warehouse name → `warehouse_name`
- Filter by country → `warehouse_location`
- **No date column** — current snapshot only; no time-series queries possible
- Aggregate across warehouses: `SUM(COALESCE("stock", 0))`
- One SKU can appear in multiple warehouses — always `SUM` when total stock is needed

### Stock Level Query Patterns

| Goal | Condition |
|---|---|
| Out of stock | `WHERE "stock" = 0` |
| Low stock | `WHERE "stock" < threshold AND "stock" > 0` |
| In stock | `WHERE "stock" > 0` |
| Total stock by SKU | `GROUP BY "sku"` with `SUM(COALESCE("stock", 0))` |
| Stock by warehouse | `GROUP BY "warehouse_name"` with `SUM(COALESCE("stock", 0))` |
| Filter by warehouse | `WHERE "warehouse_name" = 'UK Unit3'` |
| Filter by country | `WHERE "warehouse_location" = 'UK'` |

---

## SKU Type Handling (applies to both tables)

| Type | Pattern | Example | Filter Rule |
|---|---|---|---|
| single | Base SKU | `ABC123` | Exact match `=` |
| pack | Base SKU + `PK` suffix | `ABC123PK` | `LIKE '%PK'` or exact match |
| combo | Two or more SKUs joined by `+` | `ABC123+XYZ456` | `LIKE '%+%'` or exact match |

- If user provides a base SKU with no suffix → search single (exact match)
- If user provides SKU ending in `PK` → search pack version
- If user provides SKU containing `+` → search combo version
- If user intent is unclear → consider all three variations

---

## ⚠️ Live Stock Disclaimer — Date/Date-Range Queries

When a user asks about stock for a **past date or date range** (e.g. "what was the stock last week?", "show me stock on 2024-01-15", "stock between Jan and Feb"), you **must include the following disclaimer clearly in the output**:

> ⚠️ **Note:** The stock figures shown are **current live stock levels** as of today. These tables do not store historical stock snapshots — there is no record of what stock was on a past date or date range. The results **do not reflect stock at the requested time**.

**Rules:**
- Always show this disclaimer **before or immediately after** the query results — never omit it when a date or date range is part of the stock question.
- If the user's intent is purely a stock check with no date filter applied (e.g. "how much stock do I have?"), no disclaimer is needed.
- This applies to **both** `location_wise_inv_stock` and `inv_final_stock` — neither table supports point-in-time stock history.

---

## Bridge to Other Tables

| Target Table | Join Key | Notes |
|---|---|---|
| `order_transaction` | `inv_final_stock.sku = order_transaction.sku` | Direct SKU join |
| `ppc_performance` | `inv_final_stock.sku = ppc_performance.sku` | Amazon only — `source = 1`, `record_type = 'ad'`, `sku != '0'` |
| `traffic_data` | Two-step: inv_final_stock → order_transaction (get ASIN) → traffic_data | No direct join; traffic_data has no SKU |

### ASIN-to-SKU Bridging (for ASIN-based queries that need stock)

When combining top ASINs (from sales/traffic/campaign) with stock data:

```
Step 1: Aggregate source table → get top N ASINs by metric (aggregate first, LIMIT after)
Step 2: SELECT DISTINCT "asin", "sku" FROM order_transaction WHERE "asin" IN (top_asins)
        -- DISTINCT prevents one row per transaction; gives clean one-to-one ASIN→SKU mapping
Step 3: JOIN the mapping to the chosen inventory table on sku
Step 4: SUM stock if one ASIN maps to multiple SKUs
```
## Amazon PPC → Stock Lookup Rule

### ⚠️ Never use LIKE for SKU stock checks

When looking up stock for Amazon PPC ASINs/SKUs, **always use exact match (`=`)** on the inventory table.
Using `LIKE '%sku%'` pattern matches unrelated SKUs and inflates stock figures incorrectly.

```sql
-- ❌ WRONG — LIKE matches unrelated SKUs, overstates stock
WHERE sku LIKE '%WCFL180BM2PK%'

-- ✅ CORRECT — exact match only
WHERE sku = 'WCFL180BM2PK'
```

---

### SKU Resolution: PPC Listing SKU → Inventory SKU

The SKU stored in `ppc_performance` is the **Amazon listing SKU**, which may have suffixes or variants appended. The inventory table uses a **base SKU** that is different. Before querying stock, always strip the listing SKU down to its base form using the steps below.

#### Step 1 — Strip marketplace suffixes

Remove any of these trailing suffixes (case-sensitive):

| Suffix |
|---|
| `-IDE` |
| `-CA` |
| `-IFR` |
| `-NL` |

**Example:** `WCFL180BM2PK-IDE` → `WCFL180BM2PK`

#### Step 2 — Strip double-underscore variant segment

If the SKU contains `__`, remove the **last** `__`-delimited segment.

**Example:** `WCFL180BM2PK__AMD` → `WCFL180BM2PK`

#### Step 3 — Strip single-underscore variant segment

If the SKU still contains `_`, remove the **last** `_`-delimited segment.

**Example:** `WCFL180BM2PK_AML` → `WCFL180BM2PK`

#### Step 4 — Trim whitespace

Always trim leading/trailing whitespace after each step.

---

### Full Resolution Example

| PPC listing SKU | After suffix strip | After `__` strip | After `_` strip | Final inventory SKU |
|---|---|---|---|---|
| `WCFL180BM2PK-IDE` | `WCFL180BM2PK` | — | — | `WCFL180BM2PK` |
| `WCFL180BM2PK__AMD` | — | `WCFL180BM2PK` | — | `WCFL180BM2PK` |
| `WCFL180BM2PK_AML` | — | — | `WCFL180BM2PK` | `WCFL180BM2PK` |
| `WCB4WH2PK+RPR44WH2PK_AMD` | — | — | `WCB4WH2PK+RPR44WH2PK` | `WCB4WH2PK+RPR44WH2PK` |
| `amzn.gr.WCFL180BM2PK-U4FYO9lftoPCbYwL-VG` | — | — | — | ⚠️ skip (platform alias — see below) |

---

### Platform Alias SKUs (`amzn.gr.*`)

SKUs prefixed with `amzn.gr.` are Amazon-generated internal aliases. They **do not exist in the inventory table** and should be **excluded** from stock lookups entirely.

```sql
-- Exclude amzn.gr.* SKUs before stock lookup
WHERE pp.sku NOT LIKE 'amzn.gr.%'
```

---

### Full SQL Pattern for Amazon PPC → UK Stock

```sql
WITH campaign_skus AS (
    -- Get distinct listing SKUs from ppc_performance for the campaign
    SELECT DISTINCT
        pp.ref_id  AS asin,
        pp.sku     AS listing_sku,
        -- Apply base SKU resolution inline or pre-process in application layer
        -- After stripping suffixes/__/_ segments, use the resolved base SKU below
        pp.sku     AS base_sku   -- replace with resolved value after stripping
    FROM public.ppc_performance pp
    JOIN public.ppc p ON p.parent_id = pp.parent_id
    WHERE pp.source = 1
      AND pp.record_type = 'ad'
      AND pp.sku != '0'
      AND pp.sku NOT LIKE 'amzn.gr.%'       -- exclude platform aliases
      AND p.record_name = '<campaign_name>'
      AND pp.date >= CURRENT_DATE - INTERVAL '30 days'
),
stock AS (
    SELECT
        sku,
        SUM(COALESCE(stock, 0)) AS uk_stock
    FROM public.location_wise_inv_stock
    WHERE location = 'UK'
      AND sku = ANY(ARRAY(SELECT base_sku FROM campaign_skus))  -- exact match only, never LIKE
    GROUP BY sku
)
SELECT
    cs.asin,
    cs.listing_sku,
    cs.base_sku,
    COALESCE(s.uk_stock, 0) AS uk_stock
FROM campaign_skus cs
LEFT JOIN stock s ON s.sku = cs.base_sku
ORDER BY uk_stock DESC;
```

> **Key rules recap:**
> - Always resolve listing SKU → base SKU before querying stock
> - Always use exact match `=` on the inventory table — never `LIKE`
> - Always exclude `amzn.gr.*` SKUs from stock lookups
> - Always filter `location = 'UK'` (or relevant country) — never query global stock when a country is specified
> 
**Never** join aggregated ASIN results back to raw `order_transaction` without DISTINCT — each transaction row creates a duplicate, inflating every metric.