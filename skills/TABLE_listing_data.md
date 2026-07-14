---
name: table-listing-data
description: "Table definition for public.listing_data — the central product listing registry. Every product listed on Amazon, eBay, Shopify, or B&Q has rows here linking the channel listing identifier (ASIN / item_id / variant_id) to inventory SKUs per marketplace and store."
---

# Table Definition: `public.listing_data`

## ⚠️ Execution Requirement
After generating any SQL against this table, **always execute it immediately using `postgres:execute_sql`** and return the real query results to the user. Never present a SQL query alone as the final answer.

---

## What Is a "Listing"?

A **listing** is any product that has been put up for sale on a sales channel — Amazon, eBay, Shopify, or B&Q. Each listing is identified by a channel-native reference id (`ref_id`):

| Channel | `ref_id` is | Example |
|---|---|---|
| Amazon | ASIN | `B084JRSK7F` |
| eBay | eBay item_id (numeric string) | `123799969824` |
| Shopify | Shopify variant_id (numeric string) | `44267484741882` |
| B&Q | B&Q listing ref | (numeric string) |

A single listing (`ref_id`) can have **multiple rows** — one per SKU variant sold under that listing (especially on eBay). This is the most important data shape to understand before writing any query.

---

## Purpose

Central registry of every product listed across all sales channels. Links the channel listing identifier (`ref_id`) to the inventory SKU per channel, marketplace, and store account. Used as:
- **SKU bridge** — resolves listing ref_id → inventory SKU for stock queries
- **Listing lookup** — find title, price, product type for any listing
- **Channel coverage** — determine which ASINs / item_ids are active per store and marketplace

---

## Schema

| Column | Type | Description |
|---|---|---|
| `id` | bigint | Primary key |
| `ref_id` | text | Channel listing identifier — ASIN (Amazon), item_id (eBay), variant_id (Shopify/B&Q) |
| `sku` | text | Listing SKU as synced from the channel |
| `mapped_sku` | text | Internal inventory SKU when it differs from `sku`; NULL when `sku` matches inventory directly |
| `which_channel` | integer | Channel: `1` = Amazon, `2` = eBay, `3` = Shopify, `16` = B&Q |
| `which_channel_name` | text | Channel name text (`amazon`, `ebay`, `shopify`, `B&Q`) |
| `market_place` | text | Marketplace — `UK`, `Germany`, `France`, `US`, `Canada`, `Italy`, `Spain`, etc. |
| `sub_source` | bigint | Store account numeric id |
| `sub_source_name` | text | Store account name (human-readable) — use this for filtering by store |
| `fulfilment` | text | Fulfilment method — `merchant`, `fba`, `other`, or NULL (see Fulfilment Reference below) |
| `quantity` | bigint | ⭐ **Listing available quantity** — the stock figure the channel itself shows as available for this listing (FBM/FBA, eBay, Shopify, etc.). Use this column whenever the user asks about listing-side / FBM / FBA available quantity. This is **completely different from location-wise stock data** (`location_wise_inv_stock` / `inv_final_stock`) — do not confuse the two. |
| `list_qty` | double precision | Listed quantity (mostly NULL; populated for a minority of Amazon/eBay rows) |
| `wrong_sku` | bigint | Data quality flag: `0` = valid row, `1` = bad/duplicate — **always filter `wrong_sku = 0`** |
| `is_parent` | bigint | `1` = parent/container listing (Amazon parent ASIN, eBay parent item) — no sellable SKU |
| `is_child` | bigint | `1` = child/variant listing — has its own sellable SKU |
| `is_offer` | bigint | `1` = offer row (present on Amazon listings) |
| `price` | double precision | Listing price |
| `currency` | text | Currency code (`GBP`, `EUR`, `USD`, etc.) |
| `title` | text | Listing title (populated for Amazon/Shopify; sparse for eBay) |
| `product_description` | text | Product description (rarely populated) |
| `product_type` | text | Product type category (e.g. `LIGHT_BULB_SOCKET`, `Lamps`) |
| `shopify_handle` | text | Shopify URL handle (Shopify listings only) |
| `shipping_id` | text | Shipping profile id |
| `profile_name` | varchar | Profile name |
| `price_per_order` | numeric | Price per order |
| `main_image_url` | text | URL of the listing's main product image |
| `status` | text | Listing status |

---

## How Each Channel Uses This Table

### Amazon (`which_channel = 1`)
- `ref_id` = ASIN
- `is_offer = 1` on all Amazon rows
- Has both parent ASINs (`is_parent = 1`) and child/variant ASINs (`is_child = 1`)
- `title` is well populated
- `mapped_sku` present for ~40–50% of UK rows — use it when not NULL
- SKU can be a bundle/kit string (e.g. `CRSF100CH+WSNW170CH+SCRN70CH`) for multi-component products
- Spans many marketplaces: UK (largest), Germany, France, Italy, Spain, Netherlands, US, Canada, etc.

### eBay (`which_channel = 2`)
- `ref_id` = eBay item_id (numeric string)
- **One item_id → many rows** (one per variant/SKU). e.g. item `123799969824` has 3+ SKU rows — each is a different colour/size variant listed under the same item
- `is_parent` / `is_child` pattern mirrors Amazon — parent item vs child variants
- `mapped_sku` almost never populated (near zero across all marketplaces)
- `title` sparsely populated (many NULLs, especially non-UK)
- UK is the largest market (81k+ rows, ~8k distinct item_ids)
- Also covers Germany, France, Italy, Spain, Austria, US, Canada, Ireland

### Shopify (`which_channel = 3`)
- `ref_id` = Shopify **variant_id** (not product_id)
- **One row per variant** — `ref_id` is always unique (distinct_ref_ids = row_count)
- `is_child = 1` for all rows — no parent rows
- `mapped_sku` never populated — `sku` is always the inventory SKU directly
- `title` is the **variant option label** (e.g. `Default Title`, `Yes`, `No`) — not the product title
- `product_type` populated (e.g. `Lamps`)
- Markets: UK (largest), Germany, France, US, Canada

### B&Q (`which_channel = 16`)
- `ref_id` = B&Q listing ref
- UK only
- No `mapped_sku`, `is_parent = 0`, `is_child = 0` — flat listing structure
- `title` populated

---

## Store Reference (`sub_source_name`)

| Channel | `sub_source` | `sub_source_name` |
|---|---|---|
| Amazon | 6 | `amazon Dcvoltage` |
| Amazon | 8 | `amazon Ledsone` |
| Amazon | 9 | `amazon SRM Amazon` |
| Amazon | 164 | `amazon RelicElectrical` |
| Amazon | 165 | `amazon Cottage Lighting` |
| Amazon | 229 | `amazon Homin gmbh` |
| Amazon | 239 | `Neighbour Market` |
| eBay | 1 | `led_sone` |
| eBay | 2 | `re6865` |
| eBay | 3 | `bestbringer` |
| eBay | 4 | `so_926407` |
| eBay | 21 | `dctransformer` |
| eBay | 22 | `electricalsone` |
| eBay | 23 | `lighting_sone` |
| eBay | 24 | `coventrylights` |
| eBay | 27 | `ledsonede` |
| eBay | 28 | `huettenlampen` |
| eBay | 41 | `vintageinterior` |
| eBay | 222 | `homin_gmbh` |
| eBay | 238 | `neighbourmarket` |
| Shopify | 104 | `ledsone` |
| Shopify | 108 | `ledsone-de` |
| Shopify | 109 | `vintage-light-web` |
| Shopify | 112 | `electricalsoneuk` |
| Shopify | 113 | `relicelectrical` |
| Shopify | 198 | `045e77-2` |
| Shopify | 233 | `jedsz8-km` |
| Shopify | 245 | `ledsone-us` |
| Shopify | 248 | `dcvoltage-2` |
| B&Q | 242 | `bq_ledsone` |

---

## Fulfilment Reference (`fulfilment`)

Distinct values found in the table:

| `fulfilment` | Meaning |
|---|---|
| `merchant` | Merchant-fulfilled (seller ships) |
| `fba` | Fulfilled By Amazon |
| `other` | Other fulfilment method |
| NULL | Not set / unknown (most rows) |

> ⚠️ Data quality: a small number of rows contain the misspelling `ohter` — treat as `other`. Normalise in queries, e.g. `CASE WHEN fulfilment = 'ohter' THEN 'other' ELSE fulfilment END`.

---

## Key Business Rules

- **`quantity` = listing available quantity (FBM/FBA)** — when the user asks about FBM, FBA, or "listing" available quantity/stock, use `listing_data.quantity` (the channel-side figure), **not** `location_wise_inv_stock` / `inv_final_stock`. These are two distinct concepts: `listing_data.quantity` is what the channel shows as available on the listing; location-wise stock is internal warehouse/location inventory. This distinction comes up often in business questions — do not mix them up.
- **Always filter `wrong_sku = 0`** — this is mandatory on every query; bad/duplicate rows exist and will corrupt results
- **SKU resolution** — always use `COALESCE(NULLIF(mapped_sku, ''), sku)` to get the correct inventory SKU; `mapped_sku` takes priority when not NULL and not empty
- **Full identity key for joins** — always include all four: `ref_id + which_channel + sub_source + market_place + wrong_sku = 0`; use `sub_source_name` for human-readable store filtering; joining on fewer keys causes cross-channel or cross-store collisions
- **One eBay item_id → many SKU rows** — aggregate stock per item before joining, or you will multiply metrics
- **Shopify bridge key is different** — Shopify PPC joins on `ppc_performance.sku = listing_data.ref_id` with `which_channel = 3`, not on `ref_id = ref_id`
- **Parent rows have no sellable SKU** — exclude `is_parent = 1` rows when doing SKU → stock lookups
- **Step-by-step approach mandatory for stock joins** — when `listing_data` is in the join path (PPC → stock, traffic → stock), do NOT use a single CTE; run step-by-step, show resolved SKU rows to user for verification before querying inventory. See `SKILL_ppc_stock_lookup.md` and `SKILL_multi_table.md`
- **Never use `order_transaction` as a bridge for PPC/traffic → stock** — `listing_data` is the only correct SKU resolver for this path


---

## SKU Resolution Logic

```
IF mapped_sku IS NOT NULL AND mapped_sku != ''
    → use mapped_sku   (internal inventory SKU differs from channel listing SKU)
ELSE
    → use sku          (channel listing SKU is the same as inventory SKU)

SQL: COALESCE(NULLIF(mapped_sku, ''), sku) AS resolved_sku
```

After resolving, check for variant suffixes (`_AML`, `_AMD`, `_IDE`, `_CA`) and strip to base SKU if needed to match inventory.

---

## Common Query Patterns

### Look up all SKU variants for an eBay item_id
```sql
SELECT ref_id, sku, mapped_sku,
       COALESCE(NULLIF(mapped_sku, ''), sku) AS resolved_sku,
       market_place, sub_source_name
FROM public.listing_data
WHERE ref_id        = :item_id
  AND which_channel = 2
  AND wrong_sku     = 0;
```

### Look up SKU for an Amazon ASIN
```sql
SELECT ref_id, sku, mapped_sku,
       COALESCE(NULLIF(mapped_sku, ''), sku) AS resolved_sku,
       market_place, sub_source_name, title
FROM public.listing_data
WHERE ref_id        = :asin
  AND which_channel = 1
  AND market_place  = :marketplace
  AND wrong_sku     = 0;
```

### All active listings for a store and channel
```sql
SELECT ref_id, sku, mapped_sku, title, market_place, which_channel_name, sub_source_name
FROM public.listing_data
WHERE sub_source_name = :store_name
  AND which_channel   = :channel_id
  AND wrong_sku       = 0
  AND is_child        = 1
ORDER BY market_place, ref_id;
```

### Find listing by title keyword
```sql
SELECT ref_id, sku, mapped_sku, title, which_channel_name, market_place, sub_source
FROM public.listing_data
WHERE title ILIKE '%:keyword%'
  AND wrong_sku = 0
ORDER BY which_channel, market_place, ref_id;
```

### Count listings per channel and marketplace
```sql
SELECT which_channel_name, market_place,
       COUNT(*) AS total_rows,
       COUNT(DISTINCT ref_id) AS distinct_listings
FROM public.listing_data
WHERE wrong_sku = 0
  AND is_child  = 1
GROUP BY which_channel_name, market_place
ORDER BY which_channel_name, market_place;
```

---

## Bridge to Other Tables

| Target Table | Join Key | Notes |
|---|---|---|
| `ppc_performance` (Amazon/eBay) | `listing_data.ref_id = ppc_performance.ref_id` + channel/marketplace/sub_source | PPC SKU bridge |
| `ppc_performance` (Shopify) | `listing_data.ref_id = ppc_performance.sku` + `which_channel = 3` | Shopify joins on `sku`, not `ref_id` |
| `traffic_data` | `listing_data.ref_id = traffic_data.ref_id` + channel/marketplace/sub_source | Traffic SKU bridge |
| `location_wise_inv_stock` | `resolved_sku = location_wise_inv_stock.sku` | Stock lookup after SKU resolution |
| `inv_final_stock` | `resolved_sku = inv_final_stock.sku` | Aggregated stock alternative |
| `message.amz_msg` | `listing_data.ref_id = amz_msg.asin` | Listing context for Amazon messages |
| `message.ebay_msg` | `listing_data.ref_id = ebay_msg.item_id` | Listing context for eBay messages |
| `public.bullet_points` | `listing_data.id = bullet_points.product_id` | Amazon listing bullet points (up to 5 per listing) |

---

## Related Table: `public.bullet_points`

Stores the bullet point content for product listings (primarily Amazon). Each bullet is a separate row linked back to `listing_data` via `product_id`.

### Schema

| Column | Type | Description |
|---|---|---|
| `id` | bigint | Primary key |
| `product_id` | bigint | FK → `listing_data.id` |
| `points` | text | The bullet point text content |
| `view_order` | text | Display order of the bullet (1–5, where 1 = first bullet shown) |
| `which_channel` | text | Channel name (e.g. `amazon`) |

### Key Rules
- **Join key** — `bullet_points.product_id = listing_data.id` (not `ref_id`)
- **Up to 5 bullets per listing** — `view_order` values `1` through `5`
- **Always filter `wrong_sku = 0`** on the `listing_data` side before joining
- Primarily populated for Amazon listings; other channels may have no rows

### Common Query Pattern

```sql
-- Get all bullet points for a specific Amazon ASIN
SELECT
    ld.ref_id        AS asin,
    ld.title,
    ld.market_place,
    ld.sub_source_name,
    bp.view_order,
    bp.points
FROM public.listing_data ld
JOIN public.bullet_points bp ON bp.product_id = ld.id
WHERE ld.ref_id        = :asin
  AND ld.which_channel = 1
  AND ld.wrong_sku     = 0
ORDER BY bp.view_order::int;
```
