# Table Definitions: `public.order_transaction` & `public.order_shipping_billing_detail`

## ⚠️ Execution Requirement
After generating any SQL against these tables, **always execute it immediately using `postgres:execute_sql`** and return the real query results to the user. Never present a SQL query alone as the final answer.

---

## Table 1: `order_transaction`

### Purpose
Master sales/orders table. Contains every retail transaction across all platforms and marketplaces. This is the **central bridge table** — it holds all product identifiers (ASIN, item_id, product_id, SKU) and connects to every other table in the system.

### Schema

| Column | Type | Description |
|---|---|---|
| `order_item_info` | bigint | Primary key |
| `order_id` | text | Invoice identifier — links to `order_shipping_billing_detail`. Multiple order rows can share the same `order_id` |
| `item_id` | text | eBay item ID |
| `asin` | text | Amazon ASIN |
| `product_id` | text | Shopify product ID |
| `sku` | text | Internal SKU (platform-independent) |
| `item_price` | numeric | Price of the individual item |
| `quantity` | bigint | Quantity ordered |
| `order_status` | text | Cancelled / Completed / Deleted / Hold / Inprogress / New / Pending / Refunded |
| `order_date` | TIMESTAMP | Order placed timestamp |
| `order_total` | double precision | Total monetary value of the order |
| `order_sub_source` | bigint | Sub-source/store numeric ID |
| `ss_name` | text | Sub-source/store name |
| `source` | bigint | Channel / platform numeric ID |
| `source_name` | text | Channel / platform name: AMAZON / EBAY / SHOPIFY / B&Q / WAYFAIR |
| `market_place` | text | Marketplace country where the order was placed (e.g. UK, Germany, US, France, Italy) |
| `fba_sales` | boolean | Whether fulfilled by Amazon (FBA). `TRUE` = FBA, `FALSE` or `NULL` = FBM. **Amazon only** |
| `category_id` | bigint | Category numeric ID |
| `category_name` | text | Category name |
| `user_id` | bigint | User numeric ID |
| `user_name` | text | Portfolio holder (PH) name — the person responsible for managing this listing's portfolio |

---

## Table 2: `order_shipping_billing_detail`

### Purpose
Stores customer, shipping, billing, and carrier details for each invoice. One row per `order_id`. Joined to `order_transaction` via `order_id` when customer or shipment information is needed.

### Schema

| Column | Type | Description |
|---|---|---|
| `order_id` | text | Primary key — matches `order_id` in `order_transaction` |
| `warehouse_name` | text | Warehouse assigned to the order |
| `warehouse_location` | text | Country/region of the warehouse (e.g. `UK`, `Germany`, `US`) |
| `customer_first_name` | text | Customer first name |
| `customer_last_name` | text | Customer last name |
| `customer_email` | text | Customer email address |
| `tracking_number` | text | Shipment tracking number |
| `shipment_status` | text | Current shipment/delivery status |
| `carrier_name` | text | Carrier service name |
| `carrier_charge` | double precision | Postage/carrier cost |
| `carrier_charge_currency` | text | Currency of the carrier charge |
| `shipping_template_price` | double precision | Shipping template price appear in platform |
| `shipping_person_name` | text | Recipient name for shipping |
| `shipping_address` | text | Shipping street address |
| `shipping_region` | text | Shipping region/state |
| `shipping_city` | text | Shipping city |
| `shipping_postal_code` | text | Shipping postal/ZIP code |
| `shipping_country` | text | Shipping country |
| `shipping_phone` | text | Shipping contact phone number |
| `billing_person_name` | text | Billing name |
| `billing_address` | text | Billing street address |
| `billing_region` | text | Billing region/state |
| `billing_city` | text | Billing city |
| `billing_postal_code` | text | Billing postal/ZIP code |
| `billing_country` | text | Billing country |
| `billing_phone` | text | Billing contact phone number |

---

## Table Relationship & Join Rules

### Relationship
```
order_transaction.order_id  →  order_shipping_billing_detail.order_id
```

- **One `order_id` in `order_shipping_billing_detail` maps to one or more rows in `order_transaction`** (an invoice can contain multiple order line items).
- Always join using `ON ot."order_id" = osbd."order_id"`.
- Use `LEFT JOIN` when you want all order rows regardless of whether shipping/billing details exist.
- Use `INNER JOIN` when shipping/billing details are required (e.g. filtering by customer name or tracking number).

### Standard Join Template
```sql
SELECT
    ot.*,
    osbd."customer_first_name",
    osbd."customer_last_name",
    osbd."carrier_name",
    osbd."tracking_number",
    osbd."shipment_status",
    osbd."shipping_city",
    osbd."shipping_country"
FROM "order_transaction" ot
LEFT JOIN "order_shipping_billing_detail" osbd
    ON ot."order_id" = osbd."order_id"
WHERE ot."order_status" = 'Completed';
```

### When to Join
| User asks about… | Action |
|---|---|
| Customer name, email, phone | JOIN `order_shipping_billing_detail` |
| Shipping address / city / country / region | JOIN `order_shipping_billing_detail` |
| Billing address / name | JOIN `order_shipping_billing_detail` |
| Tracking number or shipment status | JOIN `order_shipping_billing_detail` |
| Carrier name or carrier charge | JOIN `order_shipping_billing_detail` |
| Revenue, sales, SKU, platform, category | `order_transaction` only — no join needed |

### Aggregation Caution (Multi-Row Invoice)
Because one `order_id` can have **multiple rows** in `order_transaction`, avoid double-counting when aggregating carrier charges:
```sql
-- WRONG: sums carrier_charge for every order line (inflated)
SUM(osbd."carrier_charge")

-- RIGHT: sum only once per invoice
SUM(DISTINCT osbd."carrier_charge")
-- or use a subquery/CTE to get one row per invoice first
```

---
## 🔴 CRITICAL: Revenue Metric Rule

### The ONE correct way to calculate revenue:
```sql
SUM(COALESCE("order_total", 0))
```

### NEVER do this — it is always wrong:
```sql
-- ❌ WRONG — item_price × quantity is not revenue
SUM("item_price" * "quantity")

-- ❌ WRONG — item_price alone is not revenue
SUM("item_price")
```

**Why:** `order_total` is the true order value. It includes carrier charges and any other fees on top of the item price. Using `item_price × quantity` will undercount revenue and produce incorrect rankings.

**`item_price` and `quantity` are reference columns only** — use `quantity` only for unit counts, never for revenue.

### Revenue query template (always use this pattern):
```sql
SELECT
    "asin",  -- or sku, category_name, user_name etc.
    SUM(COALESCE("order_total", 0))   AS total_revenue,
    SUM(COALESCE("quantity", 0))      AS total_units,
    COUNT(DISTINCT "order_item_info") AS total_orders
FROM public.order_transaction
WHERE "order_status" = 'Completed'
  -- add platform, marketplace, user, date filters here
GROUP BY "asin"
ORDER BY total_revenue DESC;
```

---

## Key Business Rules

- **Sales metric** = `order_total`; always filter `WHERE "order_status" = 'Completed'` for revenue queries
- **Platform filter by identifier:**
  - ASIN → `WHERE "source_name" = 'AMAZON'`
  - item_id → `WHERE "source_name" = 'EBAY'`
  - product_id → `WHERE "source_name" = 'SHOPIFY'`
  - sku → `WHERE "source_name" = 'B&Q'` or `WHERE "source" = 16`
  - sku → `WHERE "source_name" = 'WAYFAIR'`
- **SKU filtering** → always use `LIKE '%pattern%'` (never exact `=`)
- **User name** → `LOWER("user_name") = LOWER('input')` for case-insensitive match
- **Sub-source / store name filter — always use `=`, never `LIKE`**: When filtering by `ss_name`, always use exact match (`=`). Using `LIKE` risks matching REPLACEMENT/RESEND suffix variants (e.g. `electricalsone_ebay`, `ledsone_shopify`, `led_sone_ebay_replacement`) and cross-platform overlaps (e.g. `ledsone` exists on both SHOPIFY and FAIRE, `ledsonede` on EBAY and WAYFAIR). Always pair with `source_name` filter when the same name could appear on multiple platforms.
  ```sql
  -- ❌ WRONG — matches 'ledsone', 'ledsone_shopify', 'ledsone_shopify_replacement', 'ledsone mano' etc.
  WHERE ss_name LIKE '%ledsone%'

  -- ✅ CORRECT — exact store only
  WHERE ss_name = 'ledsone' AND source_name = 'SHOPIFY'
  ```
- **Listing identity** = `sku` + `market_place` + `ss_name`
- **Date column is TIMESTAMP** → cast before arithmetic: `"order_date"::date`
- **All SUM calls** → `SUM(COALESCE("order_total", 0))`

### Amazon FBA vs FBM
Amazon sales are split into two fulfilment types:

| Type | Full Name | Description | Filter |
|---|---|---|---|
| **FBM** | Fulfilled by Merchant | Standard Amazon orders shipped by the seller directly | `"source_name" = 'AMAZON' AND ("fba_sales" = FALSE OR "fba_sales" IS NULL)` |
| **FBA** | Fulfilled by Amazon | Orders stored in and shipped from Amazon's warehouses | `"source_name" = 'AMAZON' AND "fba_sales" = TRUE` |

- `fba_sales` is **only meaningful for Amazon** (`source_name = 'AMAZON'`). Never apply this filter on eBay, Shopify, or other platforms.
- When asked about "Amazon sales" without a specific fulfilment type, include **both FBM and FBA** (i.e. no filter on `fba_sales`).
- When comparing FBA vs FBM, always add `"source_name" = 'AMAZON'` alongside the `fba_sales` filter.

---


---

## B&Q Platform Rules

### ⚠️ Confirmed via database verification — `source = 16`

B&Q is a distinct sales channel with its own source ID. Always use the following when querying B&Q data:

| Field | Value |
|---|---|
| `source` | **16** |
| `source_name` | **B&Q** |
| `ss_name` | `bq_ledsone` (only sub-source) |
| **Product identifier** | **`sku`** — B&Q has NO ASIN, item_id, or product_id |

### B&Q Filter Rules

```sql
-- Filter by source_name (preferred — readable)
WHERE "source_name" = 'B&Q'

-- OR filter by source numeric ID (equivalent)
WHERE "source" = 16
```

### B&Q Product-Level Query Pattern

```sql
-- Top SKUs by revenue for B&Q
SELECT
    "sku",
    SUM(COALESCE("order_total", 0))   AS total_sales,
    SUM(COALESCE("quantity", 0))      AS total_units,
    COUNT(DISTINCT "order_item_info") AS total_orders
FROM public.order_transaction
WHERE "source_name" = 'B&Q'
  AND "order_status" = 'Completed'
  -- add marketplace, user, date filters as needed
GROUP BY "sku"
ORDER BY total_sales DESC;
```

### B&Q Limitations

| Capability | Available? | Notes |
|---|---|---|
| Sales / revenue | ✅ Yes | Via `order_transaction` on `sku` |
| SKU-level breakdown | ✅ Yes | `GROUP BY "sku"` |
| Shipping details | ✅ Yes | JOIN `order_shipping_billing_detail` on `order_id` |
| PPC / ad spend | ❌ No | No B&Q PPC data in `ppc` or `ppc_performance` |
| Organic traffic | ❌ No | No B&Q data in `traffic_data` |
| Channel expenses / fees | ❌ No | Not covered by `amz_order_expenses` or `ebay_order_expenses` |
| ASIN / item_id / product_id | ❌ No | B&Q orders do not carry these identifiers |

## Role as Bridge Table (`order_transaction`)

This table is the **central hub** for resolving product identifiers across the system:

| Need | How |
|---|---|
| Get SKU from ASIN | `SELECT DISTINCT "asin", "sku" WHERE "source_name" = 'AMAZON'` |
| Get SKU from item_id | `SELECT DISTINCT "item_id", "sku" WHERE "source_name" = 'EBAY'` |
| Link traffic → stock | `traffic_data.ref_id` → this table → `sku` → `inv_final_stock` |
| Match channel codes | `which_channel = 1` → `source_name = 'AMAZON'`; `which_channel = 2` → `source_name = 'EBAY'` |
| Amazon FBA orders | `"source_name" = 'AMAZON' AND "fba_sales" = TRUE` |
| Amazon FBM orders | `"source_name" = 'AMAZON' AND ("fba_sales" = FALSE OR "fba_sales" IS NULL)` |
| Customer / shipping details | JOIN `order_shipping_billing_detail` ON `order_id` |

---

## Reference Lists

**Platforms (`source_name`):** AMAZON, EBAY, SHOPIFY, B&Q, WAYFAIR

**Sub-Sources (`ss_name`) by Platform:**

- **AMAZON:** amazon Cottage Lighting, amazon Dcvoltage, amazon Homin gmbh, amazon Ledsone, amazon Ledsonede, amazon RelicElectrical, amazon SRM Amazon, amazon Vintage light, DCV UK, Neighbour Market, vendor

- **EBAY:** bestbringer, cottagelighting, coventrylights, dctransformer, electbout0, electricalsone, electro_shine, homin_gmbh, huettenlampen, koneswaransrikanesh, led_sone, ledpedia, ledsonede, lighting_sone, longtek020, nanthinvasude-0, neighbourmarket, re6865, so_926407, uk-lightsway, ur26574, vintageinterior

- **SHOPIFY:** 045e77-2, dcvoltage-2, electricalsoneuk, jedsz8-km, ledsone, ledsone-de, ledsone-us, LEDSone UK Ltd, relicelectrical, relicelectrical.myshopify.com, vintage-light-web, Vintagelite

- **B&Q:** bq_ledsone

- **WAYFAIR:** dcvoltage, LEDSone UK Castlegate, LEDSONEDE, LEDSONEUK, NeighbourmarketInc

**Marketplaces (`market_place`):** Austria, Belgium, Belgium_Dutch, Belgium_French, Canada, France, Germany, Ireland, Italy, Mexico, Netherlands, Poland, Saudi Arabia, Spain, Sweden, Switzerland, UK, United Arab Emirates, US

**Order Statuses:** Cancelled, Completed, Deleted, Hold, Inprogress, New, Pending, Refunded

**Categories:** Artificial Flowers, Batton Aluminium lighting, Belts, Cable tie, Cables, Ceiling light - Cone Shade Set, Ceiling light - Wide Shade Set, Ceiling light Curvy set, Ceiling light Dome shade set, Ceiling light Flat shade, Ceiling roses, Chains, Clip boards, Clocks, Conduit lighting, Connector, Crystal Glass Lamp Shades, Fabric Shades, Gift Bags, Glass Lamp Shades, Hemp set, Holder Rings, Injection module & C, Lamp holders, Laundry Bag, LED Bulbs, Mail Bag, Metal Lamp Shades, Mortar and pestle, Mosque and Tear Drop shades, Panel Lights, Peel and stick, Pendant lights, Pipe Lightings, Plug in Pendants, Reducer Plates, Shade Rings, Spare parts, Spot Lights, Storage Bag, Table Lamps, Tapes, Thread rods, Tile's spare parts, Transformer, Wall lamps, Wall Plugs, Screws, Water proof Junction box, White boards, Wire Cages

**Users:** Abinayaa, anoja, Arudchelvi, Dilani, Illakkiya, Jasmini, Jubista, kobitharsan, mothajini, Nithushana, paulr, Poovitha, prasath, preethi, Renuha, Saranya, Shanthini, shimee, thanucha, thanusha, Tharshana, Tharsiga(nelli), Tharsika(jaffna), Theepana, Thojika, thuwaraga, utharsika