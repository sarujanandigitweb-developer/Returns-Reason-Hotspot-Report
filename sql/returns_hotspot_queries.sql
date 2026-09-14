-- ============================================================================
-- Returns Reason Hotspot Report — the six queries that build the dashboard.
-- Read and executed by scripts/refresh_dashboard.py. Query blocks are delimited
-- by "-- name:" markers; the script splits on those, so keep them intact.
--
-- DATA SOURCE: LEDSone PostgreSQL (ledsone @ 169.58.91.229). Migrated 2026-09-14
-- from the former order_management_copy DB. ONLY the source tables/joins changed;
-- every business rule below is preserved byte-for-byte (see the discovery/mapping
-- report and validation/ledsone-migration.md).
--
-- SOURCE MAPPING (old public.* -> new schema-qualified):
--   public.amazon_returns   -> customer_service.amazon_returns
--   public.ebay_returns     -> customer_service.ebay_returns
--   public.listing_data(ch1)-> listings.amazon_listings   (ref_id = asin)
--   public.listing_data(ch2)-> listings.ebay_listings     (ref_id = item_id)
--   public.order_transaction-> order_management.orders (order_id -> id)
--                              JOIN order_management.order_item_info (id + item_id -> item_sku)
--   Amazon market_place      -> orders.market_place (code) -> order_management.market_place.name
--                              (Option A; unmatched orders remain 'UNSPECIFIED', never invented)
--
-- Window: request_date >= CURRENT_DATE - INTERVAL '3 months'
--
-- BUSINESS RULES (unchanged — see duplicate-risk-reports/DR-001 and
-- validation/reconciliation.md):
--   * res_his_order = 0 on ebay_returns is mandatory (excludes history rows).
--   * eBay has no sku column. SKU is resolved from the order line on
--     order_id + item_id (NOT order_id alone, which fans out across basket line
--     items). In LEDSone this is a 2-hop bridge: ebay_returns.order_id ->
--     orders.order_id -> orders.id -> order_item_info.order_id (+ item_id) ->
--     item_sku. This preserves the old order_transaction attribution exactly.
--   * Where one eBay item_id maps to several SKUs (a variation listing), the
--     refund AND the units are split evenly across them. Returns with no
--     matching order line surface as an explicit UNATTRIBUTED row.
--   * Every query groups by currency. Both platforms are multi-currency;
--     totals are NEVER summed across currencies, and Amazon is NEVER combined
--     with eBay.
--   * Amazon reason codes carry a CR- prefix inconsistently. It is stripped
--     mechanically so the same reason does not split across two rows.
--
-- ORDERING: each query ends with a deterministic tie-break (sku / reason).
-- Ties on refund+count are common, and without a tie-break PostgreSQL returns
-- them in an arbitrary order — so a scheduled refresh would reshuffle rows, and
-- their rank numbers, every morning without any data having changed.
-- ============================================================================


-- name: amazon_reasons
-- columns: ccy, reason, return_count, pct_of_count, total_refunded, units, last_return
WITH base AS (
    SELECT COALESCE("currency", 'UNSPECIFIED')       AS ccy,
           regexp_replace("reason", '^CR-', '')      AS reason,
           COALESCE("refunded_amount", 0)            AS amt,
           COALESCE("qty", 0)                        AS q,
           "request_date"
    FROM customer_service.amazon_returns
    WHERE "request_date" >= CURRENT_DATE - INTERVAL '3 months'
)
SELECT ccy,
       reason,
       COUNT(*)                                                                      AS return_count,
       ROUND((COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (PARTITION BY ccy))::numeric, 1) AS pct_of_count,
       ROUND(SUM(amt)::numeric, 2)                                                   AS total_refunded,
       SUM(q)::int                                                                   AS units,
       MAX("request_date")::text                                                     AS last_return
FROM base
GROUP BY ccy, reason
ORDER BY ccy, total_refunded DESC, reason;


-- name: amazon_skus
-- columns: ccy, sku, asin, return_count, total_refunded, top_reason, units, marketplace, last_return
WITH base AS (
    SELECT COALESCE(a."currency", 'UNSPECIFIED')  AS ccy,
           a."sku", a."asin",
           regexp_replace(a."reason", '^CR-', '') AS reason,
           COALESCE(a."refunded_amount", 0)       AS amt,
           COALESCE(a."qty", 0)                   AS q,
           -- Amazon market_place: LEDSone has no market_place on returns, so it is
           -- resolved via the order header (Option A). Deterministic single row per
           -- order_id (LIMIT 1 ORDER BY id) so the returns grain never fans out.
           COALESCE(omp.name, 'UNSPECIFIED')      AS "market_place",
           a."request_date"
    FROM customer_service.amazon_returns a
    LEFT JOIN LATERAL (
        SELECT mp.name
        FROM order_management.orders o
        LEFT JOIN order_management.market_place mp
          ON mp.id = CASE WHEN o.market_place ~ '^[0-9]+$' THEN o.market_place::int END
        WHERE o.order_id = a.order_id
        ORDER BY o.id
        LIMIT 1
    ) omp ON TRUE
    WHERE a."request_date" >= CURRENT_DATE - INTERVAL '3 months'
      AND a."sku" IS NOT NULL
),
sku_agg AS (
    SELECT ccy, "sku", "asin",
           COUNT(*)                                            AS return_count,
           ROUND(SUM(amt)::numeric, 2)                         AS total_refunded,
           SUM(q)::int                                         AS units,
           MODE() WITHIN GROUP (ORDER BY "market_place")       AS marketplace,
           MAX("request_date")::text                           AS last_return
    FROM base
    GROUP BY ccy, "sku", "asin"
),
top_reason AS (
    SELECT DISTINCT ON (ccy, "sku", "asin")
           ccy, "sku", "asin", reason AS top_reason
    FROM base
    GROUP BY ccy, "sku", "asin", reason
    ORDER BY ccy, "sku", "asin", COUNT(*) DESC, reason
)
SELECT a.ccy, a."sku", a."asin", a.return_count, a.total_refunded,
       t.top_reason, a.units, a.marketplace, a.last_return
FROM sku_agg a
LEFT JOIN top_reason t USING (ccy, "sku", "asin")
ORDER BY a.ccy, a.total_refunded DESC, a.return_count DESC, a."sku";


-- name: ebay_reasons
-- columns: ccy, reason, return_count, pct_of_count, total_refunded, units, last_return
SELECT COALESCE("seller_currency", 'UNSPECIFIED') AS ccy,
       "reason",
       COUNT(*) AS return_count,
       ROUND((COUNT(*) * 100.0
              / SUM(COUNT(*)) OVER (PARTITION BY COALESCE("seller_currency", 'UNSPECIFIED')))::numeric, 1)
                                                                   AS pct_of_count,
       ROUND(SUM(COALESCE("seller_refund_amount", 0))::numeric, 2) AS total_refunded,
       SUM(COALESCE("return_qty", 0))::int                         AS units,
       MAX("request_date")::date::text                             AS last_return
FROM customer_service.ebay_returns
WHERE "res_his_order" = 0
  AND "request_date" >= CURRENT_DATE - INTERVAL '3 months'
GROUP BY 1, 2
ORDER BY ccy, total_refunded DESC, "reason";


-- name: ebay_skus
-- columns: ccy, sku, return_count, total_refunded, top_reason, units, marketplace, last_return
WITH ret AS (
    SELECT r."id", r."order_id", r."item_id", r."reason",
           r."market_place_code", r."request_date",
           COALESCE(r."seller_currency", 'UNSPECIFIED') AS ccy,
           COALESCE(r."seller_refund_amount", 0)        AS amt,
           COALESCE(r."return_qty", 0)                  AS q
    FROM customer_service.ebay_returns r
    WHERE r."res_his_order" = 0
      AND r."request_date" >= CURRENT_DATE - INTERVAL '3 months'
),
matched AS (
    SELECT r."id", r.ccy, r."reason", r."market_place_code", r."request_date",
           COALESCE(m."sku", '(UNATTRIBUTED — no matching order line)') AS sku,
           r.amt / GREATEST(m.n, 1) AS alloc,      -- refund split evenly across variation SKUs
           r.q   / GREATEST(m.n, 1) AS ualloc      -- units split the same way, for consistency
    FROM ret r
    LEFT JOIN LATERAL (
        -- 2-hop bridge (orders + order_item_info) reproduces the old order_transaction
        -- lookup keyed on order_id + item_id. DISTINCT item_sku per matched line drives
        -- the even split; the item_id filter keeps a merged order from leaking other SKUs.
        SELECT ot."sku", COUNT(*) OVER () AS n
        FROM (
            SELECT DISTINCT oii."item_sku" AS sku
            FROM order_management.orders o
            JOIN order_management.order_item_info oii ON oii."order_id" = o."id"
            WHERE o."order_id" = r."order_id"
              AND oii."item_id" = r."item_id"::text
              AND NULLIF(TRIM(oii."item_sku"), '') IS NOT NULL
        ) ot
    ) m ON TRUE
),
sku_agg AS (
    SELECT ccy, sku,
           COUNT(DISTINCT "id")                                     AS return_count,
           ROUND(SUM(alloc)::numeric, 2)                            AS total_refunded,
           ROUND(SUM(ualloc)::numeric, 1)                           AS units,
           MODE() WITHIN GROUP (ORDER BY "market_place_code")       AS marketplace,
           MAX("request_date")::date::text                          AS last_return
    FROM matched
    GROUP BY ccy, sku
),
top_reason AS (
    SELECT DISTINCT ON (ccy, sku) ccy, sku, "reason" AS top_reason
    FROM matched
    GROUP BY ccy, sku, "reason"
    ORDER BY ccy, sku, COUNT(*) DESC, "reason"
)
SELECT a.ccy, a.sku, a.return_count, a.total_refunded,
       t.top_reason, a.units, a.marketplace, a.last_return
FROM sku_agg a
LEFT JOIN top_reason t USING (ccy, sku)
ORDER BY a.ccy, a.total_refunded DESC, a.return_count DESC, a.sku;


-- ============================================================================
-- NOT_AS_DESCRIBED — Possible Image/Listing Mismatch Candidates
-- ============================================================================
-- Feeds the "Mismatch Candidates" dashboard tab. These ARE part of the daily refresh:
-- refresh_dashboard.py executes both queries and rewrites `const MISMATCH` (alongside
-- `const DATA` for the four main tables). Titles are carried forward per-SKU/id from the
-- previous block by the Python layer; every other field (counts, %NAD, refund, badge,
-- link) is regenerated from these queries.
--
-- Threshold (both platforms): >= 3 NOT_AS_DESCRIBED returns for the SKU AND that
-- reason being >= 40% of the SKU's OWN total returns (denominator = the SKU's own
-- returns, not all SKUs).
--
-- DEVIATION (disclosed on the dashboard, pending DWC ratification): Amazon's real
-- "not as described" signal is AMZ-PG-BAD-DESC. eBay uses the literal 'NOT_AS_DESCRIBED'.
-- Both are present and populated in LEDSone (verified during migration).


-- name: nad_amazon_candidates
-- Amazon SKUs with a high concentration of AMZ-PG-BAD-DESC returns, + listing context.
WITH ar AS (
    -- one deterministic market_place per return (Option A), no fan-out
    SELECT a.sku, a.asin, a.reason, a.refunded_amount, a.currency,
           COALESCE(omp.name, 'UNSPECIFIED') AS market_place
    FROM customer_service.amazon_returns a
    LEFT JOIN LATERAL (
        SELECT mp.name
        FROM order_management.orders o
        LEFT JOIN order_management.market_place mp
          ON mp.id = CASE WHEN o.market_place ~ '^[0-9]+$' THEN o.market_place::int END
        WHERE o.order_id = a.order_id
        ORDER BY o.id
        LIMIT 1
    ) omp ON TRUE
    WHERE a.request_date >= CURRENT_DATE - INTERVAL '3 months'
),
cand AS (
    SELECT sku, asin, market_place,
           COUNT(*)                                                              AS total_returns,
           COUNT(*) FILTER (WHERE reason = 'AMZ-PG-BAD-DESC')                     AS nad_count,
           ROUND(COUNT(*) FILTER (WHERE reason = 'AMZ-PG-BAD-DESC')::numeric*100.0
                 / NULLIF(COUNT(*),0), 1)                                         AS pct_nad,
           ROUND(SUM(COALESCE(refunded_amount,0)) FILTER (WHERE reason='AMZ-PG-BAD-DESC')::numeric, 2) AS nad_refund,
           MAX(currency) FILTER (WHERE reason='AMZ-PG-BAD-DESC')                  AS ccy
    FROM ar
    GROUP BY sku, asin, market_place
    HAVING COUNT(*) FILTER (WHERE reason='AMZ-PG-BAD-DESC') >= 1  -- all SKUs with any NAD return
       -- (the dashboard badges rows that also meet the strict >=3 AND >=40% signal)
),
ld AS (   -- dedup amazon_listings to ONE row per ASIN+marketplace(site), prefer is_child
    SELECT DISTINCT ON (ref_id, market_place)
           ref_id, market_place, title, price, currency, product_type
    FROM (
        SELECT asin AS ref_id, site AS market_place, title, price, currency, product_type, is_child
        FROM listings.amazon_listings
        WHERE wrong_sku = 0
    ) s
    -- tie-break on every selected column so DISTINCT ON is deterministic across runs
    ORDER BY ref_id, market_place, is_child DESC NULLS LAST, price DESC NULLS LAST,
             title NULLS LAST, currency NULLS LAST, product_type NULLS LAST
)
SELECT c.sku, c.asin, c.market_place, c.ccy,
       c.total_returns, c.nad_count, c.pct_nad, c.nad_refund,
       l.title, l.price AS list_price, l.currency AS list_currency, l.product_type,
       'https://www.amazon.co.uk/dp/' || c.asin AS listing_link
FROM cand c
LEFT JOIN ld l ON l.ref_id = c.asin AND l.market_place = c.market_place
ORDER BY c.pct_nad DESC, c.nad_count DESC, c.sku;


-- name: nad_ebay_candidates
-- eBay SKUs with a high concentration of NOT_AS_DESCRIBED returns.
-- Uses the VALIDATED 2-hop bridge (orders + order_item_info on order_id + item_id).
WITH ret AS (
    SELECT r.id, r.reason,
           COALESCE(r.seller_currency,'UNSPECIFIED') AS ccy,
           COALESCE(r.seller_refund_amount, 0)       AS amt,   -- one row per return; summed NAD-only below
           ot.sku, ot.item_id
    FROM customer_service.ebay_returns r
    LEFT JOIN LATERAL (
        -- deterministic single SKU per return (ORDER BY item_sku LIMIT 1), same as the
        -- old order_transaction pick; 2-hop through orders + order_item_info.
        SELECT oii."item_sku" AS sku, oii."item_id"
        FROM order_management.orders o
        JOIN order_management.order_item_info oii ON oii."order_id" = o."id"
        WHERE o."order_id" = r."order_id"
          AND oii."item_id" = r."item_id"::text
          AND NULLIF(TRIM(oii."item_sku"), '') IS NOT NULL
        ORDER BY oii."item_sku"
        LIMIT 1
    ) ot ON TRUE
    WHERE r.res_his_order = 0
      AND r.request_date >= CURRENT_DATE - INTERVAL '3 months'
),
cand AS (
    SELECT sku, item_id, ccy,
           COUNT(DISTINCT id)                                                 AS total_returns,
           COUNT(DISTINCT id) FILTER (WHERE reason='NOT_AS_DESCRIBED')         AS nad_count,
           ROUND(COUNT(DISTINCT id) FILTER (WHERE reason='NOT_AS_DESCRIBED')::numeric*100.0
                 / NULLIF(COUNT(DISTINCT id),0), 1)                            AS pct_nad,
           ROUND(SUM(amt) FILTER (WHERE reason='NOT_AS_DESCRIBED')::numeric, 2) AS nad_refund
    FROM ret
    WHERE sku IS NOT NULL
    GROUP BY sku, item_id, ccy
    HAVING COUNT(DISTINCT id) FILTER (WHERE reason='NOT_AS_DESCRIBED') >= 1  -- all SKUs with any NAD return
       -- (dashboard badges rows that also meet the strict >=3 AND >=40% signal)
),
ld AS (   -- eBay listing context. LEDSone ebay_listings has no mapped_sku, so resolve on sku.
    SELECT DISTINCT ON (resolved_sku)
           resolved_sku, title, price, currency, product_type
    FROM (
        SELECT sku AS resolved_sku, title, price, currency, product_type, is_child
        FROM listings.ebay_listings
        WHERE wrong_sku = 0
    ) s
    -- tie-break on every selected column so DISTINCT ON is deterministic across runs
    ORDER BY resolved_sku, is_child DESC NULLS LAST, price DESC NULLS LAST,
             title NULLS LAST, currency NULLS LAST, product_type NULLS LAST
)
SELECT c.sku, c.item_id, c.ccy,
       c.total_returns, c.nad_count, c.pct_nad, c.nad_refund,
       l.title, l.price AS list_price, l.currency AS list_currency, l.product_type,
       'https://www.ebay.co.uk/itm/' || c.item_id AS listing_link
FROM cand c
LEFT JOIN ld l ON l.resolved_sku = c.sku
ORDER BY c.pct_nad DESC, c.nad_count DESC, c.sku;
