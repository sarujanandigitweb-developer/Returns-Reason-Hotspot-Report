# Returns Reason Hotspot Report

**Deliverable:** [`index.html`](index.html) — one self-contained file (CSS + JS + data all embedded, no external dependencies). Open it in any browser.

Answers *"Which products are being returned the most, why, and how much is it costing us?"* for Amazon and eBay, last 3 months, kept strictly separate.

## Status — built, verified, ready to send

- [x] All four queries executed against live PostgreSQL — real numbers, no placeholders
- [x] One HTML file, opens cleanly, renders verified in a browser
- [x] Header: title, generation date, snapshot disclaimer
- [x] Amazon and eBay separate — no merged totals anywhere
- [x] All tables sorted by refund value descending (verified programmatically)
- [x] Top 3 rows shaded; bold headers; alternating row shading
- [x] Every total reconciles to the database — see [validation/reconciliation.md](validation/reconciliation.md)
- [x] Stretch goal done: each top SKU shows its most common return reason

Extras beyond the brief: KPI cards per platform, currency selector, Refresh / Print / Export CSV.

## Read this before sending it to DWC

The report deviates from the brief's SQL in three places. **Each one fixes a defect** — they are documented in a panel at the top of the report itself, so DWC sees them without being told.

1. **Currency is split, never summed.** Both platforms are multi-currency in this window. The brief's Step 1/2 sums `refunded_amount` with no currency grouping — adding GBP + USD + EUR + CAD and labelling it `£`. That is the exact error the brief's own scope table forbids; it just doesn't notice Amazon is itself multi-currency.
2. **eBay SKU joins on `order_id + item_id`.** The brief's Step 4 joins on `order_id` alone, which fans out across basket line items and overstates eBay SKU refunds by **+12.7%** while blaming SKUs that merely shared a basket with a faulty item. See [DR-001](duplicate-risk-reports/DR-001-ebay-sku-join-fanout.md).
3. **Amazon `CR-` reason prefix stripped.** The same reason appears both with and without it; grouping raw splits one reason across two rows.

**One open question for DWC:** `AMZ-PG-BAD-DESC` is the 3rd biggest GBP refund reason (£2,340.74) and the biggest USD one. If that is the "not as described" signal, it points straight at the Listing team — but merging it into `NOT_AS_DESCRIBED` is a call about Amazon's taxonomy that should be his, not mine. Flagged, not assumed.

## Headline numbers (GBP, last 3 months)

| | Amazon | eBay |
|---|---|---|
| Returns | 1,205 | 340 |
| Refunded | £21,412.33 | £7,742.62 |
| Top reason | NOT_COMPATIBLE (£5,665.27) | WRONG_SIZE (£1,885.89) |

Never added together — different currencies and fee structures.

## Folders

| Folder | Holds |
|---|---|
| `sql/` | [The four queries as actually run](sql/returns_hotspot_queries.sql), with the deviations commented inline |
| `validation/` | [Reconciliation proof](validation/reconciliation.md) — embedded figures vs database |
| `duplicate-risk-reports/` | [DR-001](duplicate-risk-reports/DR-001-ebay-sku-join-fanout.md) — the eBay join fan-out |
| `documentation/` | The original task brief |
| `handover/` | [Paste-ready message to DWC](handover/message-to-DWC.md) |
| `evidence/`, `data-maps/`, `query-packs/`, `workflows/`, `capability/`, `prompts/`, `closure/` | Scaffolding for follow-on work |

## Two rules that will bite anyone extending this

1. **`res_his_order = 0` on `ebay_returns` is not optional.** Without it the 3-month window returns 5,064 rows instead of 489 — a 10× inflation from resolution-history rows.
2. **Never add Amazon and eBay — or two currencies — into one number.**
