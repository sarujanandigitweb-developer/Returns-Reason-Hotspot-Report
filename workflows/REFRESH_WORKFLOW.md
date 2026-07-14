# Workflow — refreshing and maintaining the dashboard

## Daily automated refresh

```
cron (09:00)
  -> scripts/refresh_dashboard.py
       -> load .env                          (fails loudly if any var is missing)
       -> connect PostgreSQL                 (read-only session, 120s statement timeout)
       -> parse sql/returns_hotspot_queries.sql  (split on "-- name:" markers)
       -> run 4 queries
       -> row-count floors                   (refuses a suspiciously small result)
       -> group rows by currency -> JSON
       -> swap ONLY `const DATA = {...}` + GENERATED_AT in the HTML
       -> structural fingerprint before/after (aborts if anything else moved)
       -> back up the old file -> backups/
       -> atomic write (os.replace)
       -> append to logs/dashboard_refresh.log
```

Any failure at any step: rollback, log the full error, **leave the previous dashboard
completely untouched**, exit 1.

## Run it manually

```bash
python3 scripts/refresh_dashboard.py
```

Works from any working directory — it resolves paths from its own location, which is why cron
(running from `$HOME`) works.

## Cron

```cron
0 9 * * * /usr/bin/python3 /home/led-247/Returns-Reason-Hotspot-Report/scripts/refresh_dashboard.py >> /home/led-247/Returns-Reason-Hotspot-Report/logs/cron.out 2>&1
```

---

## Changing a query

1. Edit `sql/returns_hotspot_queries.sql`. **Keep the `-- name:` markers** — the script splits on them.
2. **Keep the column order.** Each query's columns map positionally into the dashboard's row
   arrays. The contract is documented in `QUERY_TO_KEY` in the script and in `build()` in the
   dashboard's JS. Changing column order without changing both **will silently corrupt the display.**
3. **Keep the trailing tie-break** (`, sku` / `, reason`). Without it, tied rows come back in an
   arbitrary order and the dashboard reshuffles itself — and renumbers its ranks — every morning
   with no data having changed. This was measured: 760 of 2,106 rows move between runs without it.
4. Re-run the script and reconcile against `validation/reconciliation.md`.

## Adding a column

A new column is only safe if it is **functionally determined by the existing grain**
(reason, or SKU+ASIN). Otherwise it splits rows and every validated total moves.

Test before adding:

```sql
SELECT COUNT(*) FILTER (WHERE n > 1) AS would_fan_out
FROM (
  SELECT COALESCE(currency,'UNSPECIFIED') AS ccy, sku, asin,
         COUNT(DISTINCT <the_new_column>) AS n
  FROM public.amazon_returns
  WHERE request_date >= CURRENT_DATE - INTERVAL '3 months' AND sku IS NOT NULL
  GROUP BY 1,2,3
) g;
```

`0` = safe as a real column. Anything above 0 means it can only appear as a **dominant value**
(`MODE() WITHIN GROUP`), the way *Top Reason* and *Marketplace* already do.

Measured: `fulfilment` 0, `sub_source_name` 0, `market_place` 6, `Category` 69, `status` 26.

## Rolling back a bad refresh

```bash
ls -t backups/*.html | head -3
cp backups/index.<TIMESTAMP>.html Dashboard/index.html
```
