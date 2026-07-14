# Message to DWC — paste-ready

> Hi — before I build the Returns Hotspot report I ran the four queries against live data to sanity-check them, and I think Step 4 (eBay Top 15 SKUs) has a bug I'd rather raise now than ship.
>
> `order_transaction` is one row per **line item**, but `ebay_returns` is one row per **return**, and Step 4 joins on `order_id` only. So any returned order that had more than one item in the basket gets duplicated once per SKU, and `SUM(seller_refund_amount)` counts the same refund multiple times. In the last 3 months that's 42 orders, worst case one order with 10 line items.
>
> Two effects:
> - The eBay SKU total comes out **£12,825.91** instead of the true **£11,384.44** (+12.7%). It won't reconcile against the eBay Reasons table in Step 3, which is correct.
> - A £100 refund on a 3-item order blames the full £100 on *each* SKU. So SKUs land on the top-offenders list purely for sharing a basket with a faulty item — which is a problem given the whole point is deciding which SKU gets a supplier fix.
>
> The fix looks clean: join on `order_id + item_id` instead. I tested it — that resolves 440 of 489 returns (90%) to exactly one SKU. 46 land on variation listings (one eBay listing, several SKUs by size/colour) which I'd split evenly, and 3 have no matching order line at all (£74.79) which I'd show as an explicit "unattributed" row rather than hide. That makes the eBay total reconcile exactly.
>
> Happy to build it either way — just don't want to hand you a table that doesn't tie out to the one above it. Which do you want for the 3pm?
>
> (Also confirmed your `res_his_order = 0` warning — without it the window pulls 5,064 rows instead of 489.)

---

## If DWC says "just build what I specified"

Everything is staged and ready; the four queries run clean. Build time is short — the blocker is only this decision.

## If DWC says "fix it"

Use the `order_id + item_id` join, even-split fallback for variation listings, explicit unattributed row. See [DR-001](../duplicate-risk-reports/DR-001-ebay-sku-join-fanout.md) for the full numbers.

## Verified facts to lean on

| Check | Result |
|---|---|
| All 3 tables + every column in the brief exist | Yes |
| Amazon rows, last 3 months | 2,199 (through 2026-07-12) |
| eBay rows, last 3 months, `res_his_order = 0` | 489 (through 2026-07-13) |
| eBay rows *without* the `res_his_order` filter | 5,064 — a 10× inflation |
| True eBay refund total | £11,384.44 |
| What the brief's Step 4 SQL produces | £12,825.91 |
