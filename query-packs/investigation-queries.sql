-- ============================================================================
-- Investigation query pack — Returns Reason Hotspot
--
-- Ad-hoc queries for digging behind the dashboard. These are NOT part of the
-- refresh; the dashboard's four queries live in sql/returns_hotspot_queries.sql.
--
-- Every query below keeps the two non-negotiable rules:
--   * ebay_returns must be filtered res_his_order = 0
--   * currencies and platforms are never summed together
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 1. Is a reason ONE bad SKU, or spread across the catalogue?
--    Answers "who owns the fix": concentrated -> supplier/quality problem.
--    Diffuse -> listing/compatibility problem.
--    (NOT_COMPATIBLE spans 261 SKUs -> diffuse -> Listing team, not Quality.)
-- ---------------------------------------------------------------------------
SELECT regexp_replace(reason,'^CR-','')                 AS reason,
       COUNT(*)                                         AS returns,
       COUNT(DISTINCT sku)                              AS skus_affected,
       ROUND(COUNT(*)::numeric / COUNT(DISTINCT sku),2) AS returns_per_sku,
       ROUND(SUM(COALESCE(refunded_amount,0))::numeric,2) AS refund
FROM public.amazon_returns
WHERE request_date >= CURRENT_DATE - INTERVAL '3 months'
  AND currency = 'GBP'
GROUP BY 1
ORDER BY refund DESC;


-- ---------------------------------------------------------------------------
-- 2. The TRUE cost of a reason: refund + return shipping label.
--    label_cost holds £5,157.26 in the window and is absent from the dashboard.
-- ---------------------------------------------------------------------------
SELECT regexp_replace(reason,'^CR-','')                    AS reason,
       ROUND(SUM(COALESCE(refunded_amount,0))::numeric,2)  AS refund,
       ROUND(SUM(COALESCE(label_cost,0))::numeric,2)       AS label_cost,
       ROUND((SUM(COALESCE(refunded_amount,0))
            + SUM(COALESCE(label_cost,0)))::numeric,2)     AS true_cost
FROM public.amazon_returns
WHERE request_date >= CURRENT_DATE - INTERVAL '3 months'
  AND currency = 'GBP'
GROUP BY 1
ORDER BY true_cost DESC;


-- ---------------------------------------------------------------------------
-- 3. eBay returns still OPEN or ESCALATED — live operational risk.
--    15 escalated (£507.91), 63 not closed.
-- ---------------------------------------------------------------------------
SELECT status,
       COUNT(*)                                                   AS returns,
       ROUND(SUM(COALESCE(seller_refund_amount,0))::numeric,2)    AS refund,
       seller_currency
FROM public.ebay_returns
WHERE res_his_order = 0
  AND request_date >= CURRENT_DATE - INTERVAL '3 months'
  AND status <> 'CLOSED'
GROUP BY status, seller_currency
ORDER BY refund DESC;


-- ---------------------------------------------------------------------------
-- 4. Buyer's own words for a SKU — eBay comments are 57.9% populated.
--    The verbatim "why", straight to the Listing team. (Amazon's is 5.6% — useless.)
-- ---------------------------------------------------------------------------
SELECT ot.sku, r.reason, r.request_date::date AS on_date,
       r.seller_refund_amount, r.seller_currency, r.comments
FROM public.ebay_returns r
LEFT JOIN LATERAL (
    SELECT DISTINCT o.sku FROM public.order_transaction o
    WHERE o.order_id = r.order_id AND o.item_id = r.item_id::text LIMIT 1
) ot ON TRUE
WHERE r.res_his_order = 0
  AND r.request_date >= CURRENT_DATE - INTERVAL '3 months'
  AND NULLIF(TRIM(r.comments),'') IS NOT NULL
  -- AND ot.sku = 'PUT_A_SKU_HERE'
ORDER BY r.seller_refund_amount DESC NULLS LAST
LIMIT 50;


-- ---------------------------------------------------------------------------
-- 5. Amazon refund-coverage gap — how much of the picture is actually costed?
--    42.7% of Amazon returns have refunded_amount = NULL.
-- ---------------------------------------------------------------------------
SELECT COALESCE(currency,'UNSPECIFIED') AS ccy,
       COUNT(*)                                                  AS returns,
       COUNT(*) FILTER (WHERE refunded_amount IS NULL)           AS no_refund_value,
       ROUND(100.0 * COUNT(*) FILTER (WHERE refunded_amount IS NULL)
             / COUNT(*), 1)                                      AS pct_uncosted,
       ROUND(SUM(COALESCE(refunded_amount,0))::numeric,2)        AS refund_reported
FROM public.amazon_returns
WHERE request_date >= CURRENT_DATE - INTERVAL '3 months'
GROUP BY 1
ORDER BY returns DESC;


-- ---------------------------------------------------------------------------
-- 6. Fan-out guard — run this BEFORE adding any new column to a SKU table.
--    0 = safe as a real column. >0 = it would split rows and move every
--    validated total; it can then only appear as MODE() WITHIN GROUP.
-- ---------------------------------------------------------------------------
WITH g AS (
    SELECT COALESCE(currency,'UNSPECIFIED') AS ccy, sku, asin,
           COUNT(DISTINCT fulfilment)      AS n_fulfilment,
           COUNT(DISTINCT market_place)    AS n_marketplace,
           COUNT(DISTINCT "Category")      AS n_category,
           COUNT(DISTINCT sub_source_name) AS n_store,
           COUNT(DISTINCT status)          AS n_status
    FROM public.amazon_returns
    WHERE request_date >= CURRENT_DATE - INTERVAL '3 months' AND sku IS NOT NULL
    GROUP BY 1,2,3
)
SELECT COUNT(*)                                  AS sku_rows,
       COUNT(*) FILTER (WHERE n_fulfilment  > 1) AS fulfilment_fans_out,   -- 0 : safe
       COUNT(*) FILTER (WHERE n_store       > 1) AS store_fans_out,        -- 0 : safe
       COUNT(*) FILTER (WHERE n_marketplace > 1) AS marketplace_fans_out,  -- 6
       COUNT(*) FILTER (WHERE n_status      > 1) AS status_fans_out,       -- 26
       COUNT(*) FILTER (WHERE n_category    > 1) AS category_fans_out      -- 69
FROM g;


-- ---------------------------------------------------------------------------
-- 7. DR-001 regression guard — proves the eBay SKU join has not silently
--    reverted to joining on order_id alone. naive_total should be 12825.91,
--    true_total 11384.44. If they ever converge, someone broke the fix.
-- ---------------------------------------------------------------------------
WITH ret AS (
    SELECT id, order_id, COALESCE(seller_refund_amount,0) AS amt
    FROM public.ebay_returns
    WHERE res_his_order = 0
      AND request_date >= CURRENT_DATE - INTERVAL '3 months'
)
SELECT ROUND(SUM(r.amt)::numeric,2)                       AS true_total,
       (SELECT ROUND(SUM(r2.amt)::numeric,2)
          FROM ret r2
          LEFT JOIN public.order_transaction ot
                 ON r2.order_id = ot.order_id)            AS naive_join_total,
       (SELECT COUNT(*) FROM (
            SELECT r3.order_id
            FROM ret r3 LEFT JOIN public.order_transaction ot ON r3.order_id = ot.order_id
            GROUP BY r3.order_id HAVING COUNT(ot.sku) > 1) x) AS orders_that_fan_out
FROM ret r;
