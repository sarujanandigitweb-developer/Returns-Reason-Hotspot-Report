# Returns Reason Hotspot Report

**Deliverable:** [`Dashboard/index.html`](Dashboard/index.html) — one self-contained file (CSS + JS + data all embedded, no external dependencies). Open it in any browser.

Answers *"Which products are being returned the most, why, and how much is it costing us?"* for Amazon and eBay, last 3 months, kept strictly separate — plus a **Mismatch Candidates** tab that flags listings whose returns come back specifically as "not as described" (a listing/photo problem, not a faulty product).

> **Data source:** as of **2026-09-14** the dashboard reads the **LEDSone PostgreSQL** database
> (`ledsone` @ `169.58.91.229:5432`, TLS required). It previously used `order_management_copy`
> @ `149.28.134.54`. See [validation/ledsone-migration.md](validation/ledsone-migration.md) for
> the full source-mapping and cut-over evidence.

---

## The dashboard at a glance

Five tabs, all in the one HTML file:

| Tab | Shows |
|---|---|
| Amazon — Return Reasons | reasons ranked by refund, per currency |
| Amazon — SKU Refund Analysis | every returning SKU (search / sort / paginate), top reason, marketplace |
| eBay — Return Reasons | same, eBay |
| eBay — SKU Refund Analysis | same, eBay (SKU resolved via the order bridge) |
| **Mismatch Candidates** | Amazon + eBay SKUs with a high concentration of "not as described" returns; 🔴 badge = the strict ≥3 returns **and** ≥40%-of-own-returns signal |

SKU tables show **all** rows with pagination (not a top-15). Currencies are never summed; Amazon and eBay are never combined.

---

## How the data gets in

Two embedded constants in the HTML hold all the data; the refresh rewrites them and nothing else:

- `const DATA` — the four main tables (Amazon/eBay × Reasons/SKUs)
- `const MISMATCH` — the Mismatch Candidates tab
- `const GENERATED_AT` — the snapshot date shown in the header

[`scripts/refresh_dashboard.py`](scripts/refresh_dashboard.py) runs the **six** queries in
[`sql/returns_hotspot_queries.sql`](sql/returns_hotspot_queries.sql) against LEDSone and swaps
**only** those three constants — all HTML, CSS and JavaScript are preserved byte-for-byte, checked
by a structural fingerprint.

The six queries: `amazon_reasons`, `amazon_skus`, `ebay_reasons`, `ebay_skus`,
`nad_amazon_candidates`, `nad_ebay_candidates`.

---

## Setup (once)

**1. Install dependencies** (Python for the refresh, Node `pg` for the hub publish)

```bash
pip install python-dotenv psycopg2-binary          # or: sudo apt install python3-dotenv python3-psycopg2 (PEP 668)
cd scripts && npm install pg && cd ..               # for the hub publish (scripts/refresh_and_publish.sh)
```

**2. Create your `.env`** from the template

```bash
cp .env.example .env
```

**3. Fill in the credentials** — `.env` holds **two** connections:

```ini
# Dashboard DATA source — LEDSone (the queries read this)
PGHOST=169.58.91.229
PGPORT=5432
PGDATABASE=ledsone
PGUSER=tech_user
PGPASSWORD=<the real password>
PGSSLMODE=require

# Hub PUBLISH target — the DB that holds varman_aios.hub_pages (a DIFFERENT database)
HUB_PGHOST=<hub db host>
HUB_PGPORT=5432
HUB_PGDATABASE=<hub db name>
HUB_PGUSER=<hub db user>
HUB_PGPASSWORD=<hub db password>
```

Then lock it down: `chmod 600 .env`. `.env` is gitignored and **must never be committed**;
`.env.example` is the committed template and must never contain a real password. There are no
fallback credentials — a missing variable makes the refresh print the missing name and exit 1
without touching the dashboard (the hub publish likewise skips rather than falling back).

---

## Run it

**Manually (refresh only):**

```bash
python3 scripts/refresh_dashboard.py
```

**The full daily job (refresh + publish to the hub):**

```bash
scripts/refresh_and_publish.sh
```

### Scheduled — daily at 10:00 (installed)

```cron
0 10 * * * /home/led-247/Returns-Reason-Hotspot-Report/scripts/refresh_and_publish.sh >> /home/led-247/Returns-Reason-Hotspot-Report/logs/cron.out 2>&1
```

`refresh_and_publish.sh` runs two stages: **(1)** `refresh_dashboard.py` (from LEDSone), then
**(2)** `scripts/push_to_hub.js`, which upserts the refreshed HTML into `varman_aios.hub_pages`
(member `sarujanan`, slug `returns-reason-hotspot-report`) so it appears on the Varman AIOS Hub.
Stage 2 runs **only if stage 1 succeeded**, and uses the separate `HUB_PG*` connection — see
[workflows/REFRESH_WORKFLOW.md](workflows/REFRESH_WORKFLOW.md).

### What the refresh guarantees

- The dashboard is overwritten **only** after all six queries succeed and pass row-count floors. A query returning zero — or suspiciously few — rows is refused, not written.
- A structural fingerprint is compared before/after; if anything other than the three data constants moved, the write is aborted.
- The write is atomic (`os.replace`); a crash can't leave a truncated file.
- Every run keeps a timestamped backup in `backups/` and appends to `logs/dashboard_refresh.log`; the hub stage logs to `logs/hub_publish.log`.
- Any failure leaves the previous dashboard **completely intact** and exits non-zero (fail-closed).
- The refresh is **deterministic** — two runs against the same DB state produce byte-identical data blocks.

---

## Business rules baked into the SQL (do not change lightly)

- **`res_his_order = 0` on `ebay_returns` is mandatory** — without it the window inflates ~10× from resolution-history rows.
- **eBay has no `sku`** — it is resolved via the order bridge on `order_id + item_id` (never `order_id` alone, which fans out; see [DR-001](duplicate-risk-reports/DR-001-ebay-sku-join-fanout.md)). Variation listings split the refund/units evenly; unmatched returns show as an explicit *Unattributed* row.
- **Currency is split, never summed**; **Amazon and eBay are never combined.**
- **Amazon `CR-` reason prefix is stripped** so one reason doesn't split across two rows.
- **Mismatch signal:** Amazon uses `AMZ-PG-BAD-DESC`, eBay uses `NOT_AS_DESCRIBED`; a SKU is badged when it has **≥3** such returns **and** they are **≥40%** of that SKU's own returns.
- **Deterministic ordering** — every query ends with a tie-break so ranks don't reshuffle between runs.

---

## Folders

| Folder | Holds |
|---|---|
| `sql/` | [The six queries as run](sql/returns_hotspot_queries.sql), mapped to LEDSone, deviations commented inline |
| `scripts/` | `refresh_dashboard.py` (refresh), `refresh_and_publish.sh` (daily job), `push_to_hub.js` (hub publish) |
| `validation/` | [LEDSone migration evidence](validation/ledsone-migration.md) (current); [reconciliation](validation/reconciliation.md) + [env migration](validation/env-migration-validation.md) (historical D01) |
| `duplicate-risk-reports/` | [DR-001](duplicate-risk-reports/DR-001-ebay-sku-join-fanout.md) — the eBay join fan-out rule |
| `data-maps/` | [TABLE_MAP.md](data-maps/TABLE_MAP.md) — the LEDSone tables, keys and traps |
| `capability/` | [CAPABILITY.md](capability/CAPABILITY.md) — what the report can and cannot answer |
| `documentation/`, `handover/` | The original task brief and the original build-time message to DWC (**historical**) |
| `daily_works_logs/` | Dated D01–D03 work records (**historical**, not maintained) |
| `skills/` | **Legacy** company table-reference docs describing the *old* `order_management_copy` schema — not the LEDSone schema this project now uses. Use [data-maps/TABLE_MAP.md](data-maps/TABLE_MAP.md) instead |
| `backups/`, `logs/`, `evidence/`, `query-packs/`, `prompts/`, `closure/` | Runtime artefacts and scaffolding |

---

## ⚠️ Open items for the next owner

1. **Rotate the hub-DB / `temp_user` password.** It was exposed in plaintext during earlier work and now serves as the **active hub-publish credential** (`HUB_PGPASSWORD`). It still appears in git history (commit `90d3f1a`) and in `validation/env-migration-validation.md`. Rotate it on the DB, update `HUB_PGPASSWORD` in `.env`, and consider purging it from history.
2. **Hub location:** the hub table `varman_aios.hub_pages` lives on the old/hub DB, **not** LEDSone. The publish is intentionally pointed there via `HUB_PG*`. If the hub site moves to LEDSone, update those vars.
3. **Amazon marketplace** is derived (returns carry no marketplace) via `orders.market_place` → `order_management.market_place.name`; ~16% of returns have no order header and show `UNSPECIFIED` — expected, never invented.
