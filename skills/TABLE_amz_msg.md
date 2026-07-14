# Table Definition: `message.amz_msg`

## ⚠️ Execution Requirement
After generating any SQL against this table, **always execute it immediately using `postgres:execute_sql`** and return the real query results to the user. Never present a SQL query alone as the final answer.

---

## Purpose
Customer support message inbox for the Amazon channel. Each row is one inbound Amazon buyer-seller message or email — sender, subject, order/ASIN context, classification, and body text. Built from the application `amz_msg` table joined with `sub_source` for store account names. Use this table for all Amazon message queries — query it directly where possible.

---

## Schema

| Column | Type | Description |
|--------|------|-------------|
| `id` | bigint | Primary key |
| `message_id` | text | Unique message id from Amazon / mail sync |
| `sub_source` | bigint | Amazon account numeric id (`sub_source.sub_source`) |
| `ss_name` | text | Amazon store account name (from `sub_source`) |
| `from_msg` | text | Sender email or Amazon messaging identifier |
| `from_name` | text | Sender display name |
| `subject` | text | Message subject line |
| `date` | timestamp | Date and time the message was received |
| `body_preview` | text | Short preview of the message body (truncated) |
| `order_id` | text | Marketplace order id linked to this message — may be NULL |
| `asin` | text | Amazon ASIN for the listing context — may be NULL |
| `message_content` | text | Full plain-text content of the message |
| `message_type` | text | Auto-classified message category — see Message Type Reference below |
| `extraction_method` | text | How the content was extracted (e.g. `plain-text-extract`) |
| `is_resolved` | bigint | Resolution flag: `1` = resolved, `0` = unresolved |
| `no_reply` | bigint | Reply-needed flag: `1` = no reply needed, `0` = reply expected/required |
| `root_cause` | text | Root cause label — LLM suggestion or manually set; **treat as unconfirmed unless a matching `root_cause_confirmed` log exists in `message.message_app_logs`** |

---

## Message Type Reference

| `message_type` | What it means |
|---|---|
| `Question` | Customer asking a product or order question |
| `General` | General enquiry not fitting other categories |
| `Shipping` | Delivery issues — damaged, lost, delayed items |
| `Cancellation` | Customer requesting to cancel their order |
| `Return` | Customer requesting a return or refund |
| `Complaint` | Formal complaint about product or service |

---

## Key Business Rules

- **Amazon channel only** — all rows are Amazon messages; `ss_name` is always an Amazon store name
- **Sub-source / store name filter — always use `=`, never `LIKE`**: When filtering by `ss_name`, always use exact match (`=`). Using `LIKE` risks matching REPLACEMENT/RESEND suffix variants and cross-platform name overlaps.
- **One row = one customer message** — thread replies each get their own row; link threads by `order_id` and/or `asin`
- **Customer-only filter** — exclude internal/system messages using `from_msg` and `from_name` exclusions (see Customer Message Count section below)
- **`order_id`** links to `order_transaction.order_id` — may be NULL for non-order messages
- **`asin`** is the listing key — joins to product/listing tables on ASIN / `ref_id`
- **`is_resolved = 0`** = open/unresolved message requiring action
- **`no_reply = 1`** = no reply needed — exclude from reply queues (thank-you, acknowledgment, conversation-ending)
- **`no_reply = 0`** = reply is expected — include when identifying messages that still need a response
- **`root_cause`** is mostly NULL — populated by LLM suggestion or manually after investigation
- **`root_cause` confirmation rule** — a non-NULL `root_cause` value may be an LLM suggestion and is **not confirmed** until a corresponding row exists in `message.message_app_logs` with `action = 'root_cause_confirmed'` and `(data::jsonb->>'message_row_id')::bigint = amz_msg.id`. When reporting root causes: show confirmed value if the log row exists; otherwise report as **"LLM suggestion (not confirmed)"**. Never surface an unconfirmed `root_cause` as a fact.
- **Date filter** — use `date` column for received-day reporting and sorting
- **Customer thread grouping** — when the user asks for a specific customer's message thread(s), filter by `from_msg` and/or `from_name`, then group messages using this priority:
  1. `order_id` and `asin` both present → one thread per `from_msg` + `order_id` + `asin` + `subject`
  2. `order_id` only → one thread per `from_msg` + `order_id` + `subject`
  3. `asin` only (no `order_id`) → one thread per `from_msg` + `asin` + `subject`
  4. neither `order_id` nor `asin` → one thread per `from_msg` + `subject`

---

## Customer Message Count by Date

For **counting customer messages by date**, use the pattern below. This excludes Amazon system/notification senders via `from_msg` and `from_name` filters.

```sql
-- Customer message count for a given day
SELECT COUNT(*) AS amazon_inbound_count
FROM message.amz_msg a
WHERE a.date >= ':target_date 00:00:00'
  AND a.date <= ':target_date 23:59:59'
  AND (
    (a.from_msg IS NULL OR LOWER(TRIM(a.from_msg)) <> 'amazon.co.uk')
    AND
    (
      a.from_name IS NULL
      OR LOWER(TRIM(a.from_name)) NOT IN (
        'amazon.co.uk',
        'amazon seller central notifications (do not reply)'
      )
    )
  );
```

**Why this pattern:**
- `from_msg <> 'amazon.co.uk'` — excludes Amazon system emails by sender address
- `from_name NOT IN (...)` — excludes Amazon notification senders by display name
- `date` range — use full day range `00:00:00` to `23:59:59` for date filtering
- Both `from_msg` and `from_name` checks handle NULL safely so no rows are accidentally dropped

---

## Common Query Patterns

### Unresolved messages requiring a reply
```sql
SELECT id, from_name, from_msg, subject, order_id, asin,
       message_type, date
FROM message.amz_msg
WHERE is_resolved = 0
  AND no_reply = 0
ORDER BY date ASC;
```

### Customer-only messages by date
```sql
SELECT id, from_name, from_msg, subject, order_id, asin,
       message_type, date, message_content
FROM message.amz_msg am
WHERE am.date >= ':target_date 00:00:00'
  AND am.date <= ':target_date 23:59:59'
  AND (
    (am.from_msg IS NULL OR LOWER(TRIM(am.from_msg)) <> 'amazon.co.uk')
    AND
    (
      am.from_name IS NULL
      OR LOWER(TRIM(am.from_name)) NOT IN (
        'amazon.co.uk',
        'amazon seller central notifications (do not reply)'
      )
    )
  )
ORDER BY am.date DESC, am.id DESC;
```

### Unresolved messages by store
```sql
SELECT ss_name, COUNT(*) AS unresolved_count
FROM message.amz_msg
WHERE is_resolved = 0
GROUP BY ss_name
ORDER BY unresolved_count DESC;
```

### Full message by id
```sql
SELECT id, message_id, from_msg, from_name, subject,
       order_id, asin, ss_name, message_type,
       date, is_resolved, no_reply, root_cause, message_content
FROM message.amz_msg
WHERE id = :message_id;
```

### All messages for a specific order
```sql
SELECT id, from_name, from_msg, subject, asin, message_content,
       message_type, date, is_resolved
FROM message.amz_msg
WHERE order_id = :order_id
ORDER BY date ASC;
```

### Messages for a specific ASIN
```sql
SELECT id, from_name, from_msg, subject, order_id,
       message_type, date, is_resolved, message_content
FROM message.amz_msg
WHERE asin = :asin
ORDER BY date DESC, id DESC;
```

### Message volume by type
```sql
SELECT message_type, COUNT(*) AS total
FROM message.amz_msg
GROUP BY message_type
ORDER BY total DESC;
```

### Customer message threads (grouped)
```sql
-- Step 1: list distinct threads for a customer
SELECT from_msg, from_name, order_id, asin, subject,
       COUNT(*) AS message_count,
       MIN(date) AS first_message_at,
       MAX(date) AS last_message_at
FROM message.amz_msg
WHERE from_msg = :from_msg
GROUP BY from_msg, from_name, order_id, asin, subject
ORDER BY last_message_at DESC;
```

```sql
-- Step 2: all messages in a chosen thread (order_id + asin)
SELECT id, from_msg, from_name, order_id, asin, subject,
       message_type, date, message_content
FROM message.amz_msg
WHERE from_msg = :from_msg
  AND order_id = :order_id
  AND asin = :asin
  AND subject = :subject
ORDER BY date ASC, id ASC;
```

```sql
-- Find customer by display name, then list threads
SELECT from_msg, from_name, order_id, asin, subject,
       COUNT(*) AS message_count,
       MAX(date) AS last_message_at
FROM message.amz_msg
WHERE from_name ILIKE '%John Smith%'
GROUP BY from_msg, from_name, order_id, asin, subject
ORDER BY last_message_at DESC;
```

---

## Bridge to Other Tables

| Target Table | Join Key | Notes |
|---|---|---|
| `sub_source` | `amz_msg.sub_source = sub_source.sub_source` | Amazon store account details |
| `order_transaction` | `amz_msg.order_id = order_transaction.order_id` | Revenue, SKU, marketplace context |
| `listing_data` | `amz_msg.asin = listing_data.ref_id` | Listing title/SKU (shared product table) |
| `message.message_app_logs` | `(logs.data::jsonb->>'message_row_id')::bigint = amz_msg.id` AND `logs.action = 'root_cause_confirmed'` | Confirms whether `root_cause` was agent-approved; LEFT JOIN — no log row means unconfirmed |
| `message.phrases` | `TRIM(amz_msg.root_cause) = TRIM(phrases.phrase)` AND `phrases.send_type = 4` | Root cause category mapping; unmapped values → **Other** |


### Root cause with confirmation status
```sql
SELECT a.id, a.from_name, a.order_id, a.asin, a.ss_name,
       a.root_cause,
       CASE
         WHEN l.id IS NOT NULL THEN a.root_cause
         WHEN a.root_cause IS NOT NULL THEN 'LLM suggestion (not confirmed)'
         ELSE NULL
       END AS root_cause_display,
       l.date AS confirmed_at
FROM message.amz_msg a
LEFT JOIN message.message_app_logs l
  ON (l.data::jsonb->>'message_row_id')::bigint = a.id
  AND l.action = 'root_cause_confirmed'
WHERE a.root_cause IS NOT NULL
ORDER BY a.id DESC;
```

---

## Reference Lists

**Sub-Sources (`ss_name`):** amazon Cottage Lighting, amazon Dcvoltage, amazon Homin gmbh, amazon Ledsone, amazon Ledsonede, amazon RelicElectrical, amazon SRM Amazon, amazon Vintage light, DCV UK, Neighbour Market, vendor

**Message Types (`message_type`):** Question, General, Shipping, Cancellation, Return, Complaint

**Resolution Status (`is_resolved`):** `0` = Unresolved, `1` = Resolved

**Reply Status (`no_reply`):** `0` = Reply expected / needed, `1` = No reply needed (conversation-ending or similar)
