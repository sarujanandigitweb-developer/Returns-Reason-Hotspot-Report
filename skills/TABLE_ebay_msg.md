# Table Definition: `message.ebay_msg`

## ⚠️ Execution Requirement
After generating any SQL against this table, **always execute it immediately using `postgres:execute_sql`** and return the real query results to the user. Never present a SQL query alone as the final answer.

---

## Purpose
Pre-built eBay customer support message table. Each row is one complete eBay message — header metadata (buyer, listing, folder, read/reply flags, dates) joined with the message body text and the store account name. Built by the ETL pipeline from `messages_headers` + `ebay_messages` + `sub_source`. Use this table for all eBay message queries — query it directly, no joins to source tables needed.

---

## Schema

| Column | Type | Description |
|--------|------|-------------|
| `id` | bigint | Primary key |
| `message_id` | text | eBay message id string — sync upsert key |
| `ext_message_id` | double precision | eBay external message id |
| `sender_id` | text | Buyer eBay user id (inbox rows); seller sub_source id (sent rows) — maps to `customer_info.ci_ebay_buyer_id` |
| `receiver_id` | text | Counterparty on sent rows (buyer id when folder is sent) |
| `sub_source` | bigint | eBay account numeric id |
| `ss_name` | text | eBay store account name (e.g. `electricalsone`, `led_sone`) |
| `item_id` | text | eBay listing id — maps to `order_transaction.item_id` |
| `message_type` | text | eBay message type from API sync |
| `subject` | text | Subject — JSON-encoded from eBay API; decode for plain-text display |
| `read_status` | bigint | `1` = Read, `2` = Unread |
| `flagged` | bigint | `1` = Flagged, `2` = Not flagged |
| `reply_status` | bigint | `1` = Replied, `0` = Not replied yet |
| `no_reply` | bigint | `1` = No reply needed, `0` = Reply expected/required |
| `folder_id` | bigint | `0` = Inbox, `1` = Sent |
| `msg_sync_status` | bigint | `0` = Body pending, `1` = Body synced |
| `root_cause` | text | Root cause label — LLM suggestion or manually set; **treat as unconfirmed unless a matching `root_cause_confirmed` log exists in `message.message_app_logs`** |
| `response_date` | timestamp | Last response timestamp (used for list sorting) |
| `receive_date` | timestamp | Received timestamp |
| `message_content` | text | Message body text — JSON-encoded from eBay sync; NULL if body not yet synced |

---

## Key Business Rules

- **eBay channel only** — all rows are eBay messages; `ss_name` is always an eBay store name
- **Sub-source / store name filter — always use `=`, never `LIKE`**: When filtering by `ss_name`, always use exact match (`=`). Using `LIKE` risks matching REPLACEMENT/RESEND suffix variants and cross-platform name overlaps.
- **One row = one eBay message** — threads group by `item_id` + `sender_id`
- **Inbox filter** — `folder_id = 0`, `sender_id != 'eBay'`, `ext_message_id IS NOT NULL`
- **Reply queue** — `reply_status = 0` AND `no_reply = 0` = messages still needing a reply
- **No reply needed** — `no_reply = 1` excludes thank-you, acknowledgment, or conversation-ending messages; exclude from reply queues
- **Body pending** — `message_content` is NULL when `msg_sync_status = 0`; do not treat a NULL body as an error
- **Subject and body encoding** — both `subject` and `message_content` are JSON-encoded from the eBay API; decode for plain-text display
- **Thread sort** — `ORDER BY COALESCE(response_date, receive_date) DESC, id DESC`
- **Store filter** — use `ss_name` for human-readable store filtering (e.g. `WHERE ss_name = 'electricalsone'`)
- **`root_cause` confirmation rule** — a non-NULL `root_cause` value on a message may be an LLM suggestion and is **not confirmed** until a corresponding row exists in `message.message_app_logs` with `action = 'root_cause_confirmed'` and `(data::jsonb->>'message_row_id')::bigint = ebay_msg.id`. When reporting root causes: show confirmed value if the log row exists; otherwise report as **"LLM suggestion (not confirmed)"**. Never surface an unconfirmed `root_cause` as a fact.

---

## Customer Message Count by Date

For **counting customer messages by date**, use the pattern below on `message.ebay_msg`. This ensures correct store scoping and excludes seller/system accounts.

```sql
-- Customer message count by store for a given day
SELECT em.sub_source, COUNT(*) AS cnt
FROM message.ebay_msg em
WHERE em.sender_id <> 'eBay'
  AND em.ext_message_id IS NOT NULL
  AND em.response_date >= ':target_date 00:00:00'
  AND em.response_date <= ':target_date 23:59:59'
  AND em.sub_source::text IN (
      SELECT TRIM(ss.sub_source::text)
      FROM sub_source ss
      WHERE ss.ss_source = 2
        AND TRIM(ss.sub_source::text) <> ''
  )
  AND em.sender_id NOT IN (
      SELECT TRIM(ss.sub_source::text)
      FROM sub_source ss
      WHERE ss.ss_source = 2
        AND TRIM(ss.sub_source::text) <> ''
  )
GROUP BY em.sub_source
ORDER BY cnt DESC;
```

**Why this pattern:**
- `sub_source IN (...)` — restricts to known eBay store accounts only (`ss_source = 2`)
- `sender_id NOT IN (...)` — excludes messages sent by seller accounts (outbound/sent rows)
- `sender_id <> 'eBay'` — excludes eBay system messages
- `ext_message_id IS NOT NULL` — valid synced messages only
- `response_date` range — use for date filtering (not `receive_date`)
- Join `sub_source` on `sub_source.sub_source` to resolve `ss_name` for display

---

## Common Query Patterns

### Inbox messages requiring a reply
```sql
SELECT id, sender_id, item_id, ss_name, subject,
       receive_date, reply_status, no_reply, message_content
FROM message.ebay_msg
WHERE folder_id = 0
  AND sender_id != 'eBay'
  AND ext_message_id IS NOT NULL
  AND reply_status = 0
  AND no_reply = 0
ORDER BY COALESCE(response_date, receive_date) ASC;
```

### Full message by id
```sql
SELECT id, sender_id, receiver_id, item_id, ss_name,
       subject, message_type, folder_id, read_status,
       reply_status, no_reply, receive_date, response_date,
       root_cause, message_content
FROM message.ebay_msg
WHERE id = :message_id;
```

### Thread by buyer and listing
```sql
SELECT id, sender_id, receiver_id, message_type, subject,
       receive_date, response_date, reply_status, no_reply, message_content
FROM message.ebay_msg
WHERE item_id = :item_id
  AND (sender_id = :buyer OR receiver_id = :buyer)
ORDER BY COALESCE(response_date, receive_date) DESC, id DESC
LIMIT 12;
```

### Messages pending body sync
```sql
SELECT id, ext_message_id, sub_source, ss_name
FROM message.ebay_msg
WHERE msg_sync_status = 0
  AND ext_message_id IS NOT NULL
LIMIT 100;
```

### Messages by store account
```sql
SELECT id, sender_id, item_id, subject,
       receive_date, reply_status, no_reply, message_content
FROM message.ebay_msg
WHERE ss_name = 'electricalsone'
  AND folder_id = 0
ORDER BY COALESCE(response_date, receive_date) DESC;
```

### Unread inbox messages
```sql
SELECT id, sender_id, item_id, ss_name,
       subject, receive_date, message_content
FROM message.ebay_msg
WHERE folder_id = 0
  AND read_status = 2
ORDER BY receive_date DESC;
```

### Related order IDs for a message thread
```sql
SELECT DISTINCT ot.order_id
FROM message.ebay_msg em
INNER JOIN customer_info ci ON ci.ci_ebay_buyer_id = em.sender_id
INNER JOIN order_transaction ot
    ON ot.item_id = em.item_id
    AND ot.order_id = ci.ci_order_id
WHERE em.item_id = :item_id
  AND em.sender_id = :buyer;
```

---

## Bridge to Other Tables

| Target Table | Join Key | Notes |
|---|---|---|
| `sub_source` | `ebay_msg.sub_source = sub_source.sub_source` | eBay store account details (`ss_source = 2`) |
| `listing_data` | `ebay_msg.item_id = listing_data.ref_id` | Listing / SKU for the thread |
| `customer_info` | `ebay_msg.sender_id = customer_info.ci_ebay_buyer_id` | Buyer rows; one row per order via `ci_order_id` |
| `order_transaction` | `order_transaction.item_id = ebay_msg.item_id` AND `order_transaction.order_id = customer_info.ci_order_id` | Links message thread to order via item and buyer |
| `message.message_app_logs` | `(logs.data::jsonb->>'message_row_id')::bigint = ebay_msg.id` AND `logs.action = 'root_cause_confirmed'` | Confirms whether `root_cause` was agent-approved; LEFT JOIN — no log row means unconfirmed |
| `message.phrases` | `TRIM(ebay_msg.root_cause) = TRIM(phrases.phrase)` AND `phrases.send_type = 4` | Root cause category mapping; unmapped values → **Other** |


### Root cause with confirmation status
```sql
SELECT e.id, e.sender_id, e.item_id, e.ss_name,
       e.root_cause,
       CASE
         WHEN l.id IS NOT NULL THEN e.root_cause
         WHEN e.root_cause IS NOT NULL THEN 'LLM suggestion (not confirmed)'
         ELSE NULL
       END AS root_cause_display,
       l.date AS confirmed_at
FROM message.ebay_msg e
LEFT JOIN message.message_app_logs l
  ON (l.data::jsonb->>'message_row_id')::bigint = e.id
  AND l.action = 'root_cause_confirmed'
WHERE e.root_cause IS NOT NULL
ORDER BY e.id DESC;
```


---

## Reference Lists

**Folder (`folder_id`):** `0` = Inbox, `1` = Sent

**Read Status (`read_status`):** `1` = Read, `2` = Unread

**Flagged (`flagged`):** `1` = Flagged, `2` = Not flagged

**Reply Sent (`reply_status`):** `0` = Not replied yet, `1` = Replied

**Reply Needed (`no_reply`):** `0` = Reply expected / needed, `1` = No reply needed (conversation-ending or similar)

**Body Sync (`msg_sync_status`):** `0` = Pending (`message_content` NULL), `1` = Synced

**Store Accounts (`ss_name`):** led_sone, re6865, bestbringer, so_926407, dctransformer, electricalsone, lighting_sone, coventrylights, electro_shine, uk-lightsway, ledsonede, huettenlampen, vintageinterior, electbout0, koneswaransrikanesh, nanthinvasude-0, ur26574, cottagelighting, homin_gmbh, longtek020, ledpedia, neighbourmarket
