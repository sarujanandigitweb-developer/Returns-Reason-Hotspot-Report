# Data Map — Returns Reason Hotspot Report (LEDSone)

The LEDSone tables this report reads, the keys that join them, and the traps in each.
Verified against the live LEDSone database during the 2026-09-14 migration
(see [validation/ledsone-migration.md](../validation/ledsone-migration.md)).

> The former DB (`order_management_copy`) kept everything in `public.*` with a single
> `order_transaction` bridge table. LEDSone splits this across schemas and needs a **2-hop**
> order bridge. The business logic is unchanged; only the sources moved.

---

## `customer_service.amazon_returns` — one row per return

| Column | Used for | Notes |
|---|---|---|
| `sku`, `asin` | SKU grain | not the same key space as order lines — return-*rate* is still not computable (see CAPABILITY) |
| `reason` | Reason grain / NAD signal | carries a `CR-` prefix **inconsistently** — stripped in SQL; `AMZ-PG-BAD-DESC` is the "not as described" signal |
| `refunded_amount` | Refund value | partially NULL; NULLs contribute £0 |
| `currency` | Currency scope | GBP / EUR / USD / CAD, **~32% NULL → grouped as `UNSPECIFIED`** |
| `qty` | Units | multi-unit returns exist |
| `order_id` | marketplace derivation | dashed marketplace order id; joins to `orders.order_id` |
| `request_date` | 3-month window, Last Return | `date` type |
| `marketplace_id` | **do NOT use** | present but **100% NULL** — marketplace comes from `orders` instead |

There is **no `market_place` column** on returns. Marketplace name is derived (see below).

## `customer_service.ebay_returns` — one row per return

| Column | Used for | Notes |
|---|---|---|
| `res_his_order` | **Mandatory filter** | `= 0` only. Without it the window inflates ~10× from resolution-history rows |
| `reason` | Reason grain | `NOT_AS_DESCRIBED` is the eBay "not as described" signal |
| `seller_refund_amount` | Refund value | `double precision` |
| `seller_currency` | Currency scope | GBP / EUR / USD / CAD |
| `order_id` | SKU bridge (hop 1) | **dashed** marketplace id, e.g. `02-14629-85281` (varchar) |
| `item_id` | SKU bridge (hop 2) | eBay listing item number (**bigint** — cast `::text` to match order lines) |
| `return_qty` | Units | |
| `market_place_code` | Marketplace | `EBAY_GB`, `EBAY_DE`, `EBAY_US`, `EBAY_IE`, `EBAY_CA`, … (used directly) |
| `request_date` | 3-month window, Last Return | `timestamp` (cast `::date`) |

eBay has **no `sku` column** — SKU is resolved through the order bridge below.

## `listings.amazon_listings` / `listings.ebay_listings` — listing context (title/price)

The old single `listing_data` (with `which_channel`) is now **two** tables.

| Need | Amazon (`amazon_listings`) | eBay (`ebay_listings`) |
|---|---|---|
| join key (ref_id) | `asin` | `item_id` |
| SKU | `sku`, `mapped_sku` | `sku` (**no `mapped_sku`** → resolve on `sku`) |
| trust filter | `wrong_sku = 0` | `wrong_sku = 0` |
| dedup preference | `is_child` DESC, then price/title/ccy | same |
| marketplace name | `site` (UK, Germany, US, …) | — |
| also | `title`, `price`, `currency`, `product_type` | `title`, `price`, `currency`, `product_type` |

eBay listing titles are sparse here (as in the old DB); the refresh **carries titles forward**
per-SKU/id from the previous snapshot, so the query returning a blank title is expected.

## `order_management.orders` — order header (one row per order)

| Column | Used for |
|---|---|
| `order_id` (varchar) | the **dashed marketplace id** — matches `*_returns.order_id` |
| `id` (bigint) | internal order id — matches `order_item_info.order_id` |
| `market_place` (varchar, numeric code) | Amazon marketplace derivation → join to `order_management.market_place.id` |

## `order_management.order_item_info` — order **line** (one row per line item)

| Column | Used for |
|---|---|
| `order_id` (bigint) | = `orders.id` (internal, **not** the marketplace id) |
| `item_id` (varchar) | = `ebay_returns.item_id::text` |
| `item_sku` | the SKU an eBay return maps to (also `real_sku`, `item_title` available) |

## `order_management.market_place` — code → name lookup (36 rows)

`id` (int) → `name` (UK, Germany, US, …), `abbreviation`, `amz_marketplace_id`.

---

## Join keys

**eBay SKU bridge (2-hop — replaces the old single `order_transaction`):**
```
ebay_returns.order_id (dashed)
   -> orders.order_id  ->  orders.id
   -> order_item_info.order_id  (+  order_item_info.item_id = ebay_returns.item_id::text)
   -> order_item_info.item_sku
```
Never join on `order_id` alone (fan-out — see [DR-001](../duplicate-risk-reports/DR-001-ebay-sku-join-fanout.md)).
A variation item_id maps to several SKUs → refund/units split evenly; a return with no order line
surfaces as an explicit *Unattributed* row. **Coverage measured on LEDSone: 410 of 413 (99.3%)
resolve to a SKU; 3 unattributed.**

**Amazon marketplace derivation (Option A — returns carry no marketplace):**
```
amazon_returns.order_id -> orders.order_id -> orders.market_place (code)
   -> order_management.market_place.id -> .name
```
Resolved deterministically (one order row per order_id, no fan-out). **~84% of returns match an
order header; the ~16% that don't show `UNSPECIFIED` — never invented.**

---

## Reason codes seen in the live LEDSone data

**Amazon** (after stripping `CR-`): `NOT_COMPATIBLE`, `UNWANTED_ITEM`, **`AMZ-PG-BAD-DESC`**,
`QUALITY_UNACCEPTABLE`, `DEFECTIVE`, `NO_REASON_GIVEN`, `ORDERED_WRONG_ITEM`, `DAMAGED_BY_FC`,
`SWITCHEROO`, `DAMAGED_BY_CARRIER`, … (the `CR-` prefix and the `AMZ-PG-BAD-DESC` code match the old DB).

**eBay:** `WRONG_SIZE`, `ORDERED_WRONG_ITEM`, **`NOT_AS_DESCRIBED`**, `DEFECTIVE_ITEM`,
`ORDERED_ACCIDENTALLY`, `NO_LONGER_NEED_ITEM`, `ARRIVED_DAMAGED`, `ORDERED_DIFFERENT_ITEM`,
`MISSING_PARTS`, `FOUND_BETTER_PRICE`, `NO_REASON`, `WITHDRAW_FROM_PURCHASE_CONTRACT`, `BUYER_NO_SHOW`.

> The Amazon "not as described" question is **settled**: this project uses `AMZ-PG-BAD-DESC` as the
> NAD signal (disclosed on the dashboard). It is not merged into the near-empty literal `NOT_AS_DESCRIBED`.
