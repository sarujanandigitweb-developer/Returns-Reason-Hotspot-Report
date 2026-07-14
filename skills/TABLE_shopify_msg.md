# Table Definitions: `message.shopify_msg`

## ⚠️ Execution Requirement
After generating any SQL against these tables, **always execute it immediately using `postgres:execute_sql`** and return the real query results to the user. Never present a SQL query alone as the final answer.

---

## Purpose
Customer support message inbox for the Shopify channel. Each row represents a single inbound email or message sent by a customer regarding a Shopify order. Used for tracking customer enquiries, complaints, shipping issues, returns, and cancellations across all Shopify sub-sources. Supports resolution tracking, root cause analysis, and reply status monitoring.

---

## Schema

| Column | Type | Description |
|--------|------|-------------|
| `id` | bigint | Primary key |
| `message_id` | text | Unique email message ID (e.g. `<abc@mail.gmail.com>`) |
| `from_msg` | text | Sender email address |
| `from_name` | text | Sender display name |
| `to_msg` | text | Recipient email address (NULL if not captured) |
| `to_name` | text | Recipient display name (NULL if not captured) |
| `subject` | text | Email subject line |
| `body_preview` | text | Short preview of the message body (truncated) |
| `order_id` | text | Shopify order ID linked to this message (e.g. `LED47176`) — may be NULL |
| `message_content` | text | Full plain-text content of the message |
| `message_type` | text | Auto-classified message category — see Message Type Reference below |
| `extraction_method` | text | How the content was extracted (e.g. `plain-text-extract`) |
| `attachments` | text | JSON array of attachment URLs — `[]` if none |
| `date` | timestamp | Date and time the message was received |
| `sub_source` | bigint | Sub-source numeric ID |
| `ss_name` | text | Sub-source / store name (e.g. `ledsone`, `dcvoltage-2`) |
| `mail_id` | bigint | Mail account identifier |
| `is_resolved` | bigint | Resolution flag: `1` = resolved, `0` = unresolved |
| `root_cause` | text | Root cause label — LLM suggestion or manually set; **treat as unconfirmed unless a matching `root_cause_confirmed` log exists in `message.message_app_logs`** |
| `no_reply` | bigint | Reply-needed flag: `1` = no reply needed (e.g. conversation-ending or closing message), `0` = a reply is expected or required |

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

- **One row = one customer message** — thread replies each get their own row linked by `order_id`
- **Sub-source / store name filter — always use `=`, never `LIKE`**: When filtering by `ss_name`, always use exact match (`=`). Using `LIKE` risks matching REPLACEMENT/RESEND suffix variants and cross-platform name overlaps (e.g. `ledsone` exists on both Shopify and Faire).
- **`order_id`** links directly to `order_transaction.order_id` for order context — may be NULL for non-order messages
- **`is_resolved = 0`** = open/unresolved message requiring action
- **`no_reply = 1`** = no reply needed — message is informational or closes the thread (e.g. thank-you, acknowledgment); exclude from reply queues
- **`no_reply = 0`** = reply is expected — include when identifying messages that still need a response
- **`root_cause`** is mostly NULL — populated by LLM suggestion or manually after investigation
- **`root_cause` confirmation rule** — a non-NULL `root_cause` value may be an LLM suggestion and is **not confirmed** until a corresponding row exists in `message.message_app_logs` with `action = 'root_cause_confirmed'` and `(data::jsonb->>'message_row_id')::bigint = shopify_msg.id`. When reporting root causes: show confirmed value if the log row exists; otherwise report as **"LLM suggestion (not confirmed)"**. Never surface an unconfirmed `root_cause` as a fact.
- **`attachments`** is a JSON array stored as text — parse if image/file URLs are needed
- **`ss_name`** matches sub-source names used in `order_transaction` for cross-table consistency

---

## Customer Message Count by Date

For **counting customer messages by date**, use the pattern below. This excludes Shopify system mailers, AppScenic supplier emails, internal store mailbox emails, and LEDSone internal senders.

```sql
-- Customer message count for a given day
WITH shopify_mailbox_emails AS (
  SELECT DISTINCT LOWER(TRIM(to_msg)) AS email_norm
  FROM message.shopify_msg
  WHERE to_msg IS NOT NULL AND to_msg <> ''
    AND (
      LOWER(TRIM(to_msg)) LIKE 'admin@%'
      OR LOWER(TRIM(to_msg)) IN (
        'info@ledsone.co.uk', 'info@ledsone.fr', 'info@ledsone.de',
        'sales@ledsone.co.uk', 'german@ledsone.co.uk',
        'ledwebuk@gmail.com', 'ukelectricalsone@gmail.com',
        'relicelectrical4@gmail.com', 'development@vintageinterior.co.uk'
      )
    )
)
SELECT COUNT(*) AS shopify_inbound_count
FROM message.shopify_msg s
WHERE s.date >= ':target_date 00:00:00'
  AND s.date <= ':target_date 23:59:59'
  AND (s.from_name IS NULL OR s.from_name NOT LIKE '%AppScenic%')
  AND (
    s.from_name IS NULL
    OR LOWER(TRIM(COALESCE(s.from_name, ''))) NOT LIKE '%ledsone uk ltd%'
  )
  AND LOWER(TRIM(COALESCE(s.from_msg, ''))) NOT IN (
    SELECT email_norm FROM shopify_mailbox_emails
  )
  AND LOWER(TRIM(COALESCE(s.from_msg, ''))) NOT IN (
    'no-reply@mailer.shopify.com',
    'mailer@shopify.com'
  );
```

**Why this pattern:**
- `shopify_mailbox_emails` CTE — dynamically builds the list of known internal store mailboxes from `to_msg` (e.g. `admin@ledsone.co.uk`, `admin@dcvoltage.co.uk`) to exclude outbound/internal emails
- `from_name NOT LIKE '%AppScenic%'` — excludes AppScenic supplier notification emails
- `from_name NOT LIKE '%ledsone uk ltd%'` — excludes internal LEDSone sender display names
- `from_msg NOT IN (shopify_mailbox_emails)` — excludes emails sent from store mailboxes
- `from_msg NOT IN ('no-reply@mailer.shopify.com', 'mailer@shopify.com')` — excludes Shopify platform system emails
- `date` range — use full day range `00:00:00` to `23:59:59` for date filtering
- `mail_id` — available on the table for user-permission scoping if needed (app-layer filter only)

---

## Common Query Patterns

### Unresolved messages requiring a reply
```sql
SELECT id, from_name, from_msg, subject, order_id, message_type, date
FROM message.shopify_msg
WHERE is_resolved = 0
  AND no_reply = 0
ORDER BY date ASC;
```

### Message volume by type
```sql
SELECT message_type, COUNT(*) AS total
FROM message.shopify_msg
GROUP BY message_type
ORDER BY total DESC;
```

### All messages for a specific order
```sql
SELECT id, from_name, subject, message_content, message_type, date, is_resolved
FROM message.shopify_msg
WHERE order_id = 'LED47176'
ORDER BY date ASC;
```

### Unresolved messages by store
```sql
SELECT ss_name, COUNT(*) AS unresolved_count
FROM message.shopify_msg
WHERE is_resolved = 0
GROUP BY ss_name
ORDER BY unresolved_count DESC;
```

---

## Bridge to Other Tables

| Target Table | Join Key | Notes |
|---|---|---|
| `order_transaction` | `shopify_msg.order_id = order_transaction.order_id` | Get order details, SKU, revenue for the linked order |
| `order_shipping_billing_detail` | via `order_transaction.order_id` | Get customer shipping address and carrier info |
| `message.message_app_logs` | `(logs.data::jsonb->>'message_row_id')::bigint = shopify_msg.id` AND `logs.action = 'root_cause_confirmed'` | Confirms whether `root_cause` was agent-approved; LEFT JOIN — no log row means unconfirmed |
| `message.phrases` | `TRIM(shopify_msg.root_cause) = TRIM(phrases.phrase)` AND `phrases.send_type = 4` | Root cause category mapping; unmapped values → **Other** |


### Root cause with confirmation status
```sql
SELECT s.id, s.from_name, s.order_id, s.ss_name,
       s.root_cause,
       CASE
         WHEN l.id IS NOT NULL THEN s.root_cause
         WHEN s.root_cause IS NOT NULL THEN 'LLM suggestion (not confirmed)'
         ELSE NULL
       END AS root_cause_display,
       l.date AS confirmed_at
FROM message.shopify_msg s
LEFT JOIN message.message_app_logs l
  ON (l.data::jsonb->>'message_row_id')::bigint = s.id
  AND l.action = 'root_cause_confirmed'
WHERE s.root_cause IS NOT NULL
ORDER BY s.id DESC;
```

---

## Reference Lists

**Sub-Sources (`ss_name`):** ledsone, ledsone-de, ledsone-us, vintage-light-web, electricalsoneuk, relicelectrical, relicelectrical.myshopify.com, 045e77-2, LEDSone UK Ltd, Vintagelite, jedsz8-km, dcvoltage-2

**Message Types (`message_type`):** Question, General, Shipping, Cancellation, Return, Complaint

**Resolution Status (`is_resolved`):** `0` = Unresolved, `1` = Resolved

**Reply Status (`no_reply`):** `0` = Reply expected / needed, `1` = No reply needed (conversation-ending or similar)