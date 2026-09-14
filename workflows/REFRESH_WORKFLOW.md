# Workflow — refreshing, publishing and maintaining the dashboard

> Data source since 2026-09-14: **LEDSone** (`ledsone` @ 169.58.91.229:5432, TLS).
> The hub-publish target is a **separate** database (see stage 2).

## Daily automated job (cron, 10:00)

```
cron (10:00)  ->  scripts/refresh_and_publish.sh
  |
  |-- STAGE 1  scripts/refresh_dashboard.py
  |     -> load .env (PG* vars)             (fails loudly if any var is missing)
  |     -> connect LEDSone PostgreSQL       (read-only session, TLS, 120s statement timeout)
  |     -> parse sql/returns_hotspot_queries.sql  (split on "-- name:" markers)
  |     -> run 6 queries (4 main + 2 mismatch)
  |     -> row-count floors                 (refuses a suspiciously small result)
  |     -> group main rows by currency -> JSON; build MISMATCH rows (titles carried forward)
  |     -> swap ONLY const DATA + const MISMATCH + const GENERATED_AT in the HTML
  |     -> structural fingerprint before/after (aborts if anything else moved)
  |     -> back up the old file -> backups/ ; atomic write (os.replace)
  |     -> append to logs/dashboard_refresh.log
  |
  |-- STAGE 2  (only if stage 1 exited 0)  scripts/push_to_hub.js
        -> build HUB_DB_URL from .env HUB_PG* vars   (the HUB DB, NOT the LEDSone PG* connection)
        -> pre-publish sanity (HTML >= 100KB, has const DATA/MISMATCH/GENERATED_AT)
        -> upsert varman_aios.hub_pages (member 'sarujanan', slug 'returns-reason-hotspot-report')
        -> append to logs/hub_publish.log   (postgres URLs redacted)
```

Any failure at any step: log the full error, **leave the previous dashboard completely untouched**,
exit non-zero. A stage-1 failure skips stage 2 (nothing new to publish). A stage-2 failure means
the local dashboard is refreshed but the hub copy is not updated — fail-closed, never corrupt.

## Run pieces manually

```bash
python3 scripts/refresh_dashboard.py     # refresh only (writes Dashboard/index.html)
scripts/refresh_and_publish.sh           # full job: refresh + hub publish
```

Both resolve their own paths, so they run correctly from any working directory (cron runs from `$HOME`).

## Cron entry (installed)

```cron
0 10 * * * /home/led-247/Returns-Reason-Hotspot-Report/scripts/refresh_and_publish.sh >> /home/led-247/Returns-Reason-Hotspot-Report/logs/cron.out 2>&1
```

`crontab -l` to view. Keep it to **one** RRHD line; the wrapper (not the bare python script) is what cron calls.

---

## Two databases, two connections (important)

`.env` carries two independent connections; never mix them:

| Vars | Used by | Points at |
|---|---|---|
| `PG*` (`PGHOST`…`PGSSLMODE`) | stage 1 refresh | **LEDSone** — the returns/listings data source |
| `HUB_PG*` (`HUB_PGHOST`…`HUB_PGPASSWORD`) | stage 2 publish | the **hub DB** that holds `varman_aios.hub_pages` |

The refresh must never publish, and the publish must never read the data source. If `HUB_PG*` is
missing, stage 2 is skipped (it does **not** fall back to the LEDSone connection).

---

## Changing a query

1. Edit `sql/returns_hotspot_queries.sql`. **Keep the `-- name:` markers** — the script splits on them.
2. **Keep the column order / aliases.** Main-query columns map positionally into the dashboard row arrays (`QUERY_TO_KEY` + `build()`); the `nad_*` queries map by column **name** into `build_mismatch_rows()`. Changing either without matching the other silently corrupts the display.
3. **Keep the trailing tie-break** (`, sku` / `, reason`) and the `DISTINCT ON` tie-breakers. Without them tied rows reshuffle and ranks renumber every run for no reason (measured on the old DB: 760 of 2,106 rows moved between runs).
4. Re-run and reconcile (validate against the LEDSone MCP or a manual `SELECT`).

## Adding a column

Safe only if **functionally determined by the existing grain** (reason, or SKU+ASIN). Otherwise it
splits rows and every total moves. Test on the current source:

```sql
SELECT COUNT(*) FILTER (WHERE n > 1) AS would_fan_out
FROM (
  SELECT COALESCE(currency,'UNSPECIFIED') AS ccy, sku, asin,
         COUNT(DISTINCT <the_new_column>) AS n
  FROM customer_service.amazon_returns
  WHERE request_date >= CURRENT_DATE - INTERVAL '3 months' AND sku IS NOT NULL
  GROUP BY 1,2,3
) g;
```

`0` = safe as a real column. Above 0 = it can only appear as a **dominant value** (`MODE() WITHIN GROUP`), the way *Top Reason* and *Marketplace* already do.

## Rolling back a bad refresh

```bash
ls -t backups/*.html | head -3
cp backups/index.<TIMESTAMP>.html Dashboard/index.html
```

To re-publish the rolled-back copy to the hub, run `scripts/refresh_and_publish.sh` (it will
re-refresh first) or call `push_to_hub.js` directly with the same slug.
