# Table Definition: `public.amazon_returns`

## ⚠️ Execution Requirement
After generating any SQL against this table, **always execute it immediately using `postgres:execute_sql`** and return the real query results to the user. Never present a SQL query alone as the final answer.

---

## Purpose
Amazon return records table. Stores both FBA and FBM return events for all Amazon orders. Use for return reason analysis, return rate by SKU/ASIN, and customer comment review. For accurate refund monetary amounts, always join with `public.amz_order_expenses` on `order_id` + `item_id` where `event = 'RefundEventList'`.

---

## Schema

| Column | Type | Description |
|---|---|---|
| `id` | bigint | Primary key |
| `request_date` | date | Date the return was requested by the customer — use for return-date filtering and trend analysis |
| `order_id` | varchar | Amazon order ID (e.g. `202-6623994-1040308`) — can join to `amz_order_expenses.order_id` (for refund detail) or `order_transaction.order_id` (for order context) when needed |
| `asin` | varchar | Amazon Standard Identification Number |
| `item_id` | bigint | Order Item ID — joins to `amz_order_expenses.item_id` |
| `fulfilment` | varchar | `FBA` or `FBM` |
| `reason` | varchar | Return reason — see Reason Reference below |
| `comments` | text | Customer free-text comments |
| `qty` | bigint | Quantity returned |
| `sku` | varchar | Seller SKU |
| `refunded_amount` | double precision | Stored summary refund amount — **use `amz_order_expenses` for accurate detail** |
| `sub_source` | bigint | Seller account identifier — joins to sub-source tables |
| `market_place` | text | Marketplace identifier |
| `sub_source_name` | text | Seller account name |

---

## Key Reference Values

### `reason` — Return Reason

| Value | Meaning |
|---|---|
| `NO_REASON_GIVEN` | No reason provided |
| `NOT_AS_DESCRIBED` | Item did not match listing |
| `UNWANTED_ITEM` | Changed mind |
| `NOT_COMPATIBLE` | Did not fit or match |
| `QUALITY_UNACCEPTABLE` | Poor quality |
| `UNDELIVERABLE_UNKNOWN` | Delivery issue |
| `DEFECTIVE` | Manufacturing fault |

---

## Key Business Rules

- **Fulfilment filter** — use `"fulfilment" = 'FBA'` or `"fulfilment" = 'FBM'` when splitting FBA vs FBM returns.
- **Date filtering** — use `"request_date"` for return-date filtering (e.g. by month/day). Use half-open intervals: `"request_date" >= 'YYYY-MM-01' AND "request_date" < 'YYYY-MM-01'::date + INTERVAL '1 month'`. To find returns from orders placed on a specific date, join to `order_transaction` and filter on `ot."order_date"` instead.

- **`refunded_amount` is a denormalised summary** — for accurate refund breakdown, always join `amz_order_expenses` on `order_id` + `item_id` where `event = 'RefundEventList'`.
- **Multi-unit refunds use pipe suffix** — `charge_type` values like `Principal|0`, `Principal|1` represent quantity batches. Always filter with `LIKE 'Principal%'`, never `= 'Principal'`.
- **`amount` in `amz_order_expenses` is negative for buyer-side charges** (Principal, Tax) — multiply by `-1` to show as positive refund figure. Seller-side reversals (Commission, DigitalServicesFee) are already positive.
- **`sub_source`** identifies the seller account — filter when working with multi-account setups.
- **Sub-source / store name filter — always use `=`, never `LIKE`**: When filtering by `sub_source_name`, always use exact match (`=`). Using `LIKE` risks matching REPLACEMENT/RESEND suffix variants and cross-platform name overlaps.

---

## Bridge to `amz_order_expenses` (Refund Detail)

For accurate refund amounts, join on `order_id` + `item_id` where `event = 'RefundEventList'`.

| `charge_type` | Meaning | Sign |
|---|---|---|
| `Principal` / `Principal\|0` | Product refund to buyer | Negative |
| `Tax` / `Tax\|0` | VAT refunded to buyer | Negative |
| `Commission` / `Commission\|0` | Amazon fee reversed to seller | Positive |
| `RefundCommission` | Refund processing fee charged to seller | Negative |
| `DigitalServicesFee` | DSF returned to seller | Positive |

---

## Return Breakdown Response Format

> **Note:** When a user asks for a **returns breakdown**, always structure the response as two parts:
>
> **Part 1 — Full Detail View** (one row per return line):
> Include: `asin`, `sku`, `order_date`, `market_place`, `sub_source` (account/store), `fulfilment` (FBA or FBM), `qty` (units), `reason` (return reason), refund amount, PH user, category.
>
> **Part 2 — Summary View** (aggregated):
> Group by: Channel → Marketplace → Account/Store.
> Columns: Return Lines, Units, Refund, Currency.
>
> **Below the summary**, add a further breakdown **by PH holder** (PH user wise summary).

---

## Common Query Patterns

### Top returned SKUs
```sql
SELECT "sku", "asin", COUNT(*) AS return_count
FROM public.amazon_returns
GROUP BY "sku", "asin"
ORDER BY return_count DESC
LIMIT 10;
```

### Returns by month (using request_date)
```sql
SELECT
    DATE_TRUNC('month', "request_date") AS return_month,
    COUNT(*) AS return_count,
    SUM("qty") AS total_qty,
    SUM("refunded_amount") AS total_refunded
FROM public.amazon_returns
WHERE "request_date" IS NOT NULL
GROUP BY DATE_TRUNC('month', "request_date")
ORDER BY return_month DESC;
```

### Returns for a specific date range (request_date)
```sql
SELECT
    r."order_id",
    r."sku",
    r."asin",
    r."request_date",
    r."reason",
    r."fulfilment",
    r."qty",
    r."refunded_amount"
FROM public.amazon_returns r
WHERE r."request_date" >= '2026-04-01'
  AND r."request_date" < '2026-05-01'
ORDER BY r."request_date";
```

### Return reasons breakdown
```sql
SELECT "reason",
       COUNT(*) AS count,
       COUNT(*) * 100.0 / SUM(COUNT(*)) OVER() AS pct
FROM public.amazon_returns
GROUP BY "reason"
ORDER BY count DESC;
```

### Returns with customer comments only
```sql
SELECT "order_id", "sku", "asin", "reason", "comments"
FROM public.amazon_returns
WHERE "comments" IS NOT NULL AND TRIM("comments") != '';
```

### Total refunded to buyer (Principal + Tax)
```sql
SELECT
    r."order_id",
    r."sku",
    r."item_id",
    r."asin",
    SUM(e."amount") * -1 AS total_refunded_to_buyer,
    e."currency"
FROM public.amazon_returns r
JOIN public.amz_order_expenses e
    ON r."order_id" = e."order_id"
    AND r."item_id" = e."item_id"
WHERE e."event" = 'RefundEventList'
  AND (
      e."charge_type" LIKE 'Principal%'
      OR e."charge_type" LIKE 'Tax%'
  )
GROUP BY r."order_id", r."sku", r."item_id", r."asin", e."currency";
```

### Full refund breakdown by charge type
```sql
SELECT
    r."order_id",
    r."sku",
    r."asin",
    SUM(CASE WHEN e."charge_type" LIKE 'Principal%'        THEN e."amount" ELSE 0 END) AS principal_refund,
    SUM(CASE WHEN e."charge_type" LIKE 'Tax%'              THEN e."amount" ELSE 0 END) AS tax_refund,
    SUM(CASE WHEN e."charge_type" LIKE 'Commission%'       THEN e."amount" ELSE 0 END) AS commission_back,
    SUM(CASE WHEN e."charge_type" LIKE 'RefundCommission%' THEN e."amount" ELSE 0 END) AS refund_fee,
    SUM(CASE WHEN e."charge_type" LIKE 'DigitalServicesFee%' THEN e."amount" ELSE 0 END) AS dsf_back,
    SUM(e."amount") AS net_total,
    e."currency"
FROM public.amazon_returns r
JOIN public.amz_order_expenses e
    ON r."order_id" = e."order_id"
    AND r."item_id" = e."item_id"
WHERE e."event" = 'RefundEventList'
GROUP BY r."order_id", r."sku", r."asin", e."currency";
```

### Returns with refund detail
```sql
SELECT
    r."order_id",
    r."sku",
    r."asin",
    r."reason",
    r."comments",
    SUM(CASE WHEN e."charge_type" LIKE 'Principal%' OR e."charge_type" LIKE 'Tax%'
        THEN e."amount" ELSE 0 END) * -1 AS refunded_to_buyer,
    e."currency"
FROM public.amazon_returns r
LEFT JOIN public.amz_order_expenses e
    ON r."order_id" = e."order_id"
    AND r."item_id" = e."item_id"
    AND e."event" = 'RefundEventList'
GROUP BY r."order_id", r."sku", r."asin", r."reason", r."comments", e."currency";
```

## Bridge to Other Tables

| Target Table | Schema | Join Key | Notes |
|---|---|---|---|
| `amz_order_expenses` | `public` | `amazon_returns.order_id = amz_order_expenses.order_id` AND `amazon_returns.item_id = amz_order_expenses.item_id` | Filter `event = 'RefundEventList'` for refund rows; use `LIKE` for `charge_type` |
| `order_transaction` | `public` | `amazon_returns.order_id = order_transaction.order_id` | Join for order-level context: marketplace, ss_name, order_total, source_name, order_status |

---

## Bridge to `order_transaction` (Order Context)

Join `public.amazon_returns` → `public.order_transaction` on `order_id` to enrich return records with order metadata (marketplace, store, revenue, fulfilment status).

```sql
-- Returns enriched with order context
SELECT
    r."order_id",
    r."request_date",
    r."sku",
    r."asin",
    r."reason",
    r."fulfilment",
    r."comments",
    ot."order_total",
    ot."order_date",
    ot."ss_name",
    ot."market_place",
    ot."order_status",
    ot."source_name"
FROM public.amazon_returns r
LEFT JOIN public.order_transaction ot
    ON r."order_id" = ot."order_id";
```

### Returns with order value (revenue at risk)
```sql
SELECT
    r."order_id",
    r."request_date",
    r."sku",
    r."asin",
    r."reason",
    ot."order_total",
    ot."market_place",
    ot."ss_name"
FROM public.amazon_returns r
LEFT JOIN public.order_transaction ot
    ON r."order_id" = ot."order_id"
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
LEFT JOIN public.amazon_returns r
    ON ot."order_id" = r."order_id"
WHERE ot."source_name" = 'AMAZON'
  AND ot."order_status" = 'Completed'
  AND ot."order_date"::date >= CURRENT_DATE - INTERVAL '90 days'
GROUP BY ot."sku"
ORDER BY return_rate_pct DESC NULLS LAST;
```

---

## Reference Lists

**Marketplaces (`market_place`):** Belgium, France, Germany, Ireland, Italy, Netherlands, Spain, UK

**Sub-Sources (`sub_source_name`):** amazon Dcvoltage, amazon Ledsone
