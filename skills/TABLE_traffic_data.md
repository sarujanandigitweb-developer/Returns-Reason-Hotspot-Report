# Table Definition: `public.traffic_data`

## ⚠️ Execution Requirement
After generating any SQL against this table, **always execute it immediately using `postgres:execute_sql`** and return the real query results to the user. Never present a SQL query alone as the final answer.

---

## Purpose
Organic traffic metrics table. Contains impressions, clicks, and conversions for Amazon, eBay, and Shopify product listings. **Does not contain SKU** — use `order_transaction` as a bridge to resolve SKU when needed for multi-table queries.

---

## Schema

| Column | Type | Description |
|---|---|---|
| `id` | integer | Primary key |
| `date` | date | Date traffic was recorded |
| `ref_id` | text | Amazon ASIN, eBay item_id, or Shopify product_id |
| `which_channel` | integer | Platform: `1` = Amazon, `2` = eBay, `3` = Shopify |
| `sub_source` | bigint | Sub-source numeric ID |
| `sub_source_name` | text | Sub-source name |
| `market_place` | text | Country marketplace |
| `impression` | bigint | Times the listing was shown |
| `click` | bigint | Number of clicks |
| `conversion` | numeric | Number of conversions |
| `category_id` | bigint | Category numeric ID |
| `category_name` | text | Category name |
| `user_name` | text | User name |

---

## Key Business Rules

- **Organic traffic only** — this table has no spend/cost data; do not use for PPC queries
- **Always pair `ref_id` with `which_channel`** to correctly identify the product + platform
- **`which_channel` mapping:** `1` = Amazon, `2` = eBay, `3` = Shopify
- **Metrics must be aggregated** over date ranges: `SUM(COALESCE("impression", 0))`
- **Listing identity** = `ref_id` + `market_place` + `sub_source_name`
- **No SKU column** — bridge through `order_transaction` to get SKU
- **User name** → `LOWER("user_name") = LOWER('input')` for case-insensitive match
- **Sub-source filter — always use `=`, never `LIKE`**: When filtering by `sub_source_name`, always use exact match (`=`). Using `LIKE` risks matching REPLACEMENT/RESEND suffix variants (e.g. `electricalsone_ebay`, `ledsone_shopify`) and cross-platform name overlaps (e.g. `ledsone` exists on both Shopify and Faire). Always pair with `which_channel` when the same name could appear on multiple platforms.

---

## Derived Metrics (Always From Aggregated Values)

| KPI | Formula |
|---|---|
| CTR | `SUM(COALESCE("click", 0)) / NULLIF(SUM(COALESCE("impression", 0)), 0)` |
| CVR | `SUM(COALESCE("conversion", 0)) / NULLIF(SUM(COALESCE("click", 0)), 0)` |

Never average pre-calculated rate columns.

---


### Channel-to-Source Mapping (when joining to order_transaction)
| `which_channel` | `order_transaction.source_name` |
|---|---|
| `1` | `'AMAZON'` |
| `2` | `'EBAY'` |
| `3` | `'SHOPIFY'` |

---

## Reference Lists

**Sub-Sources (`sub_source_name`) by Platform:**

- **AMAZON** (`which_channel = 1`): amazon Dcvoltage, amazon Ledsone

- **EBAY** (`which_channel = 2`): bestbringer, coventrylights, dctransformer, electricalsone, homin_gmbh, huettenlampen, led_sone, ledsonede, lighting_sone, neighbourmarket, re6865, so_926407, vintageinterior

- **SHOPIFY** (`which_channel = 3`): 045e77-2, dcvoltage-2, electricalsoneuk, jedsz8-km, ledsone, ledsone-de, ledsone-us, vintage-light-web

**Marketplaces (`market_place`):** Austria, Belgium, Belgium_Dutch, Belgium_French, Canada, France, Germany, Ireland, Italy, Mexico, Netherlands, Poland, Saudi Arabia, Spain, Sweden, Switzerland, UK, United Arab Emirates, US

**Categories:** Artificial Flowers, Batton Aluminium lighting, Belts, Cable tie, Cables, Ceiling light - Cone Shade Set, Ceiling light - Wide Shade Set, Ceiling light Curvy set, Ceiling light Dome shade set, Ceiling light Flat shade, Ceiling roses, Chains, Clip boards, Clocks, Conduit lighting, Connector, Crystal Glass Lamp Shades, Fabric Shades, Gift Bags, Glass Lamp Shades, Hemp set, Holder Rings, Injection module & C, Lamp holders, Laundry Bag, LED Bulbs, Mail Bag, Metal Lamp Shades, Mortar and pestle, Mosque and Tear Drop shades, Panel Lights, Peel and stick, Pendant lights, Pipe Lightings, Plug in Pendants, Reducer Plates, Shade Rings, Spare parts, Spot Lights, Storage Bag, Table Lamps, Tapes, Thread rods, Tile's spare parts, Transformer, Wall lamps, Wall Plugs, Screws, Water proof Junction box, White boards, Wire Cages

**Users:** Abinayaa, anoja, Arudchelvi, Dilani, Illakkiya, Jasmini, Jubista, kobitharsan, mothajini, Nithushana, paulr, Poovitha, prasath, preethi, Renuha, Saranya, Shanthini, shimee, thanucha, thanusha, Tharshana, Tharsiga(nelli), Tharsika(jaffna), Theepana, Thojika, thuwaraga, utharsika