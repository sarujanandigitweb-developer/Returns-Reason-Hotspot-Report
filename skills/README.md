# skills/ — LEGACY schema reference (old database)

> **Read this first.** The `TABLE_*.md` and `SKILL_*.md` files in this folder are **company
> reference documentation for the old `order_management_copy` database** (schema `public.*`).
> They were provided as background material and describe tables/columns as they existed there.

**This project no longer uses that database.** As of **2026-09-14** the Returns Reason Hotspot
dashboard reads the **LEDSone** database (`ledsone` @ 169.58.91.229), where the schema is
different (`customer_service.*`, `listings.*`, `order_management.*`, and a 2-hop order bridge).

For the tables, columns, keys and traps that the dashboard **actually** uses today, see:

- [../data-maps/TABLE_MAP.md](../data-maps/TABLE_MAP.md) — the current LEDSone data map
- [../validation/ledsone-migration.md](../validation/ledsone-migration.md) — old → new source mapping
- [../sql/returns_hotspot_queries.sql](../sql/returns_hotspot_queries.sql) — the six queries as run

Treat everything else in this folder as **historical reference only**. In particular, table names
like `public.amazon_returns`, `public.ebay_returns`, `public.listing_data` and
`public.order_transaction` do **not** exist in LEDSone — see TABLE_MAP.md for their equivalents.
