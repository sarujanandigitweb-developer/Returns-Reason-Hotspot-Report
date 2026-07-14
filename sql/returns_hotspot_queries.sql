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
