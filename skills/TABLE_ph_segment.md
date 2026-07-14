# Table Definition: `analytics.ph_segment`

## ⚠️ Execution Requirement
After generating any SQL against this table, **always execute it immediately using `postgres:execute_sql`** and return the real query results to the user. Never present a SQL query alone as the final answer.

---

## Purpose
Pre-computed bi-weekly performance segmentation table. Each row classifies a product listing (ASIN or eBay item_id) into a performance segment based on impressions, clicks, and conversions relative to other products in the same category over a 14-day period. Use for segment distribution analysis, listing health checks, period-over-period segment tracking, and champion/dead-horse identification.

---

## Schema

| Column | Type | Description |
|---|---|---|
| `period_start` | date | Start date of the 14-day bi-weekly period |
| `period_end` | date | End date of the 14-day bi-weekly period (inclusive) |
| `ref_id` | text | Amazon ASIN (channel=1) or eBay item_id (channel=2) |
| `which_channel` | bigint | Platform: `1` = Amazon, `2` = eBay |
| `market_place` | text | Marketplace name (e.g. `UK`, `US`, `Germany`, `France`) |
| `sub_source` | bigint | Sub-source numeric ID |
| `sub_source_name` | text | Sub-source / store name |
| `impression_count` | bigint | Total impressions in the period |
| `click_count` | bigint | Total clicks in the period |
| `conversion_count` | bigint | Total conversions in the period |
| `total_sales` | double precision | Total sales revenue in the period |
| `impression_count_segment` | text | `H` or `L` — impression rank vs category median |
| `click_count_segment` | text | `H` or `L` — click rank vs category median |
| `conversion_count_segment` | text | `H` or `L` — conversion rank vs category median |
| `performance_segment` | text | Segment code — use this for all segment filtering and grouping |
| `performance_segment_name` | text | Human-readable segment label — use this for display |
| `category_name` | text | Product category name |
| `user_name` | text | Assigned user/analyst name |

---

## Key Business Rules

- **Period grain**: One row per `ref_id` + `market_place` + `sub_source_name` + bi-weekly period (14 days)
- **Period columns**: Filter by `period_start` and/or `period_end` (both are DATE)
- **Latest period**: `WHERE "period_end" = (SELECT MAX("period_end") FROM analytics.ph_segment)`
- **Channel coverage**: `which_channel = 1` → Amazon (ASIN); `which_channel = 2` → eBay (item_id)
- **Listing identity** = `ref_id` + `market_place` + `sub_source_name`
- **User name filter** → `LOWER("user_name") = LOWER('input')` (case-insensitive)
- **Marketplace filter** → use `market_place` column
- **Sub-source filter — always use `=`, never `LIKE`**: When filtering by `sub_source_name`, always use exact match (`=`). Using `LIKE` risks matching REPLACEMENT/RESEND suffix variants (e.g. `electricalsone_ebay`, `led_sone_ebay_replacement`) and cross-platform name overlaps. Always pair with `which_channel` filter when the same name could appear on multiple platforms.
- **Segmentation scope**: H/L labels are computed **within category** — a product is H or L relative to other products in the same `category_name`, not globally. Do not compare segment labels across different categories.
- **Segment columns to use**: Always filter and group on `performance_segment` or `performance_segment_name`. The individual dimension columns (`impression_count_segment`, `click_count_segment`, `conversion_count_segment`) are available for drill-down only.

---

## Channel Reference

| `which_channel` | Platform | `ref_id` type |
|---|---|---|
| `1` | Amazon | ASIN |
| `2` | eBay | item_id |

---

## Sub-Source Reference

**Amazon (`which_channel = 1`):**
- `amazon Dcvoltage` — markets: UK, Germany, France
- `amazon Ledsone` — markets: UK, US, Germany, France

**eBay (`which_channel = 2`):**
- `electricalsone` — markets: UK, US, Germany, France
- `huettenlampen` — markets: Germany
- `led_sone` — markets: UK, US, Germany
- `ledsonede` — markets: Germany
- `neighbourmarket` — markets: US
- `so_926407` — markets: UK

---

## Marketplace Reference

| `market_place` | Available on Amazon | Available on eBay |
|---|---|---|
| `UK` | ✓ | ✓ |
| `US` | ✓ | ✓ |
| `Germany` | ✓ | ✓ |
| `France` | ✓ | ✓ |

---

## Segment Reference

### Performance Segments

| `performance_segment` | `performance_segment_name` | Meaning |
|---|---|---|
| `HHH` | **Champions** | High impressions, high clicks, high conversions — top performers |
| `HHL` | **Leaky Buckets** | High visibility and clicks but low conversions — traffic not converting |
| `HLH` | **Wallflowers** | High impressions but low click engagement |
| `LHH` | **Hidden Gems** | Low reach but strong click-through and conversion — underexposed performers |
| `LLH` | **Niche Winners** | Converts well without needing high traffic or clicks |
| `LLL` | **Dead Horses** | Low across all three dimensions — underperforming listings |

### Segment Dimension Breakdown (for drill-down only)

| Column | `H` means | `L` means |
|---|---|---|
| `impression_count_segment` | Above-median impressions in category | Below-median impressions in category |
| `click_count_segment` | Above-median clicks in category | Below-median clicks in category |
| `conversion_count_segment` | Above-median conversions in category | Below-median conversions in category |

---

## Common Query Patterns

### Latest period segment distribution (by channel)
```sql
SELECT
    "which_channel",
    "performance_segment_name",
    COUNT(*) AS listing_count
FROM analytics.ph_segment
WHERE "period_end" = (SELECT MAX("period_end") FROM analytics.ph_segment)
GROUP BY "which_channel", "performance_segment_name"
ORDER BY "which_channel", listing_count DESC;
```

### Champions in a specific marketplace (latest period)
```sql
SELECT
    "ref_id",
    "market_place",
    "sub_source_name",
    "category_name",
    "impression_count",
    "click_count",
    "conversion_count",
    "total_sales"
FROM analytics.ph_segment
WHERE "period_end" = (SELECT MAX("period_end") FROM analytics.ph_segment)
  AND "performance_segment" = 'HHH'
  AND "market_place" = 'UK'
ORDER BY "total_sales" DESC;
```

### Period-over-period segment history for a listing
```sql
SELECT
    "period_start",
    "period_end",
    "ref_id",
    "market_place",
    "performance_segment",
    "performance_segment_name",
    "impression_count",
    "click_count",
    "conversion_count"
FROM analytics.ph_segment
WHERE "ref_id" = '<asin_or_item_id>'
  AND "which_channel" = 1
ORDER BY "period_start";
```

### Dead Horses by category (latest period)
```sql
SELECT
    "category_name",
    COUNT(*) AS dead_horse_count
FROM analytics.ph_segment
WHERE "period_end" = (SELECT MAX("period_end") FROM analytics.ph_segment)
  AND "performance_segment" = 'LLL'
GROUP BY "category_name"
ORDER BY dead_horse_count DESC;
```

### Segment distribution for a user across all periods
```sql
SELECT
    "period_start",
    "period_end",
    "performance_segment_name",
    COUNT(*) AS listing_count
FROM analytics.ph_segment
WHERE LOWER("user_name") = LOWER('Saranya')
GROUP BY "period_start", "period_end", "performance_segment_name"
ORDER BY "period_start", listing_count DESC;
```

---

## Bridge to Other Tables

| Target Table | Join Key | Notes |
|---|---|---|
| `order_transaction` | `ph_segment.ref_id = order_transaction.asin` (channel=1) or `order_transaction.item_id` (channel=2) | Filter `order_transaction` by `source_name = 'AMAZON'` or `'EBAY'` accordingly |
| `traffic_data` | `ph_segment.ref_id = traffic_data.ref_id` + `ph_segment.which_channel = traffic_data.which_channel` + `market_place` | Organic traffic enrichment |
| `inv_final_stock` | Two-step: `ph_segment.ref_id` → `order_transaction` (get SKU via DISTINCT) → `inv_final_stock.sku` | No direct join; bridge through `order_transaction` |
| `ppc` | `ph_segment.ref_id = ppc.ref_id` + marketplace + `which_channel = 1` (Amazon only) | PPC enrichment — Amazon only |

---

## Data Coverage

- **Refresh cadence**: Bi-weekly (new period every 14 days: 1st–14th and 15th–28th of each month)
- **Platforms**: Amazon + eBay

## Reference Lists

**Categories:** Artificial Flowers, Batton Aluminium lighting, Belts, Cable tie, Cables, Ceiling light - Cone Shade Set, Ceiling light - Wide Shade Set, Ceiling light Curvy set, Ceiling light Dome shade set, Ceiling light Flat shade, Ceiling roses, Chains, Clip boards, Clocks, Conduit lighting, Connector, Crystal Glass Lamp Shades, Fabric Shades, Gift Bags, Glass Lamp Shades, Hemp set, Holder Rings, Injection module & C, Lamp holders, Laundry Bag, LED Bulbs, Mail Bag, Metal Lamp Shades, Mortar and pestle, Mosque and Tear Drop shades, Panel Lights, Peel and stick, Pendant lights, Pipe Lightings, Plug in Pendants, Reducer Plates, Shade Rings, Spare parts, Spot Lights, Storage Bag, Table Lamps, Tapes, Thread rods, Tile's spare parts, Transformer, Wall lamps, Wall Plugs, Screws, Water proof Junction box, White boards, Wire Cages

**Users:** Abinayaa, anoja, Arudchelvi, Dilani, Illakkiya, Jasmini, Jubista, kobitharsan, mothajini, Nithushana, paulr, Poovitha, prasath, preethi, Renuha, Saranya, Shanthini, shimee, thanucha, thanusha, Tharshana, Tharsiga(nelli), Tharsika(jaffna), Theepana, Thojika, thuwaraga, utharsika