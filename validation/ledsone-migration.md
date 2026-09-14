# LEDSone Data-Source Migration — Validation Evidence

**Date:** 2026-09-14
**Change:** Data source cut over from `order_management_copy` (149.28.134.54) to
**LEDSone** `ledsone` @ 169.58.91.229:5432. Schema-mapping only — no business logic,
thresholds, filters, grain, output columns, or dashboard structure changed.
**Commit:** `fb4cb19`
**No credential appears in this file.**

## 1. New connection (verified via LEDSone MCP)
`current_database()=ledsone`, `inet_server_addr()=169.58.91.229`, `port=5432`,
PostgreSQL 18.4. Discovery ran as read-only `dbhub_readonly`; the refresh uses
`tech_user` over TLS (`sslmode=require`) from `.env`.

## 2. Source mapping (verified against the live schema)

| OLD (`public.*`) | NEW LEDSone source | Status |
|---|---|---|
| `amazon_returns` | `customer_service.amazon_returns` | PASS |
| `ebay_returns` (incl. `res_his_order`) | `customer_service.ebay_returns` | PASS |
| `listing_data` where `which_channel=1` (ref_id=asin) | `listings.amazon_listings` (asin) | PASS |
| `listing_data` where `which_channel=2` (ref_id=item_id) | `listings.ebay_listings` (item_id) | PASS |
| `order_transaction` (order_id + item_id → sku) | `order_management.orders` (order_id→id) ⨝ `order_management.order_item_info` (id + item_id → item_sku) | PASS (2-hop) |
| `amazon_returns.market_place` (absent; `marketplace_id` NULL) | `orders.market_place` → `order_management.market_place.name` (Option A) | PASS (gaps = UNSPECIFIED) |
| eBay `mapped_sku` | absent on `ebay_listings` → resolve on `sku` | PASS (documented) |

## 3. Semantic compatibility
- Amazon reason taxonomy identical, incl. `CR-` prefix and `AMZ-PG-BAD-DESC` (195 in-window).
- eBay `NOT_AS_DESCRIBED` present (56 in-window); `res_his_order=0`, `seller_currency`,
  `market_place_code` (EBAY_GB/DE/…) all present.
- eBay bridge resolves **410/413 (99.3%)**; the 3 unresolved fall into the existing
  UNATTRIBUTED handling.
- Amazon marketplace via Option A → UK/Germany/US/… with 346/2151 UNSPECIFIED (never invented).

## 4. Six-query validation (read-only against LEDSone MCP)

| Query | Rows | Floor | Pass | Notes |
|---|---:|---:|---|---|
| amazon_reasons | 67 | 40 | ✓ | 5 currencies |
| amazon_skus | 1561 | 900 | ✓ | 0 NULL marketplace (COALESCE) |
| ebay_reasons | 28 | 20 | ✓ | 4 currencies |
| ebay_skus | 364 | 250 | ✓ | refund total = ebay_reasons (allocation preserves totals); 1 UNATTRIBUTED row |
| nad_amazon_candidates | 179 | — | ✓ | 1 strict-badged, 173 titled |
| nad_ebay_candidates | 53 | — | ✓ | 0 query-titles (as in old DB; carried forward by Python) |

## 5. Old vs New comparison + classification
Old = last `order_management_copy` snapshot embedded in `Dashboard/index.html`.

| Query | Old | New | Δ | Class |
|---|---:|---:|---:|---|
| amazon_reasons | 67 | 67 | 0 | A |
| amazon_skus | 1555 | 1561 | +6 | A |
| ebay_reasons | 28 | 28 | 0 | A |
| ebay_skus | 366 | 364 | −2 | A |
| nad_amazon | 176 | 179 | +3 | A |
| nad_ebay | 54 | 53 | −1 | A |

Classes: **A**=expected data recency, B=schema mapping, C=business-rule, D=bug, E=data-quality.
All aggregate differences are **A**. Structure (columns/grain) identical. No B/C/D observed.
Data-quality notes (E, not blocking): ~32% of Amazon returns have NULL currency →
`UNSPECIFIED` bucket (COALESCE, as before); 16% of Amazon returns have no matching order
header → marketplace `UNSPECIFIED`.

## 6. Business-logic preservation
3-month window, currency separation, Amazon/eBay separation, `CR-` normalization,
`AMZ-PG-BAD-DESC` / `NOT_AS_DESCRIBED` signals, `res_his_order=0`, ≥3 & ≥40% NAD threshold,
even variation split + UNATTRIBUTED, deterministic ORDER BY / DISTINCT ON tie-breakers,
and all output column names/order — unchanged.

## 7. Safety / security
- `refresh_dashboard.py` fail-closed test with empty `PGPASSWORD`: exit 1,
  "Missing PGPASSWORD", dashboard sha **unchanged** (`08cabbd8…`).
- `.env` is gitignored and untracked; `.env.example` + README carry a placeholder only.
- No password in source, SQL, README, this file, logs, or Git. TLS required.

## 8. Pending (operator action)
Live refresh (Phases 5–6) is gated on `tech_user`'s password in `.env` (`PGPASSWORD=`).
Once set: `python3 scripts/refresh_dashboard.py` (run twice for determinism), then verify
embedded `DATA`/`MISMATCH`/`GENERATED_AT` and commit the refreshed dashboard.
