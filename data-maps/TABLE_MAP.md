# Data Map — Returns Reason Hotspot Report

The three tables this report reads, the keys that join them, and the traps in each.
Everything here was verified against the live database, not taken from documentation.

---

## `public.amazon_returns` — one row per return

| Column | Used for | Notes |
|---|---|---|
| `sku`, `asin` | SKU grain | **Not the same key as `order_transaction.sku`** — see the key-mismatch warning below |
| `reason` | Reason grain | Carries a `CR-` prefix **inconsistently** — must be stripped, or one reason splits across two rows |
| `refunded_amount` | Refund value | **NULL on 940 of 2,199 rows (42.7%)** in the 3-month window |
| `currency` | Currency scope | **Multi-currency: GBP / USD / EUR / CAD + 677 rows with NULL** |
| `qty` | Units | 2,789 units across 2,199 returns — multi-unit returns exist |
| `market_place` | Marketplace | UK, Germany, France, US, Canada, Italy, Netherlands, Ireland, Spain, Belgium |
| `request_date` | 3-month window, Last Return | `date` type |
| `label_cost` | *(available, not yet used)* | **£5,157.26 of return postage in the window**, 83% populated |
| `fulfilment` | *(available)* | FBA / FBM — verified 1:1 with the SKU grain |
| `comments` | *(unusable)* | Only 5.6% populated |

## `public.ebay_returns` — one row per return

| Column | Used for | Notes |
|---|---|---|
| `res_his_order` | **Mandatory filter** | `= 0` only. Without it the window returns **5,064 rows instead of 489** — a 10× inflation from resolution-history rows |
| `reason` | Reason grain | No prefix issue |
| `seller_refund_amount` | Refund value | 100% populated, zero NULLs |
| `seller_currency` | Currency scope | GBP / EUR / USD / CAD |
| `order_id` + `item_id` | **SKU lookup** | eBay has **no `sku` column** |
| `return_qty` | Units | 794 units across 489 returns |
| `market_place_code` | Marketplace | `EBAY_GB`, `EBAY_DE`, `EBAY_US`, `EBAY_IE`, `EBAY_AT`, `EBAY_CA` — verified 1:1 with SKU grain |
| `status` | *(available)* | 8 states. **15 ESCALATED (£508), 63 still open** |
| `comments` | *(available)* | 57.9% populated — far better than Amazon's |
| `carrier` | *(unusable)* | 0% populated |

## `public.order_transaction` — one row per **order line item**

Line-item grain, **not** order grain. This is the single most important fact about this table
and the cause of DR-001.

| Column | Used for |
|---|---|
| `order_id` + `item_id` | Join key to `ebay_returns` |
| `sku` | The SKU an eBay return maps to |
| `source_name` | `AMAZON`, `EBAY`, `SHOPIFY`, `WAYFAIR`, … (15 values) |

---

## Join keys

```
ebay_returns.order_id + ebay_returns.item_id::text
        ->  order_transaction.order_id + order_transaction.item_id
```

**Never join on `order_id` alone.** `order_transaction` is line-item level, so a returned
order with several items in the basket fans out — 42 orders do, worst case one order across
10 line items — duplicating the refund once per SKU and overstating eBay SKU refunds by
**+12.7%**. Full analysis: [DR-001](../duplicate-risk-reports/DR-001-ebay-sku-join-fanout.md).

Coverage of the correct `order_id + item_id` join, measured:

| Outcome | Returns | |
|---|---|---|
| Resolves to exactly one SKU | 440 | 90.0% |
| Resolves to several SKUs (variation listing) | 46 | 9.4% — refund and units split evenly |
| No matching order line | 3 | 0.6% — shown as an explicit *Unattributed* row |

---

## Two key facts that constrain what this report can ever answer

**1. `amazon_returns.sku` is not `order_transaction.sku`.**
Only **699 of 1,503** Amazon return SKUs (46%) exist in `order_transaction` *at all* — not a
timing gap; they were checked all-time. Any metric requiring Amazon sales volume (return
*rate*, revenue-at-risk, sell-through) **cannot be computed** and must not be attempted until
someone reconciles the two SKU formats.

**2. Amazon refund coverage is 42.7% incomplete.**
940 of 2,199 returns carry `refunded_amount = NULL`. In GBP that's 313 of 1,205 (26%). Only
9 of those are recoverable from `amz_order_expenses`. So Amazon refund totals describe the
**1,259 returns that have a value**, not all 2,199 — and a SKU whose returns all lack a refund
value ranks at £0.00 despite being returned.

---

## Reason codes seen in the live data

The task brief's reason lists were **wrong for both platforms**. These are the actual values.

**Amazon** (after stripping `CR-`): `NOT_COMPATIBLE`, `UNWANTED_ITEM`, `AMZ-PG-BAD-DESC`,
`QUALITY_UNACCEPTABLE`, `NO_REASON_GIVEN`, `DEFECTIVE`, `ORDERED_WRONG_ITEM`, `DAMAGED_BY_FC`,
`MISSING_PARTS`, `SWITCHEROO`, `DAMAGED_BY_CARRIER`, `MISSED_ESTIMATED_DELIVERY`,
`FOUND_BETTER_PRICE`, `UNAUTHORIZED_PURCHASE`, `EXTRA_ITEM`, `POOR_FIT`, `AMZ-PG-APP-TOO-LARGE`,
`AMZ-PG-APP-TOO-SMALL`, `NOT_AS_DESCRIBED`, `UNDELIVERABLE_UNKNOWN`, `UNDELIVERABLE_REFUSED`

> **Open question:** `AMZ-PG-BAD-DESC` is the 3rd-largest GBP refund reason (£2,340.74) and the
> largest USD one. It is very likely the "not as described" signal, but merging it into
> `NOT_AS_DESCRIBED` is a judgement about Amazon's taxonomy — **DWC's call, not ours.**

**eBay:** `WRONG_SIZE`, `ORDERED_WRONG_ITEM`, `NOT_AS_DESCRIBED`, `ARRIVED_DAMAGED`,
`ORDERED_ACCIDENTALLY`, `NO_LONGER_NEED_ITEM`, `DEFECTIVE_ITEM`, `ORDERED_DIFFERENT_ITEM`,
`MISSING_PARTS`, `FOUND_BETTER_PRICE`, `BUYER_NO_SHOW`, `NO_REASON`,
`WITHDRAW_FROM_PURCHASE_CONTRACT`
