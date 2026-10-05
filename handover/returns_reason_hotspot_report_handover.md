# Returns Reason Hotspot Report - Handover

Project name: `returns_reason_hotspot_report` (project code RRHD) | Folder: `/home/led-247/Returns-Reason-Hotspot-Report` | Developer: Sarujanan (git author `sarujanandigitweb-developer`) | Handover written: 2026-10-05 from the current code, git log and logs.

## 1. Project Overview

A single self-contained HTML dashboard, `Dashboard/index.html` (CSS, JS and data all embedded, no external dependencies), answering: "Which products are being returned the most, why, and how much is it costing us?" for Amazon and eBay over the last 3 months. Requested by DWC (task brief in `documentation/`).

Five tabs: Amazon - Return Reasons; Amazon - SKU Refund Analysis; eBay - Return Reasons; eBay - SKU Refund Analysis; Mismatch Candidates (SKUs whose returns are "not as described", i.e. a listing/photo problem rather than a faulty product).

Business rules (all in `sql/returns_hotspot_queries.sql`; do not change lightly):

- Window: `request_date >= CURRENT_DATE - INTERVAL '3 months'`.
- eBay: `res_his_order = 0` is mandatory (otherwise about 10x row inflation from resolution-history rows).
- eBay has no SKU column: SKU is resolved through the order bridge on `order_id + item_id` (never `order_id` alone, which fans out - see `duplicate-risk-reports/DR-001-ebay-sku-join-fanout.md`). Variation listings (one item_id, several SKUs) split refund and units evenly; returns with no matching order line appear as an explicit UNATTRIBUTED row.
- Currency is grouped, never summed across currencies. Amazon and eBay are never combined.
- Amazon `CR-` reason prefix is stripped so one reason does not split across two rows.
- Mismatch signal: Amazon reason `AMZ-PG-BAD-DESC`, eBay reason `NOT_AS_DESCRIBED`. A SKU is badged (red) when it has at least 3 such returns AND they are at least 40% of that SKU's own returns. These thresholds are hardcoded in SQL/JS; BLOS ratification by DWC is still pending.
- Amazon marketplace is derived (returns carry none): `orders.market_place` to `order_management.market_place.name`; about 16% of returns have no order header and show `UNSPECIFIED` (expected, never invented).
- Every query ends with a deterministic tie-break so ranks do not reshuffle between runs.

## 2. Final Status

Status: **Complete, with Known Limitations** (live in production, refreshed and published daily).

- Last successful automated run: 2026-10-05 10:00 (refresh 11.6s, 2,323 rows, hub publish OK, 298,548 bytes).
- Known limitations (section 10): eBay "Units" under-count (unfixed), Amazon refund coverage gap (about 43% of returns have NULL refunded_amount), exposed hub credential still to be rotated, DWC has not signed off the SQL deviations.

## 3. Latest Updates

| Date | Commit | Change |
|---|---|---|
| 2026-07-14 | 90d3f1a | First build: 4 queries, dashboard, refresh script, DR-001 decision. |
| 2026-07-15 | 5999ff1 | Mismatch/refund-detail SQL; dashboard grew (Mismatch Candidates tab, all-rows pagination). Daily log D02. |
| 2026-07-17 | 3f276f3, bb7bee7 | Mismatch Candidates auto-refresh: refresh script now also rewrites `const MISMATCH` (six queries). Daily log D03. |
| 2026-07-24 | bbd1de6 | Added `scripts/push_to_hub.js`, `scripts/refresh_and_publish.sh`, `scripts/package.json`; daily hub publish. |
| 2026-09-14 | fb4cb19, 8d9b8df, b87c938 | Data source migrated from the old `order_management_copy` DB to LEDSone PostgreSQL (schema mapping only, logic unchanged); live cut-over. |
| 2026-09-14 | 0ef21b1 | Hub publish decoupled from the data source: separate `HUB_PG*` env vars (hub DB is a different database from LEDSone). |
| 2026-09-14 | fc3662e | Documentation refresh for handover (README, TABLE_MAP, REFRESH_WORKFLOW, SIGN_OFF). |
| 2026-09-17 | 8662923 | Post-migration data validation and eBay Units known issue recorded (final commit by the developer). |

Latest working implementation: cron 10:00 daily runs `scripts/refresh_and_publish.sh` which (1) runs `scripts/refresh_dashboard.py` against LEDSone, then (2) only if stage 1 succeeded, runs `scripts/push_to_hub.js` to upsert the HTML into the hub. No code changes after 2026-09-17.

Uncommitted work at time of writing: `Dashboard/index.html` is modified (3 lines changed). This is just the daily data refresh (GENERATED_AT 2026-10-05 and data constants) written by the cron job after the last commit; it is expected, not unfinished work.

## 4. Project Structure / Important Files

| Path | Purpose |
|---|---|
| `Dashboard/index.html` | The deliverable. Embedded `const DATA`, `const MISMATCH`, `const GENERATED_AT` are the only parts the refresh rewrites. |
| `sql/returns_hotspot_queries.sql` | The six queries (`-- name:` markers are parsed by the script, keep them): `amazon_reasons`, `amazon_skus`, `ebay_reasons`, `ebay_skus`, `nad_amazon_candidates`, `nad_ebay_candidates`. |
| `scripts/refresh_dashboard.py` | Runs the queries, validates, swaps the 3 constants atomically, backs up, logs. |
| `scripts/refresh_and_publish.sh` | Daily job wrapper (refresh then hub publish). |
| `scripts/push_to_hub.js`, `scripts/package.json` | Hub upsert (Node `pg`). `scripts/node_modules` is git-ignored. |
| `.env` / `.env.example` | Credentials (git-ignored) / placeholder template. |
| `requirements.txt` | python-dotenv, psycopg2-binary. |
| `README.md` | Main project doc (current). |
| `data-maps/TABLE_MAP.md` | LEDSone tables, keys, traps. |
| `validation/ledsone-migration.md` | Current migration and old-vs-new validation evidence. `validation/reconciliation.md` and `validation/env-migration-validation.md` are historical (D01). |
| `workflows/REFRESH_WORKFLOW.md` | Refresh/publish workflow. |
| `closure/SIGN_OFF.md` | Original D01 acceptance record plus current-state note. |
| `capability/CAPABILITY.md` | What the report can and cannot answer. |
| `duplicate-risk-reports/DR-001-ebay-sku-join-fanout.md` | eBay join fan-out rule. |
| `handover/message-to-DWC.md` | Historical (2026-07-14) message raising DR-001. Kept because `closure/SIGN_OFF.md` links to it. |
| `daily_works_logs/` | Dated D01-D03 work records and daily-activities CSV (historical, not maintained after 2026-07-17). |
| `skills/` | Legacy docs describing the OLD `order_management_copy` schema; do not use. |
| `backups/`, `logs/` | Runtime artefacts (git-ignored): timestamped HTML backups per run; `dashboard_refresh.log`, `hub_publish.log`, `cron.out`. |
| `evidence/`, `query-packs/`, `prompts/`, `documentation/` | Investigation evidence, ad-hoc queries, prompts, original brief. |

## 5. Data Sources / Database Tables

Data source: LEDSone PostgreSQL (`ledsone`, TLS required, `sslmode=require`), read-only use via `PG*` env vars.

| Used for | Table |
|---|---|
| Amazon returns | `customer_service.amazon_returns` |
| eBay returns (filter `res_his_order = 0`) | `customer_service.ebay_returns` |
| Amazon listings (asin) | `listings.amazon_listings` |
| eBay listings (item_id) | `listings.ebay_listings` |
| eBay SKU bridge (2 hops: `ebay_returns.order_id` to `orders.order_id` to `orders.id` to `order_item_info.order_id` + `item_id` to `item_sku`) | `order_management.orders`, `order_management.order_item_info` |
| Amazon marketplace name | `order_management.market_place` (via `orders.market_place`) |

Hub publish target: table `varman_aios.hub_pages` on the hub database (a DIFFERENT database from LEDSone), via `HUB_PG*` env vars. Row: member_name `sarujanan`, page_slug `returns-reason-hotspot-report`, title "Returns Reason Hotspot Report" (hub row id 13 per the 2026-10-05 log).

Env var names (in the project `.env`, git-ignored, chmod 600): `PGHOST, PGPORT, PGDATABASE, PGUSER, PGPASSWORD, PGSSLMODE` (LEDSone) and `HUB_PGHOST, HUB_PGPORT, HUB_PGDATABASE, HUB_PGUSER, HUB_PGPASSWORD` (hub). No fallback credentials exist in code.

The previous source was the old `order_management_copy` DB (tables in `public.*`); it is no longer used by this project.

## 6. Current Workflow / Architecture

```
cron 10:00 -> scripts/refresh_and_publish.sh
  stage 1: scripts/refresh_dashboard.py
     read .env -> run 6 queries (sql/returns_hotspot_queries.sql) on LEDSone
     -> sanity row-count floors (MIN_ROWS) -> structural fingerprint check
     -> backup to backups/index.<timestamp>.html -> atomic write (os.replace)
        of const DATA / const MISMATCH / const GENERATED_AT in Dashboard/index.html
  stage 2 (only if stage 1 exit 0): HTML size >= 100000 bytes, 3 markers present,
     build hub URL from HUB_PG* -> node scripts/push_to_hub.js (upsert hub_pages)
```

Guarantees: on any failure the previous dashboard is left intact and the job exits non-zero (fail-closed); a zero-row or suspiciously small query result is refused; two runs on the same data produce identical data blocks; the DB URL is redacted from logs. All HTML/CSS/JS is preserved byte-for-byte, so UI changes must be made by editing `Dashboard/index.html` directly (the refresh does not regenerate it).

## 7. How to Run

```bash
cd /home/led-247/Returns-Reason-Hotspot-Report
pip install -r requirements.txt           # or: sudo apt install python3-dotenv python3-psycopg2
cd scripts && npm install pg && cd ..     # hub publish dependency
cp .env.example .env && chmod 600 .env    # then fill in real values (obtain from the owner / secure store)

python3 scripts/refresh_dashboard.py      # refresh only (writes Dashboard/index.html)
scripts/refresh_and_publish.sh            # full job: refresh + hub publish
```

View the result by opening `Dashboard/index.html` in a browser. Both commands write to production files / the hub; run only intentionally.

## 8. Refresh / Deployment Process

- Schedule (installed in the developer's user crontab, verified 2026-10-05):
  `0 10 * * * /home/led-247/Returns-Reason-Hotspot-Report/scripts/refresh_and_publish.sh >> /home/led-247/Returns-Reason-Hotspot-Report/logs/cron.out 2>&1`
- The cron lives on the `led-247` user account of the developer's machine. The backup owner must keep that crontab or re-install the entry elsewhere; no systemd timer, Vercel or n8n job exists for this project (none found).
- Deployment = hub upsert of the HTML into `varman_aios.hub_pages` (member `sarujanan`, slug `returns-reason-hotspot-report`); the same slug updates in place. The script only writes that member's row.
- Check results: `logs/dashboard_refresh.log`, `logs/hub_publish.log`, `logs/cron.out`.
- Rollback: copy a file from `backups/` over `Dashboard/index.html`, then run the publish stage (or wait for the next run, which re-queries live data).

## 9. Validation Completed

- D01 (2026-07-14): 4 queries against real data, 2,106 rows reconciled; 0 external refs in HTML; sort order verified; eBay SKU total reconciles to eBay Reasons total after the DR-001 join fix (`validation/reconciliation.md`, `closure/SIGN_OFF.md`).
- D02/D03 (2026-07-15/16): Mismatch Candidates and auto-refresh verified (`daily_works_logs/`, `evidence/`).
- LEDSone migration (2026-09-14): source mapping, semantic compatibility, six-query validation, old-vs-new comparison, business-logic preservation, live cut-over, and post-migration data validation (`validation/ledsone-migration.md` sections 1-9).
- Operational: refresh log shows 58 SUCCESS runs; hub publish confirmed OK on 2026-10-05.
- Not re-validated by this handover: figures were not re-queried; status is taken from code, docs and logs.

## 10. Known Issues / Dependencies

1. eBay "Units" under-counts (open bug, MEDIUM). On LEDSone `ebay_returns.return_qty` is an integer, so the even-split `return_qty / GREATEST(n,1)` in `ebay_skus` does integer division (units about 631 shown as about 604). Refunds and counts are unaffected. Fix: cast `r.q::numeric / GREATEST(m.n,1)`. Not applied pending sign-off (see `validation/ledsone-migration.md` section 9).
2. Amazon refund coverage gap (HIGH, data issue): about 43% of Amazon returns have NULL `refunded_amount`, so "Total Returns" beside "Total Refund" can mislead. Suggested fix: a one-line caption; not applied.
3. Credential exposure: the hub-DB credential (`temp_user`) was exposed in plaintext earlier, still appears in git history (commit `90d3f1a`) and in `validation/env-migration-validation.md`, and is the active hub-publish credential. Rotate it, update the hub password variable in `.env`, and consider purging history. (Value deliberately not reproduced here.)
4. DWC has not ratified the three SQL deviations from his brief (currency grouping, `order_id + item_id` join, `CR-` strip), nor the Mismatch thresholds/Amazon signal. The "snapshot disclaimer" was removed from the header on explicit instruction (a footer "Snapshot only" chip remains).
5. Historical failures (fail-closed, dashboard stayed intact): 2026-07-31 `amazon_reasons` returned 0 rows (refused); 2026-09-15 LEDSone "too many connections for role". Transient; later runs succeeded.
6. The docstring in `scripts/refresh_dashboard.py` still mentions a 09:00 schedule; the actual schedule is 10:00 (cosmetic).
7. Dependencies: LEDSone DB availability and connection limits; hub DB reachability; Python 3 with python-dotenv and psycopg2; Node with `pg`; cron on the `led-247` host.
8. Hardcoded: Mismatch thresholds (3 / 40%), `AMZ-PG-BAD-DESC`, 3-month window. A hub or LEDSone move requires updating the `HUB_PG*` / `PG*` vars.

## 11. Backup Person / Owner

Backup person: Not documented. Documented parties: developer/owner Sarujanan (leaving); requester/business owner DWC (sign-off pending on deviations); data owner for LEDSone and hub DB access: Not documented (check with the DB administrators).

## 12. Troubleshooting

| Symptom | Check / action |
|---|---|
| Dashboard not updating | `tail logs/dashboard_refresh.log logs/hub_publish.log logs/cron.out`; confirm the crontab entry exists (`crontab -l`). |
| Missing env var, exit 1 | Fill the named variable in `.env` (see `.env.example`). Dashboard is untouched. |
| `too many connections for role` | LEDSone connection limit; wait and re-run `scripts/refresh_and_publish.sh`. |
| "returned 0 rows" / below sanity floor | Likely a broken filter or source-table change; inspect the named query in `sql/returns_hotspot_queries.sql` against LEDSone before touching `MIN_ROWS`. |
| Structural fingerprint abort | Something besides the 3 data constants changed; do not bypass, diff against `backups/`. |
| Publish SKIPPED (hub vars missing, file too small, markers missing) | Fix the hub vars in `.env` or the HTML; the stage 1 result is kept locally. |
| Hub shows stale page | Confirm the last "stage 2 publish: OK" line in `logs/hub_publish.log`; re-run `scripts/refresh_and_publish.sh`. |
| Bad HTML | Restore from `backups/`. |

## 13. Final Handover Notes

- The current code is the source of truth; `skills/` and the D01 files are historical.
- Handover file status: `handover/message-to-DWC.md` is historical and left in place (referenced by `closure/SIGN_OFF.md`); this file is the canonical handover. An old partition copy exists at `/home/led-247/Task_Work_Partition/Returns-Reason-Hotspot-Report -v1-correct` (July snapshot, pre-LEDSone); ignore it.
- First actions for the backup: obtain `.env` values securely, rotate the hub credential, confirm cron is running on the host, decide on the eBay Units cast and the Amazon coverage caption, and get DWC sign-off on the deviations and thresholds.
- `Dashboard/index.html` regenerates every day; commit it only if desired.
