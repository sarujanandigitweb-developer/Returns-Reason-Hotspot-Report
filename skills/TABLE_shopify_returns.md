# Table Definition: `public.shopify_returns`

## ⚠️ Execution Requirement
After generating any SQL against this table, **always execute it immediately using `postgres:execute_sql`** and return the real query results to the user. Never present a SQL query alone as the final answer.

---

## Purpose
Shopify return / refund records table. Stores refund events for Shopify orders with refund amounts in the store currency. Use for refund reporting, refund totals per order, and refund trend analysis.

> ✅ **Refund amount is directly available** — use `refund_amount` for all refund reporting. No join to finance/expenses tables required.

> 🔁 **Multiple refund rows per order are expected** — a single `order_id` can have several refund records (partial refunds issued on different dates). Always treat one row = one refund event, not one row = one order. See **Multiple Refunds Per Order** below.

---

## Schema

| Column | Type | Description |
|---|---|---|
| `id` | bigint | Primary key — unique per refund event (one row = one refund) |
| `date` | timestamp | Date and time the refund was issued — use for refund-date filtering and trend analysis. Cast to `::date` for day-level grouping |
| `order_id` | text | Shopify Order ID / name (e.g. `LED29351`) — joins to `public.order_transaction.order_id`. **Not unique in this table** — repeats when an order has multiple refunds |
| `refund_amount` | double precision | **Primary refund field — refund amount in store currency. Always use this for refund reporting.** Each row is one refund event; sum across rows for the order total |
| `refund_currency` | text | Currency code of the refund (e.g. `GBP`, `EUR`, `CAD`, `USD`) |
| `sub_source` | bigint | Seller / store account identifier |
| `sub_source_name` | text | Human-readable name for the store account (`sub_source`) |

---

## Key Reference Values

### `refund_currency` — Refund Currency

| Value | Meaning |
|---|---|
| `GBP` | British Pound |
| `EUR` | Euro |
| `CAD` | Canadian Dollar |
| `USD` | US Dollar |

### `sub_source_name` — Store Account

| Value |
|---|
| `ledsone` |
| `ledsone-de` |
| `ledsone-us` |
| `vintage-light-web` |
| `electricalsoneuk` |
| `relicelectrical` |
| `dcvoltage-2` |
| `045e77-2` |
| `jedsz8-km` |

---

## Key Business Rules

- **Multiple refunds per order — never assume one row per order.** A given `order_id` may appear on several rows, one per refund event (partial refunds processed on different dates). When asked for "refund details for an order", return **all** rows for that `order_id` and also provide the summed total. When counting refunds, `COUNT(*)` counts refund events; use `COUNT(DISTINCT order_id)` to count distinct refunded orders. See examples below.
- **`refund_amount` is the only refund field needed** — no join to an expenses table is required. Use `refund_amount` + `refund_currency` for all refund reporting.
- **Mind the currency when summing** — refunds span `GBP`, `EUR`, `CAD`, `USD`. Group/sum by `refund_currency` (do **not** sum raw amounts across different currencies as if one figure).
- **Date filtering** — use `r."date"` to filter by when the refund was issued (native to this table, no join needed). Use `order_transaction.order_date` via join on `order_id` when filtering by the **original order date** instead of the refund date. Prefer `date` over `created_at` for reporting — `date` is the refund event date; `created_at` is the ETL ingestion timestamp. `date` is a `timestamp` — cast to `::date` for day-level comparisons and always use half-open intervals: `"date" >= '2026-05-01' AND "date" < '2026-06-01'`.
- **`id` is the unique row key** — use it when a unique refund-event identifier is needed (not `order_id`).
- **`sub_source`** identifies the store account — always filter when working with multi-store setups.
- **Sub-source / store name filter — always use `=`, never `LIKE`**: When filtering by `sub_source_name`, always use exact match (`=`). Using `LIKE` risks matching REPLACEMENT/RESEND suffix variants and cross-platform name overlaps.
- **No history/status filter needed** — unlike `ebay_returns` (which requires `res_his_order = 0`), this table has no resolution-history rows. Every row is a live refund event.

---

## Multiple Refunds Per Order

A single order can have several refund records. Example — order `LED29351` has **3** refund rows:

| date | refund_amount | refund_currency |
|---|---|---|
| 2025-05-13 | 1.43 | GBP |
| 2025-05-17 | 6.89 | GBP |
| 2025-06-17 | 71.68 | GBP |
| **Total** | **80.00** | GBP |

### Refund details for a specific order (all refund rows)
Returns every individual refund event for the order — use this when the user asks for "refund details for order X".
```sql
SELECT
    "id",
    "order_id",
    "date",
    "refund_amount",
    "refund_currency",
    "sub_source_name"
FROM public.shopify_returns
WHERE "order_id" = 'LED29351'
ORDER BY "date";
```

### Total refunded for a specific order (one summary row)
Use when the user wants a single refunded figure for the order.
```sql
SELECT
    "order_id",
    COUNT(*)            AS refund_events,
    SUM("refund_amount") AS total_refunded,
    "refund_currency"
FROM public.shopify_returns
WHERE "order_id" = 'LED29351'
GROUP BY "order_id", "refund_currency";
```

### Orders that received more than one refund
```sql
SELECT
    "order_id",
    COUNT(*)             AS refund_events,
    SUM("refund_amount") AS total_refunded,
    "refund_currency"
FROM public.shopify_returns
GROUP BY "order_id", "refund_currency"
HAVING COUNT(*) > 1
ORDER BY refund_events DESC, total_refunded DESC;
```

---

## Refund Amount — Direct from Table

No join needed. Use `refund_amount` directly for all refund analysis:

```sql
-- Refund amount per refund event
SELECT "id", "order_id", "date", "refund_amount", "refund_currency"
FROM public.shopify_returns
ORDER BY "date" DESC;

-- Total refunds by store account and currency
SELECT
    "sub_source_name",
    "refund_currency",
    COUNT(*)             AS refund_events,
    COUNT(DISTINCT "order_id") AS refunded_orders,
    SUM("refund_amount") AS total_refunded
FROM public.shopify_returns
GROUP BY "sub_source_name", "refund_currency"
ORDER BY total_refunded DESC;
```

---

## Common Query Patterns

### Refunds by month (using `date`)
```sql
SELECT
    DATE_TRUNC('month', "date") AS refund_month,
    COUNT(*)                    AS refund_events,
    COUNT(DISTINCT "order_id")  AS refunded_orders,
    SUM("refund_amount")        AS total_refunded,
    "refund_currency"
FROM public.shopify_returns
WHERE "date" IS NOT NULL
GROUP BY DATE_TRUNC('month', "date"), "refund_currency"
ORDER BY refund_month DESC;
```

### Refunds for a specific date range (date)
```sql
SELECT
    r."id",
    r."order_id",
    r."date",
    r."refund_amount",
    r."refund_currency",
    r."sub_source_name"
FROM public.shopify_returns r
WHERE r."date" >= '2026-05-01'
  AND r."date" <  '2026-06-01'
ORDER BY r."date";
```

### Top refunded orders by total value
```sql
SELECT
    "order_id",
    COUNT(*)             AS refund_events,
    SUM("refund_amount") AS total_refunded,
    "refund_currency"
FROM public.shopify_returns
GROUP BY "order_id", "refund_currency"
ORDER BY total_refunded DESC
LIMIT 10;
```

### Refunds by store account (`sub_source`)
```sql
SELECT
    "sub_source",
    "sub_source_name",
    COUNT(*)             AS refund_events,
    SUM("refund_amount") AS total_refunded,
    "refund_currency"
FROM public.shopify_returns
GROUP BY "sub_source", "sub_source_name", "refund_currency"
ORDER BY total_refunded DESC;
```

### Refunds by currency
```sql
SELECT
    "refund_currency",
    COUNT(*)             AS refund_events,
    SUM("refund_amount") AS total_refunded
FROM public.shopify_returns
GROUP BY "refund_currency"
ORDER BY total_refunded DESC;
```

---

## Bridge to Other Tables

| Target Table | Schema | Join Key | Notes |
|---|---|---|---|
| `order_transaction` | `public` | `shopify_returns.order_id = order_transaction.order_id` | Join for order-level context. **Fan-out warning** — `order_transaction` has one row per line item, and `shopify_returns` has one row per refund, so a naive join multiplies rows. Pre-aggregate one side (see below) before joining for totals |

---

## Bridge to `order_transaction` (Order Context)

Join `public.shopify_returns` → `public.order_transaction` on `order_id` to enrich refunds with order metadata.

> ⚠️ **Fan-out:** both tables can have multiple rows per `order_id` (refunds × line items). For per-refund detail a `LEFT JOIN` is fine, but for **totals**, aggregate refunds per order first, then join — otherwise refund amounts get double-counted.

### Refund detail enriched with order context (per refund row)
```sql
SELECT
    r."id",
    r."order_id",
    r."date"        AS refund_date,
    r."refund_amount",
    r."refund_currency",
    r."sub_source_name",
    ot."order_total",
    ot."order_date",
    ot."ss_name",
    ot."market_place",
    ot."order_status",
    ot."sku"
FROM public.shopify_returns r
LEFT JOIN public.order_transaction ot
    ON r."order_id" = ot."order_id"
ORDER BY r."date" DESC NULLS LAST;
```

### Total refunded per order vs order value (no double-count)
```sql
WITH refunds AS (
    SELECT
        "order_id",
        SUM("refund_amount") AS total_refunded,
        MAX("refund_currency") AS refund_currency,
        COUNT(*) AS refund_events
    FROM public.shopify_returns
    GROUP BY "order_id"
)
SELECT
    rf."order_id",
    rf."refund_events",
    rf."total_refunded",
    rf."refund_currency",
    ot."order_total",
    ot."order_date",
    ot."ss_name",
    ot."market_place"
FROM refunds rf
LEFT JOIN public.order_transaction ot
    ON rf."order_id" = ot."order_id"
ORDER BY rf."total_refunded" DESC NULLS LAST;
```

### Refunds with order value (revenue at risk, last 30 days)
Date-filtered on the refund `date` — surfaces recently refunded orders alongside their original order value.
```sql
SELECT
    r."id",
    r."order_id",
    r."date"          AS refund_date,
    r."refund_amount",
    r."refund_currency",
    r."sub_source_name",
    ot."order_date",
    ot."order_total",
    ot."ss_name",
    ot."market_place"
FROM public.shopify_returns r
LEFT JOIN public.order_transaction ot
    ON r."order_id" = ot."order_id"
WHERE r."date" >= CURRENT_DATE - INTERVAL '30 days'
ORDER BY ot."order_total" DESC NULLS LAST;
```

### Refund rate by SKU (refunded orders vs total orders)
```sql
SELECT
    ot."sku",
    COUNT(DISTINCT ot."order_id") AS total_orders,
    COUNT(DISTINCT r."order_id")  AS refunded_orders,
    COUNT(DISTINCT r."order_id") * 100.0
        / NULLIF(COUNT(DISTINCT ot."order_id"), 0) AS refund_rate_pct
FROM public.order_transaction ot
LEFT JOIN public.shopify_returns r
    ON ot."order_id" = r."order_id"
WHERE ot."source_name" = 'SHOPIFY'
  AND ot."order_status" = 'Completed'
  AND ot."order_date"::date >= CURRENT_DATE - INTERVAL '90 days'
GROUP BY ot."sku"
ORDER BY refund_rate_pct DESC NULLS LAST;
```
> Note: confirm the actual `source_name` value for Shopify in `order_transaction` (e.g. `SHOPIFY`) before relying on the refund-rate query.

---

## Reference Lists

**Currencies (`refund_currency`):** GBP, EUR, CAD, USD

**Store accounts (`sub_source_name`):** ledsone, ledsone-de, ledsone-us, vintage-light-web, electricalsoneuk, relicelectrical, dcvoltage-2, 045e77-2, jedsz8-km
