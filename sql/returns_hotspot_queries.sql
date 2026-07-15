-- ============================================================================
-- Returns Reason Hotspot Report — the four queries that build the dashboard.
-- Read and executed by scripts/refresh_dashboard.py. Query blocks are delimited
-- by "-- name:" markers; the script splits on those, so keep them intact.
--
-- Window: request_date >= CURRENT_DATE - INTERVAL '3 months'
--
-- BUSINESS RULES (unchanged — see duplicate-risk-reports/DR-001 and
-- validation/reconciliation.md):
--   * res_his_order = 0 on ebay_returns is mandatory. Without it the window
--     returns 5,064 rows instead of 489 — a 10x inflation from history rows.
--   * eBay has no sku column. SKU is resolved from order_transaction on
--     order_id + item_id (NOT order_id alone, which fans out across basket line
--     items and overstates eBay SKU refunds by +12.7%).
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
-- Ties on refund+count are common (many rows share an identical refund), and
-- without a tie-break PostgreSQL returns them in an arbitrary order — so a
-- scheduled refresh would reshuffle rows, and their rank numbers and the top-3
-- highlighting, every single morning without any data having changed.
-- The tie-break changes no value and no refund-descending order; it only makes
-- the result reproducible.
-- ============================================================================


-- name: amazon_reasons
-- columns: ccy, reason, return_count, pct_of_count, total_refunded, units, last_return
WITH base AS (
    SELECT COALESCE("currency", 'UNSPECIFIED')       AS ccy,
           regexp_replace("reason", '^CR-', '')      AS reason,
           COALESCE("refunded_amount", 0)            AS amt,
           COALESCE("qty", 0)                        AS q,
           "request_date"
    FROM public.amazon_returns
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
    SELECT COALESCE("currency", 'UNSPECIFIED')  AS ccy,
           "sku", "asin",
           regexp_replace("reason", '^CR-', '') AS reason,
           COALESCE("refunded_amount", 0)       AS amt,
           COALESCE("qty", 0)                   AS q,
           "market_place", "request_date"
    FROM public.amazon_returns
    WHERE "request_date" >= CURRENT_DATE - INTERVAL '3 months'
      AND "sku" IS NOT NULL
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
FROM public.ebay_returns
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
    FROM public.ebay_returns r
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
        SELECT ot."sku", COUNT(*) OVER () AS n
        FROM (
            SELECT DISTINCT "sku"
            FROM public.order_transaction
            WHERE "order_id" = r."order_id"
              AND "item_id"  = r."item_id"::text
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
-- Feeds the "Mismatch Candidates" dashboard tab. NOTE: these are NOT part of the
-- daily refresh (refresh_dashboard.py rewrites only the four queries above, which
-- populate `const DATA`). The mismatch tab reads `const MISMATCH`, a static
-- snapshot — re-run these by hand and update that block when needed.
--
-- Threshold (both platforms): >= 3 NOT_AS_DESCRIBED returns for the SKU AND that
-- reason being >= 40% of the SKU's OWN total returns (denominator = the SKU's own
-- returns, not all SKUs).
--
-- DEVIATION (disclosed on the dashboard, pending DWC ratification): Amazon's real
-- "not as described" signal is AMZ-PG-BAD-DESC. The literal 'NOT_AS_DESCRIBED'
-- value on Amazon is a near-empty legacy code (33 rows, GBP 0.00 refund) and
-- produces a misleading GBP 0.00 table. eBay uses the literal 'NOT_AS_DESCRIBED',
-- which is a real populated value there.


-- name: nad_amazon_candidates
-- Amazon SKUs with a high concentration of AMZ-PG-BAD-DESC returns, + listing context.
WITH cand AS (
    SELECT sku, asin, market_place,
           COUNT(*)                                                              AS total_returns,
           COUNT(*) FILTER (WHERE reason = 'AMZ-PG-BAD-DESC')                     AS nad_count,
           ROUND(COUNT(*) FILTER (WHERE reason = 'AMZ-PG-BAD-DESC')::numeric*100.0
                 / NULLIF(COUNT(*),0), 1)                                         AS pct_nad,
           ROUND(SUM(COALESCE(refunded_amount,0)) FILTER (WHERE reason='AMZ-PG-BAD-DESC')::numeric, 2) AS nad_refund,
           MAX(currency) FILTER (WHERE reason='AMZ-PG-BAD-DESC')                  AS ccy
    FROM public.amazon_returns
    WHERE request_date >= CURRENT_DATE - INTERVAL '3 months'
    GROUP BY sku, asin, market_place
    HAVING COUNT(*) FILTER (WHERE reason='AMZ-PG-BAD-DESC') >= 1  -- all SKUs with any NAD return
       -- (the dashboard badges rows that also meet the strict >=3 AND >=40% signal)
),
ld AS (   -- dedup listing_data to ONE row per ASIN+marketplace (prefer is_child), avoids fan-out
    SELECT DISTINCT ON (ref_id, market_place)
           ref_id, market_place, title, price, currency, product_type
    FROM public.listing_data
    WHERE which_channel = 1 AND wrong_sku = 0
    ORDER BY ref_id, market_place, is_child DESC NULLS LAST, price DESC NULLS LAST
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
-- Uses the VALIDATED bridge (order_id + item_id), NOT order_id alone (that fans out).
-- Returns 0 rows in the current window (max NAD on any one SKU is 2; threshold is 3).
WITH ret AS (
    SELECT r.id, r.reason,
           COALESCE(r.seller_currency,'UNSPECIFIED') AS ccy,
           ot.sku, ot.item_id
    FROM public.ebay_returns r
    LEFT JOIN LATERAL (
        SELECT o.sku, o.item_id FROM public.order_transaction o
        WHERE o.order_id = r.order_id AND o.item_id = r.item_id::text LIMIT 1
    ) ot ON TRUE
    WHERE r.res_his_order = 0
      AND r.request_date >= CURRENT_DATE - INTERVAL '3 months'
),
cand AS (
    SELECT sku, item_id, ccy,
           COUNT(DISTINCT id)                                                 AS total_returns,
           COUNT(DISTINCT id) FILTER (WHERE reason='NOT_AS_DESCRIBED')         AS nad_count,
           ROUND(COUNT(DISTINCT id) FILTER (WHERE reason='NOT_AS_DESCRIBED')::numeric*100.0
                 / NULLIF(COUNT(DISTINCT id),0), 1)                            AS pct_nad
    FROM ret
    WHERE sku IS NOT NULL
    GROUP BY sku, item_id, ccy
    HAVING COUNT(DISTINCT id) FILTER (WHERE reason='NOT_AS_DESCRIBED') >= 1  -- all SKUs with any NAD return
       -- (dashboard badges rows that also meet the strict >=3 AND >=40% signal)
),
ld AS (   -- eBay listing context: resolve SKU with COALESCE(NULLIF(mapped_sku,''),sku), dedup
    SELECT DISTINCT ON (resolved_sku)
           COALESCE(NULLIF(mapped_sku,''), sku) AS resolved_sku, title, price, currency, product_type
    FROM public.listing_data
    WHERE which_channel = 2 AND wrong_sku = 0
    ORDER BY resolved_sku, is_child DESC NULLS LAST, price DESC NULLS LAST
)
SELECT c.sku, c.item_id, c.ccy,
       c.total_returns, c.nad_count, c.pct_nad,
       l.title, l.price AS list_price, l.currency AS list_currency, l.product_type,
       'https://www.ebay.co.uk/itm/' || c.item_id AS listing_link
FROM cand c
LEFT JOIN ld l ON l.resolved_sku = c.sku
ORDER BY c.pct_nad DESC, c.nad_count DESC, c.sku;
