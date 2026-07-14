# Validation — Returns Reason Hotspot Report

Run 2026-07-14 against live PostgreSQL. Every figure in `index.html` is embedded from
these results; nothing is hand-typed or estimated.

## 1. Platform totals reconcile to the database, per currency

Reason-table totals summed from the embedded JS, compared against a direct
`SUM()` over the source tables:

| Currency | Amazon (embedded = DB) | eBay (embedded = DB) |
|---|---|---|
| GBP | £21,412.33 ✓ | £7,742.62 ✓ |
| EUR | €4,362.85 ✓ | €3,174.27 ✓ |
| USD | $4,638.24 ✓ | $348.77 ✓ |
| CAD | C$403.61 ✓ | C$118.78 ✓ |
| Not recorded | 6,082.71 ✓ | — (no eBay rows) |

All PASS. Amazon rows in window: 2,199. eBay rows in window (`res_his_order = 0`): 489.

## 2. eBay SKU attribution reconciles to the eBay reason table

The corrected `order_id + item_id` allocation sums to **exactly** the reason-table
total in every currency (GBP 7,742.62 / EUR 3,174.27 / USD 348.77 / CAD 118.78).

The brief's Step 4 SQL does **not**: it produces £12,825.91 against a true
£11,384.44 across all currencies — **+12.7%**, because `LEFT JOIN … ON order_id`
duplicates a return once per line item in the basket (42 orders fan out; worst case
one order spread across 10 line items).

Unattributed (no matching order line), shown explicitly in the report, never dropped:
GBP £56.81 across 2 returns, EUR €17.98 across 1 return.

## 3. Filter checks

| Check | Result |
|---|---|
| `res_his_order = 0` applied to every eBay query | Yes — without it the window returns **5,064** rows instead of 489 (10× inflation) |
| eBay SKU sourced from `order_transaction`, never `ebay_returns` | Yes — `ebay_returns` has no `sku` column |
| Amazon and eBay totals never combined | Yes — separate sections, separate KPI rows |
| Currencies never combined | Yes — one currency selected at a time; no cross-currency total exists anywhere in the file |

## 4. Output checks

| Check | Result |
|---|---|
| JS syntax | `node --check` passes |
| Every table sorted by refund value, descending | Verified programmatically across all 4 tables × 5 currencies — 0 violations |
| SKU tables capped at 15 | Yes |
| Renders in a browser | Verified via headless Chrome screenshot, all 4 sections + KPIs + footer |
| Currency switch does not break tables | Fixed — empty state renders inside the table rather than replacing it (an earlier version destroyed the node and crashed on switching back) |

## 5. Known caveat, not resolved

`AMZ-PG-BAD-DESC` is left as its own reason and **not** merged into `NOT_AS_DESCRIBED`.
On GBP it is the **3rd largest** refund reason (£2,340.74), and on USD the **largest**
($1,289.18). If it is in fact the "not as described" signal, that is a direct pointer at
the Listing/Copywriting team and the number is bigger than it currently looks. Merging
the two requires a judgement about Amazon's taxonomy that should come from DWC, not
from me — flagged rather than assumed.
