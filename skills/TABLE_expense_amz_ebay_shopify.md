# Table Definitions: `public.amz_order_expenses` & `public.ebay_order_expenses` & `public.shopify_transactions`

## ⚠️ Execution Requirement
After generating any SQL against these tables, **always execute it immediately using `postgres:execute_sql`** and return the real query results to the user. Never present a SQL query alone as the final answer.

---

## Overview

Two separate tables store channel-level expense/settlement data per platform:

| Table | Platform | Grain |
|---|---|---|
| `public.amz_order_expenses` | Amazon | One row per charge type per SKU per invoice |
| `public.ebay_order_expenses` | eBay | One row per transaction type per invoice |
| `public.shopify_transactions` | Shopify | One row per transaction event per order |

`amz_order_expenses` , `ebay_order_expenses` and `shopify_transactions` join to `order_transaction` via `order_id`.

---

# Table 1: `public.amz_order_expenses`

### Purpose
Amazon settlement expense table. Contains itemised charge/credit rows for every Amazon order — one row per charge type per SKU. Use for SKU-level cost analysis, profitability, refund detection, and FBA vs FBM cost comparison.

### Schema

| Column | Type | Description |
|---|---|---|
| `id` | bigint | Primary key |
| `date` | date | Settlement date |
| `order_id` | text | Links to `order_transaction.order_id` |
| `seller_sku` | text | Amazon listing SKU — **NOTE: has marketplace suffix** (e.g. `-UK`, `-JK`, `-IN`). Strip suffix to match `order_transaction.sku` |
| `event` | text | Event type — see Event Reference below |
| `item_id` | bigint | Amazon item identifier |
| `charge_type` | text | Type of charge — see Charge Type Reference below |
| `amount` | double precision | Charge amount. **Positive = money in to seller. Negative = money out from seller** |
| `currency` | text | Currency of the amount |
| `sub_source` | bigint | Sub-source / account identifier |
| `market_place_name` | text | Marketplace name (e.g. `UK`, `Germany`, `US`) |

---

## Join & Lookup

### Primary join key: `order_id`

`amz_order_expenses.order_id` matches directly to `order_transaction.order_id`. No SKU resolution or bridge table is needed — join on `order_id` alone to get all expense rows for any set of orders.

```sql
SELECT
    ot."asin",
    ae."event",
    ae."charge_type",
    SUM(ae."amount") AS total_amount
FROM public.order_transaction ot
JOIN public.amz_order_expenses ae ON ot."order_id" = ae."order_id"
WHERE ot."asin" = '<asin>'
  AND ot."order_status" = 'Completed'
  AND ot."order_date"::date >= <start>
  AND ot."order_date"::date < <end>
GROUP BY ot."asin", ae."event", ae."charge_type"
ORDER BY ae."event", total_amount;
```

### Net profit pattern (revenue − channel expenses − refunds)

1. **Gross revenue** — `SUM(COALESCE(ot."order_total", 0))` from `order_transaction` where `order_status = 'Completed'`
2. **Channel expenses** — from `amz_order_expenses` where `event = 'ShipmentEventList'`, exclude `charge_type` IN (`Principal`, `ShippingCharge`, `Tax`, `ShippingTax`) — those are pass-through revenue/tax, not costs
3. **Refund impact** — from `amz_order_expenses` where `event = 'RefundEventList'`, sum all `amount` values (negatives are deductions, positives are credits returned to seller)
4. **Net profit** = gross revenue + channel expenses (negative) + refund net (negative)

> Always join via `order_id`. Never use `seller_sku` LIKE patterns to identify orders — that approach is fragile and overly broad.
> **Sub-source filter — always use `=`, never `LIKE`**: When filtering by `sub_source`, always use exact match (`=`). Using `LIKE` risks matching REPLACEMENT/RESEND suffix variants and cross-platform name overlaps.

---

## Amazon Order Expenses — Reference

## Event reference

| `event` | What it means |
|---|---|
| `ShipmentEventList` | Charges/credits from order shipments — main settlement event |
| `RefundEventList` | Refund transactions — customer refunded |
| `AdjustmentEventList` | Manual Amazon adjustments, reimbursements |
| `GuaranteeClaimEventList` | A-to-Z guarantee claims |
| `ChargebackEventList` | Credit card chargebacks |

---

## Charge type reference

### ShipmentEventList charge types

| `charge_type` | Amount sign | Who pays | Include in channel expense? |
|---|---|---|---|
| `Principal` | + positive | Customer pays → seller receives | ❌ Revenue — not a cost |
| `ShippingCharge` | + positive | Customer pays → seller receives | ❌ Revenue — passes through |
| `Tax` / `ShippingTax` | + positive | Customer pays → passed through | ❌ Tax — passes through |
| `Commission` | − negative | Seller pays → Amazon referral fee | ✅ Yes |
| `DigitalServicesFee` | − negative | Seller pays → VAT/DST | ✅ Yes |
| `DigitalServicesFeeFBA` | − negative | Seller pays → FBA-specific DST | ✅ Yes |
| `FBAPerUnitFulfillmentFee` | − negative | Seller pays → FBA pick/pack/ship | ✅ Yes — FBA only |
| `ShippingHB` | − negative | Seller pays → shipping handling fee | ✅ Yes — FBM only |
| `PromotionMetaDataDefinitionValue` | − negative | Seller pays → seller-funded discount | ✅ Yes |

---

### RefundEventList charge types

| `charge_type` | Amount sign | What it means |
|---|---|---|
| `Principal` | − negative | Refund paid back to customer |
| `Commission` | + positive | Amazon returns referral fee to seller |
| `DigitalServicesFee` | + positive | Amazon reverses DST to seller |
| `RefundCommission` | − negative | Amazon's refund admin penalty — seller pays |
| `ReturnPostageBilling_Postage` | − negative | Return shipping cost — seller pays |
| `ShippingCharge` | − negative | Shipping refunded to customer |
| `Tax` / `ShippingTax` | − negative | Tax refunded to customer |

---

---

# Table 2: `public.ebay_order_expenses`

### Purpose
eBay settlement expense table. Contains one row per transaction type per fee type per order. Use for eBay order-level cost analysis, profitability, refund detection, and ad fee attribution.

### Schema

| Column | Type | Description |
|---|---|---|
| `id` | bigint | Primary key |
| `transaction_date` | date | Date of the transaction |
| `transaction_id` | text | eBay transaction identifier |
| `order_id` | text | Links to `order_transaction.order_id` |
| `item_id` | bigint | eBay item/listing ID |
| `payout_id` | double precision | eBay payout batch identifier |
| `case_id` | double precision | Dispute/case ID — populated for DISPUTE transactions |
| `return_id` | text | Return request ID — populated for REFUND transactions |
| `order_sub_source` | bigint | Sub-source identifier |
| `transaction_type` | text | Type of transaction — see Transaction Type Reference below |
| `transaction_amount` | double precision | Gross order value — repeated across all fee rows for the same order; **never SUM for revenue** |
| `transaction_currency` | text | Currency of the transaction amount |
| `fee` | double precision | Fee amount for this specific fee_type row — always `SUM(COALESCE("fee", 0))` when aggregating |
| `fee_currency` | text | Currency of the fee |
| `tax` | double precision | Tax amount on the transaction |
| `tax_currency` | text | Currency of the tax |
| `order_marketplace_fee` | double precision | Total marketplace fee for the order (summary field) |
| `order_status` | text | Order status at time of record |
| `order_marketplace_currency` | text | Currency of the `order_marketplace_fee` field |
| `booking_entry` | text | `CREDIT` = money in to seller, `DEBIT` = money out from seller |
| `transaction_status` | text | Settlement status: `FUNDS_AVAILABLE_FOR_PAYOUT`, `PAYOUT`, `FUNDS_PROCESSING` |
| `fee_type` | text | Specific fee category — see Fee Type Reference below |

---

## Join & Lookup

### Primary join key: `order_id`

`ebay_order_expenses.order_id` matches directly to `order_transaction.order_id`.

```sql
SELECT
    ot."item_id",
    ee."transaction_type",
    ee."fee_type",
    ee."booking_entry",
    SUM(COALESCE(ee."fee", 0)) AS total_fee
FROM public.order_transaction ot
JOIN public.ebay_order_expenses ee ON ot."order_id" = ee."order_id"
WHERE ot."source_name" = 'EBAY'
  AND ot."order_date"::date >= <start>
  AND ot."order_date"::date < <end>
GROUP BY ot."item_id", ee."transaction_type", ee."fee_type", ee."booking_entry"
ORDER BY ee."transaction_type", total_fee;
```

### Key aggregation rules

- `transaction_amount` is the gross order value repeated across every fee row — **never SUM it** for revenue; use `order_transaction.order_total` instead
- `fee` is the per-row fee amount — always `SUM(COALESCE("fee", 0))` when aggregating
- Always group by `booking_entry` to correctly separate costs from reversals
- Net fee position: `SUM(CASE WHEN "booking_entry" = 'DEBIT' THEN "fee" ELSE -"fee" END)`

### Net profit pattern (eBay)

1. **Gross revenue** — `SUM(COALESCE(ot."order_total", 0))` from `order_transaction` where `order_status = 'Completed'`
2. **Channel fees** — from `ebay_order_expenses` where `transaction_type = 'SALE'`, sum `fee` by `fee_type`
3. **Ad fees** — from `ebay_order_expenses` where `transaction_type = 'NON_SALE_CHARGE'` and `fee_type IN ('PREMIUM_AD_FEES', 'AD_FEE')`, net DEBIT minus CREDIT
4. **Refund impact** — from `ebay_order_expenses` where `transaction_type = 'REFUND'`, sum `fee` — eBay claws back previously credited fees on refunded orders
5. **Net profit** = gross revenue − SALE fees − net ad fees + refund fee reversals

> ⚠️ On refunded orders, eBay reverses both the SALE fee rows and the AD_FEE. Always net DEBIT vs CREDIT per `fee_type` to get the true cost.

---

## eBay Order Expenses — Reference

## Transaction Type reference

| `transaction_type` | What it means |
|---|---|
| `SALE` | Standard eBay order settlement — fee rows for a completed sale |
| `NON_SALE_CHARGE` | Fees not tied to a single sale event — ad fees, insertion fees, etc. |
| `REFUND` | Customer refund — fee reversals and refund-specific charges |
| `CREDIT` | eBay-issued credits back to the seller |
| `DISPUTE` | Chargeback or buyer dispute transactions |
| `SHIPPING_LABEL` | eBay shipping label purchase costs |
| `ADJUSTMENT` | Manual eBay adjustments |

---

## Fee Type reference

### SALE fee types

| `fee_type` | `booking_entry` | What it means | Include in channel expense? |
|---|---|---|---|
| `FINAL_VALUE_FEE` | CREDIT | eBay commission — % of sale value | ✅ Yes |
| `FINAL_VALUE_FEE_FIXED_PER_ORDER` | CREDIT | Fixed per-order charge on top of % commission | ✅ Yes |
| `REGULATORY_OPERATING_FEE` | CREDIT | eBay regulatory compliance fee | ✅ Yes |
| `INTERNATIONAL_FEE` | CREDIT | Surcharge for cross-border sales | ✅ Yes |

---

### NON_SALE_CHARGE fee types

| `fee_type` | `booking_entry` | What it means | Include in channel expense? |
|---|---|---|---|
| `PREMIUM_AD_FEES` | DEBIT | eBay Advanced (CPC / ON_SITE) promoted listing fees — charged per click | ✅ Yes |
| `AD_FEE` | DEBIT | eBay Standard (CPS / COST_PER_SALE) promoted listing fees — charged on attributed sale | ✅ Yes |
| `INSERTION_FEE` | DEBIT | Listing insertion fee | ✅ Yes |
| `OTHER_FEES` | DEBIT | Miscellaneous eBay fees | ✅ Yes |
| `SUBTITLE_FEE` | DEBIT | Optional subtitle listing upgrade fee | ✅ Yes |
| `INTERNATIONAL_LISTING_FEE` | DEBIT | Fee for listing in international marketplaces | ✅ Yes |
| `FINAL_VALUE_FEE_FIXED_PER_ORDER` | DEBIT | Fixed order fee billed outside of standard sale settlement | ✅ Yes |
| `REGULATORY_OPERATING_FEE` | DEBIT | Regulatory fee billed outside of sale settlement | ✅ Yes |
| `FINAL_VALUE_FEE` | DEBIT | Commission billed outside of sale settlement | ✅ Yes |
| `GALLERY_PLUS_FEE` | DEBIT | Listing gallery upgrade fee | ✅ Yes |

---

### REFUND fee types

| `fee_type` | `booking_entry` | What it means |
|---|---|---|
| `FINAL_VALUE_FEE` | DEBIT | eBay claws back the commission credited on the original sale |
| `FINAL_VALUE_FEE_FIXED_PER_ORDER` | DEBIT | eBay claws back the fixed order fee credited on the original sale |
| `REGULATORY_OPERATING_FEE` | DEBIT | eBay claws back the regulatory fee credited on the original sale |
| `INTERNATIONAL_FEE` | DEBIT | eBay claws back the international fee credited on the original sale |

> `AD_FEE` under `NON_SALE_CHARGE` is reversed with a `CREDIT` booking entry on refunded orders — not listed under REFUND rows.

---

### Other transaction types

| `transaction_type` | `fee_type` | Notes |
|---|---|---|
| `CREDIT` | `-` | No fee breakdown — plain credit in `transaction_amount` |
| `DISPUTE` | `-` | No fee breakdown — dispute amount in `transaction_amount` |
| `ADJUSTMENT` | `-` | No fee breakdown — adjustment amount in `transaction_amount` |
| `SHIPPING_LABEL` | `-` | No fee breakdown — label cost in `transaction_amount` |
---

---

# Table 3: `public.shopify_transactions`

### Purpose
Shopify Payments settlement table. Contains one row per transaction event per order — charges, refunds, payouts, disputes, and adjustments. Use for Shopify order-level channel expense calculation, profitability analysis, and refund/dispute tracking.

### Schema

| Column | Type | Description |
|---|---|---|
| `id` | bigint | Primary key |
| `type` | text | Transaction type — see Transaction Type Reference below |
| `payout_status` | text | Status of the payout: `paid`, `in_transit`, `pending`, `failed` |
| `currency` | text | Currency code (e.g. `GBP`, `USD`) |
| `amount` | double precision | Gross transaction amount. Positive = money in, Negative = money out |
| `fee` | double precision | Shopify payment processing fee for this transaction |
| `net` | double precision | Net amount after fee (`amount − fee`) — pre-calculated |
| `sub_source` | text | Sub-source / store identifier |
| `source_type` | text | Source of the transaction: `charge`, `payout`, `Payments::Refund`, `Payments::Dispute` |
| `order_id` | text | **Primary join key** — links to `order_transaction.order_id` directly |
| `shopify_transaction_id` | double precision | Shopify's own transaction identifier |
| `processed_at` | timestamp | When the transaction was processed |

---

## Join & Lookup

### Primary join key: `order_id` → `order_transaction.order_id`

```sql
SELECT
    st."order_id",
    st."type",
    st."source_type",
    st."amount",
    st."fee",
    st."net"
FROM public.shopify_transactions st
WHERE st."order_id" = <order_id>
  AND st."test" = 0
  AND st."payout_status" IN ('paid', 'in_transit')
ORDER BY st."type";
```


### Key aggregation rules

- Always filter `WHERE "test" = 0` — never include test transactions in any calculation
- `amount` is the gross value; `fee` is the Shopify processing fee; `net = amount − fee` (pre-calculated)
- For channel expense, aggregate `fee` (not `amount`) on charge rows, and `ABS(amount)` on refund/dispute/adjustment rows
- Never SUM `amount` across all types — it mixes credits and debits incorrectly

### Net channel expense pattern (Shopify)

Channel expense per order is the **sum of fees/costs across all applicable transaction types**:

| Component | Filter | Metric |
|---|---|---|
| Charge fee | `type = 'charge'` AND `payout_status IN ('paid','in_transit')` AND `source_type = 'charge'` | `SUM("fee")` |
| Refund cost | `type = 'refund'` AND `payout_status IN ('paid','in_transit')` AND `source_type = 'Payments::Refund'` | `SUM(ABS("amount"))` |
| Dispute cost | `type = 'dispute'` AND `payout_status IN ('paid','in_transit','pending')` AND `source_type = 'Payments::Dispute'` | `SUM(ABS("amount"))` |
| Adjustment cost | `type = 'adjustment'` AND `amount < 0` AND `payout_status IN ('paid','pending')` | `SUM(ABS("amount"))` |
| Refund failure credit | `type = 'refund_failure'` AND `payout_status = 'paid'` AND `source_type = 'Payments::Refund'` | `− SUM(ABS("amount"))` *(subtract — this is a recovery)* |

**Net channel expense = Charge fee + Refund cost + Adjustment cost − Refund failure recovery**

### Net profit pattern (Shopify)

1. **Gross revenue** — `SUM(COALESCE(ot."order_total", 0))` from `order_transaction` where `order_status = 'Completed'` and `source_name = 'SHOPIFY'`
2. **Channel expense** — from `shopify_transactions` using the formula above, joined via `order_id`
3. **Net profit** = gross revenue − channel expense

---

## Transaction Type Reference

| `type` | `payout_status` filter | `source_type` | Metric | Include in expense? |
|---|---|---|---|---|
| `charge` | `paid`, `in_transit` | `charge` | `SUM("fee")` | ✅ Yes — processing fee |
| `refund` | `paid`, `in_transit` | `Payments::Refund` | `SUM(ABS("amount"))` | ✅ Yes — refund cost |
| `dispute` | `paid`, `in_transit`, `pending` | `Payments::Dispute` | — | ❌ No — excluded from expense calculation |
| `adjustment` | `paid`, `pending` | any | `SUM(ABS("amount"))` where `amount < 0` | ✅ Yes — negative adjustments only |
| `refund_failure` | `paid` | `Payments::Refund` | `− SUM(ABS("amount"))` | ✅ Subtract — failed refund is a recovery |
| `payout` | — | `payout` | — | ❌ No — internal fund transfer, not a cost |
| `payout_failure` | — | `payout` | — | ❌ No — payout failure event, not a cost |

---

## SQL Pattern — Shopify Channel Expense per Order

```sql
SELECT
    "order_id",
    SUM(
        CASE
            WHEN "type" = 'charge'
                 AND "payout_status" IN ('paid', 'in_transit')
                 AND "source_type" = 'charge'
            THEN COALESCE("fee", 0)

            WHEN "type" = 'refund'
                 AND "payout_status" IN ('paid', 'in_transit')
                 AND "source_type" = 'Payments::Refund'
            THEN ABS(COALESCE("amount", 0))

            WHEN "type" = 'adjustment'
                 AND "amount" < 0
                 AND "payout_status" IN ('paid', 'pending')
            THEN ABS(COALESCE("amount", 0))

            WHEN "type" = 'refund_failure'
                 AND "payout_status" = 'paid'
                 AND "source_type" = 'Payments::Refund'
            THEN -ABS(COALESCE("amount", 0))

            ELSE 0
        END
    ) AS channel_expense
FROM public.shopify_transactions
WHERE "test" = 0
  AND "order_id" IS NOT NULL
GROUP BY "order_id";
```
