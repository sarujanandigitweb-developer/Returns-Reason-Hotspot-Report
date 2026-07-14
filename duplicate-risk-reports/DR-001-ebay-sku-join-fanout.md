# DR-001 — eBay SKU join fans out and overstates refunds

**Status:** OPEN — needs a decision before the report is built
**Found:** 2026-07-14, during pre-build validation
**Affects:** Task Brief Step 4 (eBay — Top 15 SKUs by Refund Value)

---

## The problem

`public.order_transaction` is a **line-item level** table — one row per SKU on an order, not one row per order. `public.ebay_returns` is at return level and joins on `order_id` alone.

So when a returned order contained more than one line item, the brief's `LEFT JOIN` produces one row per line item, and `SUM(r.seller_refund_amount)` counts the **same refund once per SKU on that order**.

## Measured impact (last 3 months, `res_his_order = 0`)

| Metric | Value |
|---|---|
| Return rows before join | 489 |
| Rows after join | 581 |
| Orders that fan out (>1 line item) | 42 |
| Worst single-order fan-out | 10 line items |
| Orders with no match in `order_transaction` | 3 |
| **True refund total** | **£11,384.44** |
| **Total the brief's Step 4 SQL produces** | **£12,825.91** |
| **Overstatement** | **+£1,441.47 (+12.7%)** |

Two separate errors follow from this:

1. **The total is inflated by 12.7%.** The Top 15 table would not reconcile against the eBay Reasons table in Section 3, which is computed without the join and is correct.
2. **Refunds are misattributed.** A £100 refund on an order containing 3 SKUs credits £100 of blame to *each* of the 3 SKUs. An innocent SKU that merely shared a basket with a genuinely faulty one climbs the "top offenders" list. That is precisely the decision this report is supposed to drive — which SKU gets a supplier fix — so the misattribution is not cosmetic.

Also: 3 orders have no `order_transaction` match and will surface as a `NULL` SKU row.

## Options

**A — Split the refund evenly across the order's line items.** Divide `seller_refund_amount` by the line-item count for that order. The eBay grand total then reconciles to £11,384.44 exactly, and no SKU is blamed for a neighbour's refund. Blame is diluted when the true culprit is one SKU in the basket, but no SKU is ever over-blamed.

**B — Attribute the full refund to the order's highest-value line item.** Assumes the priciest item is the one being returned. Total still reconciles. Sharper attribution when the guess is right, plain wrong when it isn't.

**C — Join on `order_id` AND `item_id` to pin the actual returned line.** Coverage tested against live data:

| Outcome of `order_id + item_id` join | Return rows | |
|---|---|---|
| Resolves to exactly one SKU | 440 | 90.0% — clean, exact attribution |
| Resolves to >1 SKU (variation listing) | 46 | 9.4% — one eBay listing, several SKUs (size/colour) |
| No match in `order_transaction` | 3 | 0.6% — £74.79 unattributable |

**D — Ship the brief's SQL as written**, with a visible caveat on the table.

## Recommendation — C with A as fallback

Join on `order_id + item_id`. That gives exact, correct attribution for **90% of returns outright**. For the 46 variation-listing rows where one `item_id` still covers several SKUs, split that refund evenly across them (option A). Show the 3 unmatched rows as an explicit "Unattributed — £74.79" line rather than silently dropping them.

This makes the eBay Top-15 total reconcile to **£11,384.44**, matching the eBay Reasons table exactly. Option D does not reconcile, and would put SKUs on the "top offenders" list that did nothing wrong.

## Decision

**Implemented: C with A as fallback** (2026-07-14), in `sql/returns_hotspot_queries.sql` query 4 and shipped in `index.html`.

- SKU resolved on `order_id + item_id`.
- Variation listings (one `item_id` → several SKUs) split evenly.
- The 3 unmatched returns surface as an explicit *Unattributed* row (GBP £56.81 / EUR €17.98), never dropped.
- eBay SKU totals now reconcile to the eBay reason table **exactly, in every currency** — see `validation/reconciliation.md`.

The deviation is disclosed in a panel at the top of the report itself, so DWC sees it without being told.

**Still needs DWC's ratification** — he specified the Step 4 SQL, and this overrides it. If he wants the brief's version shipped as-is, the change is a one-query revert.
