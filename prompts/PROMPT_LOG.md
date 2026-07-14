# Prompt log — how this project was built

A record of what was asked for, and — more usefully — **where the instructions were wrong**,
so the same ground isn't re-covered.

| # | Request | Outcome |
|---|---|---|
| 1 | Understand the brief, create the folder structure | Scaffolding created. Schema verified against the live DB. |
| 2 | Discovery: does an existing returns dashboard already exist? | No overlapping asset. Found the sibling `POSTAGE-RECONCILIATION-SYSTEM` (same house conventions, reusable table skills) and two `staging_ai` returns views. |
| 3 | Build the HTML report | Built with real data. **Three defects found in the brief's own SQL** (below). |
| 4 | Zero-trust revalidation | 896 cells re-diffed against a fresh query run. All values correct. Two disclosure issues raised. |
| 5 | Convert report -> interactive dashboard | Tabs, filters, search, sorting, pagination, KPIs. All records loaded (top-15 cap removed). |
| 6 | UI passes (padding, KPI cards, theme, icons, logo, table header) | Iterative. Light/dark mode added. |
| 7 | Restrict sorting to count + refund | Done — other columns made inert. |
| 8 | Recommend additional columns | DB analysed. Units / Marketplace / Last Return added. **Return rate rejected on evidence.** |
| 9 | Python refresh script + cron | Built, tested, fails safe. |
| 10 | Move credentials to `.env` | Done. No fallbacks. |

---

## Where the instructions were wrong

The task brief was authoritative in tone but wrong in five places. Each was caught by
**running the query rather than trusting the spec.**

1. **Step 4's eBay SKU join double-counted.** `LEFT JOIN ... ON order_id` alone fans out across
   basket line items — overstating eBay SKU refunds by **+12.7%** and blaming SKUs that merely
   shared a basket with a faulty item. → [DR-001](../duplicate-risk-reports/DR-001-ebay-sku-join-fanout.md)

2. **Steps 1–2 summed four currencies into one number labelled `£`.** Amazon is itself
   multi-currency (GBP/USD/EUR/CAD + nulls). The brief's own scope table forbids exactly this
   — it just didn't notice Amazon was multi-currency. The brief's SQL produces a meaningless
   **36,899.74** headline.

3. **The reason lists were wrong for both platforms.** Live Amazon codes mostly carry a `CR-`
   prefix, inconsistently — so grouping raw splits one reason across two rows. eBay's real
   codes barely overlap with the brief's list at all.

4. **The `TABLE_*.md` reference files the brief said were "already in the project" were not there.**
   Schema was read from the database directly. (They appeared later, in `skills/`.)

5. **The brief's field choice under-reports Amazon.** `refunded_amount` is NULL on 42.7% of
   Amazon returns, and the company's own `TABLE_amazon_returns.md` says it's a denormalised
   summary. Kept per the brief, but flagged.

## Standing decisions

- **Never** sum across currencies or across platforms.
- **Never** join `ebay_returns` to `order_transaction` on `order_id` alone.
- **Never** add a column without running the fan-out guard first
  (`query-packs/investigation-queries.sql`, query 6).
- **Keep the SQL tie-breaks.** Without them the dashboard reshuffles itself daily.

## Still open for DWC

- Should `AMZ-PG-BAD-DESC` merge into `NOT_AS_DESCRIBED`? It's the 3rd-biggest GBP reason
  (£2,340.74) and the biggest USD one. If yes, it points straight at the Listing team.
- Ratify the three deviations from the brief's SQL — all are fixes, all are disclosed, but he
  specified the original.
- The snapshot disclaimer was removed from the header on request. His definition-of-done
  requires it. Deliberate, but it is a checklist miss.
