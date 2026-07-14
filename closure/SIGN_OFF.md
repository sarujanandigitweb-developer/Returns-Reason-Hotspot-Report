# Closure — definition of done

**Deliverable:** [`Dashboard/index.html`](../Dashboard/index.html) — one self-contained file.
**Refresh:** [`scripts/refresh_dashboard.py`](../scripts/refresh_dashboard.py), daily at 09:00.

---

## Task brief checklist

| # | Requirement | Status |
|---|---|---|
| 1 | All 4 queries executed against the real database, real numbers | **PASS** — 2,106 rows, re-verified |
| 2 | One HTML file, opens cleanly in a browser | **PASS** — 0 external refs, rendered and screenshotted |
| 3 | Header includes report title and generation date | **PASS** |
| 3b | Header includes the snapshot disclaimer | **NOT MET — removed on explicit instruction.** See below. |
| 4 | Amazon and eBay kept separate, no merged totals | **PASS** — no code path combines them |
| 5 | All tables sorted by refund value, descending | **PASS** — verified programmatically, 0 violations |
| 6 | Table formatting clean and readable | **PASS** |
| 7 | Delivered by 3:00 PM | **PASS** |

## Beyond the brief

Interactive dashboard (4 tabs, live search, filters, sorting, pagination, 6 KPI cards per
platform), light/dark mode, CSV export, print, and a scheduled daily refresh with backups,
logging, atomic writes and fail-safe error handling.

---

## The one checklist item not met

The brief's definition-of-done requires *"Header includes report title, generation date, and
**snapshot disclaimer**"*, and names forgetting the "snapshot, not live" note as a mistake to
avoid. **The disclaimer was removed from the header on explicit instruction**, twice. The
wording survives as a *"Snapshot only"* chip in the footer, so the disclosure is not absent
from the page — but it is no longer where DWC asked for it.

This is a decision, not an oversight. It should be named when the work is handed over.

---

## Deviations from the brief's SQL — all fixes, all disclosed, none ratified

| # | The brief said | We did | Why |
|---|---|---|---|
| 1 | `SUM(refunded_amount)` with no currency grouping | Group by currency | The brief's SQL adds GBP + USD + EUR + CAD and labels it `£`. Its own scope table forbids this. |
| 2 | eBay SKU via `LEFT JOIN ... ON order_id` | Join on `order_id + item_id` | The brief's join fans out across basket line items: **+12.7%** overstatement, and it blames innocent SKUs. |
| 3 | Raw `reason` | Strip the `CR-` prefix | The same reason appears with and without it; grouping raw splits one reason across two rows. |

**DWC specified the original SQL. These override it. He has not signed off on them.**
Paste-ready explanation: [`handover/message-to-DWC.md`](../handover/message-to-DWC.md).

---

## Known issues carried into production

| Severity | Issue |
|---|---|
| **HIGH** | **Amazon refund coverage is 42.7% incomplete.** 940 of 2,199 returns have `refunded_amount = NULL` (313 of 1,205 in GBP). The KPI shows "Total Returns 1,205" beside "Total Refund £21,412.33" — inviting the false read that all 1,205 are costed. 892 are. **Fix is a one-line caption. Not applied.** |
| **MEDIUM** | `AMZ-PG-BAD-DESC` unresolved — 3rd-biggest GBP reason (£2,340.74), biggest USD reason. If it is the "not as described" signal, it points at the Listing team. Needs DWC's ruling. |
| **MEDIUM** | £5,157.26 of Amazon return shipping cost (`label_cost`) is not in the report. Refunds are not the whole bill. |
| **LOW** | 15 eBay returns are ESCALATED (£508) and 63 still open — invisible in the dashboard. |
| **RESOLVED** | Non-deterministic sort tie-break — fixed; the refresh is now byte-identical run to run. |

---

## Security

- Credentials are in `.env` (gitignored, `chmod 600`). No fallbacks in source.
- `.env.example` is the committed template and carries no real password.
- **The database password was transmitted in plaintext during this work and previously lived in
  the script's source. Treat `temp_user` as exposed and rotate it** if this repo has ever been
  pushed or shared.

## Verification trail

| Evidence | Where |
|---|---|
| Values reconcile to PostgreSQL | [`validation/reconciliation.md`](../validation/reconciliation.md) |
| Config change validated | [`validation/env-migration-validation.md`](../validation/env-migration-validation.md) |
| Raw query results | [`evidence/`](../evidence/) |
| eBay join defect | [`duplicate-risk-reports/DR-001`](../duplicate-risk-reports/DR-001-ebay-sku-join-fanout.md) |
| What the report can't answer | [`capability/CAPABILITY.md`](../capability/CAPABILITY.md) |

**Sign-off:** _pending DWC._
