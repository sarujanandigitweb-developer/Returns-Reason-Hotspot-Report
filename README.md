# Returns Reason Hotspot Report

**Deliverable:** [`Dashboard/index.html`](Dashboard/index.html) — one self-contained file (CSS + JS + data all embedded, no external dependencies). Open it in any browser.

Answers *"Which products are being returned the most, why, and how much is it costing us?"* for Amazon and eBay, last 3 months, kept strictly separate.

---

## Daily refresh

The dashboard is a snapshot. [`scripts/refresh_dashboard.py`](scripts/refresh_dashboard.py) re-runs the four queries in [`sql/returns_hotspot_queries.sql`](sql/returns_hotspot_queries.sql) against PostgreSQL and rewrites **only** the embedded data block — all HTML, CSS and JavaScript are preserved byte-for-byte.

### Setup (once)

**1. Install the dependencies**

```bash
pip install python-dotenv psycopg2-binary
```

On Debian/Ubuntu, `pip` may refuse to install system-wide (PEP 668). Either use the packaged versions:

```bash
sudo apt install python3-dotenv python3-psycopg2
```

…or install into a virtualenv, and point the cron job at that interpreter.

**2. Create your `.env` from the template**

```bash
cp .env.example .env
```

**3. Fill in the credentials**

Edit `.env` and set the real `PGPASSWORD`:

```ini
PGHOST=149.28.134.54
PGPORT=5435
PGDATABASE=order_management_copy
PGUSER=temp_user
PGPASSWORD=<the real password>
```

Then lock it down: `chmod 600 .env`

`.env` is gitignored and **must never be committed**. `.env.example` is the committed template and must never contain a real password. There are no fallback credentials in the script — if any variable is missing it prints the missing name, refuses to connect, and exits 1 without touching the dashboard.

### Run it manually

```bash
python3 scripts/refresh_dashboard.py
```

### Schedule it daily at 09:00

```cron
0 9 * * * /usr/bin/python3 /home/led-247/Returns-Reason-Hotspot-Report/scripts/refresh_dashboard.py >> /home/led-247/Returns-Reason-Hotspot-Report/logs/cron.out 2>&1
```

Install with `crontab -e`. The script has no loop — cron owns the schedule. It resolves its own paths, so it runs correctly from any working directory (cron runs jobs from `$HOME`).

### What it guarantees

- The dashboard is overwritten **only** after all four queries succeed and pass row-count floors. A query returning zero — or suspiciously few — rows is treated as a broken filter and refused, not written.
- A structural fingerprint is compared before/after; if anything other than the data block moved, the write is aborted.
- The write is atomic (`os.replace`), so a crash can't leave a truncated file.
- Every run keeps a timestamped backup in `backups/` and appends to `logs/dashboard_refresh.log` (start, finish, duration, rows, success/failure, full error).
- Any failure — bad credentials, unreachable host, missing `.env` — leaves the previous dashboard **completely intact** and exits non-zero.

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
