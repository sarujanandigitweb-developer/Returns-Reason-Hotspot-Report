-- Returns Reason Hotspot Report — the four queries as actually executed, 2026-07-14.
-- Window: request_date >= CURRENT_DATE - INTERVAL '3 months'
--
-- These differ from the task brief's Step 1-4 in three ways. Each deviation is
-- there to fix a defect in the brief's SQL, not for style. See
-- duplicate-risk-reports/DR-001 and validation/reconciliation.md.
--
--   1. Every query groups by currency. Both platforms are multi-currency in this
--      window (Amazon: GBP/USD/EUR/CAD + 677 rows with no currency recorded).
--      The brief's Step 1/2 SUM(refunded_amount) with no currency grouping adds
--      pounds to dollars to euros and labels the result "£".
--   2. eBay SKU is resolved on order_id + item_id, not order_id alone. The brief's
--      Step 4 join fans out across basket line items and overstates eBay SKU
--      refunds by +12.7%.
--   3. Amazon reason has its CR- prefix stripped, because the same reason appears
--      in the data both with and without it and would otherwise split into two rows.


-- ============================================================================
-- 1. AMAZON — Return Reasons Summary (per currency)
-- ============================================================================
WITH base AS (
    SELECT COALESCE("currency", 'UNSPECIFIED')       AS ccy,
           regexp_replace("reason", '^CR-', '')      AS reason,
           COALESCE("refunded_amount", 0)            AS amt
    FROM public.amazon_returns
    WHERE "request_date" >= CURRENT_DATE - INTERVAL '3 months'
)
SELECT ccy,
       reason,
       COUNT(*)                                                                     AS return_count,
       ROUND((COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (PARTITION BY ccy))::numeric, 1) AS pct_of_count,
       ROUND(SUM(amt)::numeric, 2)                                                   AS total_refunded
FROM base
GROUP BY ccy, reason
ORDER BY ccy, total_refunded DESC;


-- ============================================================================
-- 2. AMAZON — Top 15 SKUs by Refund Value (per currency, + most common reason)
-- ============================================================================
WITH base AS (
    SELECT COALESCE("currency", 'UNSPECIFIED')  AS ccy,
           "sku", "asin",
           regexp_replace("reason", '^CR-', '') AS reason,
           COALESCE("refunded_amount", 0)       AS amt
    FROM public.amazon_returns
    WHERE "request_date" >= CURRENT_DATE - INTERVAL '3 months'
      AND "sku" IS NOT NULL
),
sku_agg AS (
    SELECT ccy, "sku", "asin",
           COUNT(*)                    AS return_count,
           ROUND(SUM(amt)::numeric, 2) AS total_refunded
    FROM base
    GROUP BY ccy, "sku", "asin"
),
top_reason AS (
    SELECT DISTINCT ON (ccy, "sku", "asin")
           ccy, "sku", "asin", reason AS top_reason
    FROM base
    GROUP BY ccy, "sku", "asin", reason
    ORDER BY ccy, "sku", "asin", COUNT(*) DESC, reason
),
ranked AS (
    SELECT a.*, t.top_reason,
           ROW_NUMBER() OVER (PARTITION BY a.ccy
                              ORDER BY a.total_refunded DESC, a.return_count DESC) AS rn
    FROM sku_agg a
    LEFT JOIN top_reason t USING (ccy, "sku", "asin")
)
SELECT ccy, "sku", "asin", return_count, total_refunded, top_reason
FROM ranked
WHERE rn <= 15
ORDER BY ccy, total_refunded DESC;


-- ============================================================================
-- 3. eBAY — Return Reasons Summary (per currency)
--    res_his_order = 0 is mandatory: without it the window returns 5,064 rows
--    instead of 489 (resolution-history rows, a 10x inflation).
-- ============================================================================
SELECT COALESCE("seller_currency", 'UNSPECIFIED') AS ccy,
       "reason",
       COUNT(*) AS return_count,
       ROUND((COUNT(*) * 100.0
              / SUM(COUNT(*)) OVER (PARTITION BY COALESCE("seller_currency", 'UNSPECIFIED')))::numeric, 1)
                                                  AS pct_of_count,
       ROUND(SUM(COALESCE("seller_refund_amount", 0))::numeric, 2) AS total_refunded
FROM public.ebay_returns
WHERE "res_his_order" = 0
  AND "request_date" >= CURRENT_DATE - INTERVAL '3 months'
GROUP BY 1, 2
ORDER BY ccy, total_refunded DESC;


-- ============================================================================
-- 4. eBAY — Top 15 SKUs by Refund Value (per currency)
--    Refund attributed to the ACTUAL returned line via order_id + item_id.
--    Where one item_id still maps to several SKUs (a variation listing: one eBay
--    listing, several sizes/colours), the refund is split evenly across them.
--    Returns with no matching order line surface as an explicit UNATTRIBUTED row
--    rather than being silently dropped.
--    This reconciles to query 3 exactly, per currency. The brief's version does not.
-- ============================================================================
WITH ret AS (
    SELECT r."id", r."order_id", r."item_id", r."reason",
           COALESCE(r."seller_currency", 'UNSPECIFIED') AS ccy,
           COALESCE(r."seller_refund_amount", 0)        AS amt
    FROM public.ebay_returns r
    WHERE r."res_his_order" = 0
      AND r."request_date" >= CURRENT_DATE - INTERVAL '3 months'
),
matched AS (
    SELECT r."id", r.ccy, r.amt, r."reason",
           COALESCE(m."sku", '(UNATTRIBUTED — no matching order line)') AS sku,
           r.amt / GREATEST(m.n, 1)                                     AS alloc
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
           COUNT(DISTINCT "id")          AS return_count,
           ROUND(SUM(alloc)::numeric, 2) AS total_refunded
    FROM matched
    GROUP BY ccy, sku
),
top_reason AS (
    SELECT DISTINCT ON (ccy, sku) ccy, sku, "reason" AS top_reason
    FROM matched
    GROUP BY ccy, sku, "reason"
    ORDER BY ccy, sku, COUNT(*) DESC, "reason"
),
ranked AS (
    SELECT a.*, t.top_reason,
           ROW_NUMBER() OVER (PARTITION BY a.ccy
                              ORDER BY a.total_refunded DESC, a.return_count DESC) AS rn
    FROM sku_agg a
    LEFT JOIN top_reason t USING (ccy, sku)
)
SELECT ccy, sku, return_count, total_refunded, top_reason
FROM ranked
WHERE rn <= 15
ORDER BY ccy, total_refunded DESC;
