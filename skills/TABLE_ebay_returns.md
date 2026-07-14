# Table Definition: `public.ebay_returns`

## ⚠️ Execution Requirement
After generating any SQL against this table, **always execute it immediately using `postgres:execute_sql`** and return the real query results to the user. Never present a SQL query alone as the final answer.

---

## Purpose
eBay return records table. Stores eBay return requests with refund amounts. Use for return reason analysis, return rate by order, and refund reporting.


> ✅ **Refund amount is directly available** — use `seller_refund_amount` for all refund reporting. No join to finance tables required.

---

## Schema

| Column | Type | Description |
|---|---|---|
| `id` | bigint | Primary key |
| `res_his_order` | double precision | Resolution history sequence — **`0` = current return row**; always filter `res_his_order = 0` when fetching return data (exclude history rows) |
| `request_date` | timestamp | Date and time the return was requested by the buyer — use for return-date filtering and trend analysis. Cast to `::date` for day-level grouping |
| `order_id` | text | eBay Order ID — joins to `public.order_transaction.order_id` |
| `reason` | text | Return reason — see Reason Reference below |
| `return_qty` | double precision | Quantity being returned |
| `comments` | text | Buyer free-text comments |
| `seller_refund_amount` | double precision | **Primary refund field — refund amount in seller currency. Always use this for refund reporting** |
| `seller_currency` | text | Seller currency code (e.g. `GBP`, `USD`) |
| `buyer_refund_amount` | double precision | Refund amount in buyer currency |
| `buyer_currency` | text | Buyer currency code |
| `sub_source` | bigint | Seller account identifier |
| `market_place_code` | text | eBay marketplace code — see Marketplace Reference below |
| `market_place` | text | Marketplace identifier (alternative to `market_place_code`) |
| `sub_source_name` | text | Human-readable name for the seller account (`sub_source`) |

---

## Key Reference Values

### `reason` — Return Reason

| Value | Meaning |
|---|---|
| `DOES_NOT_FIT` | Item does not fit |
| `NOT_AS_DESCRIBED` | Item not as described in listing |
| `DAMAGED_IN_SHIPPING` | Damaged during delivery |
| `DEFECTIVE_ITEM` | Item is faulty |
| `UNWANTED_GIFT` | Unwanted gift |
| `CHANGED_MIND` | Buyer changed mind |
| `MISSING_PARTS` | Parts or accessories missing |
| `WRONG_ITEM` | Wrong item received |
| `ARRIVED_LATE` | Item arrived too late |

### `market_place_code` — eBay Marketplace

| Value | Meaning |
|---|---|
| `EBAY_GB` | eBay UK |
| `EBAY_US` | eBay US |
| `EBAY_DE` | eBay Germany |
| `EBAY_FR` | eBay France |

---

## Key Business Rules

- **Always filter `res_his_order = 0`** — every query that fetches eBay return data must include `WHERE "res_his_order" = 0` (or `r."res_his_order" = 0` when aliased). Non-zero values are resolution history rows and must be excluded from reporting.
- **`seller_refund_amount` is the only refund field needed** — no join to an expenses table is required. Use `seller_refund_amount` + `seller_currency` for all seller-side refund reporting.
- **`buyer_refund_amount` is in buyer currency** — may differ from `seller_refund_amount` if buyer and seller are in different regions. Always use `seller_refund_amount` for internal reporting.
- **One row per return** — use `id` as the row identifier when a unique key is needed.
- **`sub_source`** identifies the seller account — always filter when working with multi-account setups.
- **Sub-source / store name filter — always use `=`, never `LIKE`**: When filtering by `sub_source_name`, always use exact match (`=`). Using `LIKE` risks matching REPLACEMENT/RESEND suffix variants and cross-platform name overlaps.
- **`market_place_code`** identifies the eBay site — filter `EBAY_GB` for UK, `EBAY_DE` for Germany etc.
- **Date filtering** — use `r."request_date"` to filter by when the return was requested (native to this table, no join needed). Use `order_transaction.order_date` via join on `order_id` when filtering by original order date. `request_date` is a `timestamp` — cast to `::date` for day-level comparisons and use half-open intervals: `"request_date" >= '2026-04-01' AND "request_date" < '2026-05-01'`.

---

## Refund Amount — Direct from Table

No join needed. Use `seller_refund_amount` directly for all refund analysis:

```sql
-- Total refunded per return
SELECT "id", "order_id", "request_date", "seller_refund_amount", "seller_currency"
FROM public.ebay_returns
WHERE "res_his_order" = 0;

-- Total refunds by reason
SELECT
    "reason",
    COUNT(*) AS return_count,
    SUM("seller_refund_amount") AS total_refunded,
    "seller_currency"
FROM public.ebay_returns
WHERE "res_his_order" = 0
GROUP BY "reason", "seller_currency"
ORDER BY total_refunded DESC;
```

---

## Return Breakdown Response Format

> **Note:** When a user asks for a **returns breakdown**, always structure the response as two parts:
>
> **Part 1 — Full Detail View** (one row per return line):
> Include: `item_id`, `sku`, `order_date`, `market_place`, `sub_source` (account/store), `return_qty` (units), `reason` (return reason), `seller_refund_amount`, PH user, category.
>
> **Part 2 — Summary View** (aggregated):
> Group by: Channel → Marketplace → Account/Store.
> Columns: Return Lines, Units, Refund, Currency.
>
> **Below the summary**, add a further breakdown **by PH holder** (PH user wise summary).

---

## Common Query Patterns

### Top returned orders by volume
```sql
SELECT
    "order_id",
    "request_date"::date AS request_date,
    COUNT(*) AS return_count,
    SUM("seller_refund_amount") AS total_refunded,
    "seller_currency"
FROM public.ebay_returns
WHERE "res_his_order" = 0
GROUP BY "order_id", "request_date"::date, "seller_currency"
ORDER BY return_count DESC
LIMIT 10;
```

### Returns by month (using request_date)
```sql
SELECT
    DATE_TRUNC('month', "request_date") AS return_month,
    COUNT(*) AS return_count,
    SUM("return_qty") AS total_qty,
    SUM("seller_refund_amount") AS total_refunded,
    "seller_currency"
FROM public.ebay_returns
WHERE "res_his_order" = 0
  AND "request_date" IS NOT NULL
GROUP BY DATE_TRUNC('month', "request_date"), "seller_currency"
ORDER BY return_month DESC;
```

### Returns for a specific date range (request_date)
```sql
SELECT
    r."id",
    r."order_id",
    r."request_date",
    r."reason",
    r."return_qty",
    r."seller_refund_amount",
    r."seller_currency",
    r."market_place_code"
FROM public.ebay_returns r
WHERE r."res_his_order" = 0
  AND r."request_date" >= '2026-04-01'
  AND r."request_date" < '2026-05-01'
ORDER BY r."request_date";
```

### Return reasons breakdown
```sql
SELECT
    "reason",
    COUNT(*) AS count,
    COUNT(*) * 100.0 / SUM(COUNT(*)) OVER() AS pct,
    SUM("seller_refund_amount") AS total_refunded
FROM public.ebay_returns
WHERE "res_his_order" = 0
GROUP BY "reason"
ORDER BY count DESC;
```

### Returns by marketplace
```sql
SELECT
    "market_place_code",
    COUNT(*) AS return_count,
    SUM("seller_refund_amount") AS total_refunded,
    "seller_currency"
FROM public.ebay_returns
WHERE "res_his_order" = 0
GROUP BY "market_place_code", "seller_currency"
ORDER BY return_count DESC;
```

### Returns with buyer comments
```sql
SELECT
    "id",
    "order_id",
    "reason",
    "comments",
    "seller_refund_amount"
FROM public.ebay_returns
WHERE "res_his_order" = 0
  AND "comments" IS NOT NULL AND TRIM("comments") != ''
ORDER BY "id" DESC;
```

### Returns by sub_source (seller account)
```sql
SELECT
    "sub_source",
    COUNT(*) AS return_count,
    SUM("seller_refund_amount") AS total_refunded,
    "seller_currency"
FROM public.ebay_returns
WHERE "res_his_order" = 0
GROUP BY "sub_source", "seller_currency"
ORDER BY return_count DESC;
```

### Returns with full details
```sql
SELECT
    "id",
    "order_id",
    "request_date",
    "reason",
    "comments",
    "return_qty",
    "seller_refund_amount",
    "seller_currency",
    "market_place_code"
FROM public.ebay_returns
WHERE "res_his_order" = 0
ORDER BY "request_date" DESC NULLS LAST;
```

---

## Bridge to Other Tables

| Target Table | Schema | Join Key | Notes |
|---|---|---|---|
| `order_transaction` | `public` | `ebay_returns.order_id = order_transaction.order_id` | Join for order-level context; always filter `ebay_returns.res_his_order = 0` |

---

## Bridge to `order_transaction` (Order Context)

Join `public.ebay_returns` → `public.order_transaction` on `order_id` to enrich return records with order metadata.

```sql
-- Returns enriched with order context
SELECT
    r."id",
    r."order_id",
    r."request_date",
    r."reason",
    r."seller_refund_amount",
    r."seller_currency",
    r."market_place_code",
    ot."order_total",
    ot."order_date",
    ot."ss_name",
    ot."market_place",
    ot."order_status",
    ot."sku"
FROM public.ebay_returns r
LEFT JOIN public.order_transaction ot
    ON r."order_id" = ot."order_id"
WHERE r."res_his_order" = 0
ORDER BY r."request_date" DESC NULLS LAST;
```

### Returns with order value (revenue at risk)
```sql
SELECT
    r."id",
    r."order_id",
    r."request_date",
    r."reason",
    r."seller_refund_amount",
    r."seller_currency",
    ot."order_date",
    ot."order_total",
    ot."ss_name",
    ot."market_place"
FROM public.ebay_returns r
LEFT JOIN public.order_transaction ot
    ON r."order_id" = ot."order_id"
WHERE r."res_his_order" = 0
  AND r."request_date" >= CURRENT_DATE - INTERVAL '30 days'
ORDER BY ot."order_total" DESC NULLS LAST;
```

### Return rate by SKU (returns vs orders)
```sql
SELECT
    ot."sku",
    COUNT(DISTINCT ot."order_id") AS total_orders,
    COUNT(DISTINCT r."order_id") AS returned_orders,
    COUNT(DISTINCT r."order_id") * 100.0 / NULLIF(COUNT(DISTINCT ot."order_id"), 0) AS return_rate_pct
FROM public.order_transaction ot
LEFT JOIN public.ebay_returns r
    ON ot."order_id" = r."order_id"
    AND r."res_his_order" = 0
WHERE ot."source_name" = 'EBAY'
  AND ot."order_status" = 'Completed'
  AND ot."order_date"::date >= CURRENT_DATE - INTERVAL '90 days'
GROUP BY ot."sku"
ORDER BY return_rate_pct DESC NULLS LAST;
```
