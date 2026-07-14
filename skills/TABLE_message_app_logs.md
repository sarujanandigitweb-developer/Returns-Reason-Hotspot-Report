# Table Definition: `message.message_app_logs`

## ⚠️ Execution Requirement
After generating any SQL against this table, **always execute it immediately using `postgres:execute_sql`** and return the real query results to the user. Never present a SQL query alone as the final answer.

---

## Purpose
Application activity/audit log for the message app. Each row records one user or system action on a given date — which channel (`source`), which store (`sub_source`), what happened (`action`), optional payload (`data`), and who performed it (`user`). Use for tracing support actions, debugging workflows, and reporting activity by date, channel, or store.

---

## Schema

**Table:** `message.message_app_logs`

| Column | Type | Description |
|--------|------|-------------|
| `id` | bigint | Primary key — may be NULL |
| `date` | date | Log date — may be NULL |
| `source` | double precision | Channel / platform code — see Source Reference below |
| `sub_source` | double precision | Store account id (`sub_source.sub_source`) — may be NULL |
| `action` | text | Action name or code (app-defined) — may be NULL |
| `data` | text | Optional payload (JSON or plain text) — may be NULL |
| `user` | bigint | User id who performed the action — FK to `public.user."user"` — may be NULL |

---

## Source Reference

| `source` | Channel |
|---|---|
| `1` | Amazon |
| `2` | eBay |
| `3` | Shopify |

> Filter `source` together with `sub_source` when scoping to a specific store account.

---

## Key Business Rules

- **One row = one logged action** in the message app
- **`date`** is the business log date (date only, not timestamp) — filter with `date = :target_date` or a date range
- **`source`** identifies marketplace channel; pair with `sub_source` for store-level reporting
- **Sub-source filter — always use `=`, never `LIKE`**: When filtering by `sub_source`, always use exact match (`=`). Using `LIKE` risks matching REPLACEMENT/RESEND suffix variants and unrelated store accounts.
- **`action`** values are defined by the application — use exact match or `ILIKE` when searching
- **`data`** may contain JSON or free text — parse or search with `ILIKE` as needed
- **`user`** is the internal user id; NULL for system/automated actions
- **No direct join to message bodies** — this table logs app events, not individual `ebay_msg` / `amz_msg` / `shopify_msg` rows (unless `data` references ids)

---

## Common Query Patterns

### Logs for a specific date
```sql
SELECT id, date, source, sub_source, action, data, "user"
FROM message.message_app_logs
WHERE date = :target_date
ORDER BY id DESC;
```

### Logs by channel (source)
```sql
SELECT id, date, sub_source, action, data, "user"
FROM message.message_app_logs
WHERE source = :source
  AND date = :target_date
ORDER BY id DESC;
```

### Logs by store (sub_source)
```sql
SELECT id, date, source, action, data, "user"
FROM message.message_app_logs
WHERE sub_source = :sub_source
  AND date >= :from_date
  AND date <= :to_date
ORDER BY date DESC, id DESC;
```

### Logs by action name
```sql
SELECT id, date, source, sub_source, data, "user"
FROM message.message_app_logs
WHERE action = :action
ORDER BY date DESC, id DESC
LIMIT 200;
```

### Logs by user
```sql
SELECT id, date, source, sub_source, action, data
FROM message.message_app_logs
WHERE "user" = :user_id
ORDER BY date DESC, id DESC
LIMIT 200;
```

### Action volume by date and channel
```sql
SELECT date, source, action, COUNT(*) AS log_count
FROM message.message_app_logs
WHERE date >= :from_date
  AND date <= :to_date
GROUP BY date, source, action
ORDER BY date DESC, log_count DESC;
```

### Search in data payload
```sql
SELECT id, date, source, sub_source, action, data, "user"
FROM message.message_app_logs
WHERE data ILIKE '%' || :search_text || '%'
ORDER BY date DESC, id DESC
LIMIT 100;
```

### Recent logs (last N rows)
```sql
SELECT id, date, source, sub_source, action, "user"
FROM message.message_app_logs
ORDER BY id DESC
LIMIT 50;
```

### Logs with store name (join sub_source)
```sql
SELECT l.id, l.date, l.source, l.sub_source, ss.ss_name,
       l.action, l.data, l."user"
FROM message.message_app_logs l
LEFT JOIN sub_source ss ON ss.sub_source = l.sub_source
WHERE l.date = :target_date
ORDER BY l.id DESC;
```

---

## Samples

```sql
-- Sample: all eBay app logs on a date
SELECT id, sub_source, action, data, "user"
FROM message.message_app_logs
WHERE source = 2
  AND date = '2026-05-28'
ORDER BY id DESC;
```

```sql
-- Sample: Amazon logs for one store
SELECT id, date, action, "user"
FROM message.message_app_logs
WHERE source = 1
  AND sub_source = 8
  AND date BETWEEN '2026-05-01' AND '2026-05-28'
ORDER BY date DESC, id DESC;
```

```sql
-- Sample: count actions per channel for a day
SELECT source, action, COUNT(*) AS log_count
FROM message.message_app_logs
WHERE date = '2026-05-28'
GROUP BY source, action
ORDER BY source, log_count DESC;
```

```sql
-- Sample: find logs mentioning an order id in data
SELECT id, date, source, sub_source, action, data
FROM message.message_app_logs
WHERE data ILIKE '%LED47176%'
ORDER BY date DESC
LIMIT 50;
```

---

## Bridge to Other Tables

| Target Table | Join Key | Notes |
|---|---|---|
| `public.sub_source` | `message_app_logs.sub_source = sub_source.sub_source` | Resolve store name (`ss_name`); filter `ss_source` by channel when needed (`1` Amazon, `2` eBay, `3` Shopify) |
| `public.user` | `message_app_logs."user" = "user"."user"` | Resolve user name (`user_firstname`, `user_name`) and status (`user_status`) for the actor who performed the action |

### Logs with user name (join public.user)
```sql
SELECT l.id, l.date, l.source, l.sub_source,
       l.action, l.data,
       u.user_firstname, u.user_name
FROM message.message_app_logs l
LEFT JOIN public."user" u ON u."user" = l."user"
WHERE l.date = :target_date
ORDER BY l.id DESC;
```

---

## Reference Lists

**Sources (`source`):** `1` = Amazon, `2` = eBay, `3` = Shopify

**Columns often NULL:** `date`, `source`, `sub_source`, `action`, `data`, `user` — always handle NULLs in filters and aggregates
