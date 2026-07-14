# Table Definition: `message.msg_tag_etl`

## ⚠️ Execution Requirement
After generating any SQL against this table, **always execute it immediately using `postgres:execute_sql`** and return the real query results to the user. Never present a SQL query alone as the final answer.

---

## Purpose
LLM-generated message tagging table. Each row represents a tag assigned to a customer message by the LLM pipeline — the LLM reads the message content, classifies it into a `tag_name` category, and records the matched `phrase` that triggered the classification. One row per message (no multi-tag rows). Use this table to filter or group messages by topic/issue type across all channels.

> **All tags and phrases in this table are LLM-generated** — they are not manually assigned by agents. Treat them as AI classifications, not verified human labels.

---

## Schema

| Column | Type | Description |
|---|---|---|
| `id` | bigint | Primary key — nullable |
| `message_id` | text | Channel message id — join key to message tables (see Bridge section for channel-specific joins) |
| `tag_name` | text | LLM-assigned tag / issue category |
| `phrase` | text | The matched phrase or sentence from the message that the LLM used to assign the tag |
| `channel` | text | Source channel — see Channel Reference below |

---

## Key Business Rules

- **LLM-generated only** — `tag_name` and `phrase` are produced entirely by the LLM classification pipeline, not by human agents. Do not present tags as confirmed facts; frame as "LLM-tagged as X"
- **One tag per message** — no message has more than one row in this table
- **`phrase` is the evidence** — it contains the specific text excerpt the LLM matched to assign the tag; useful for understanding why a tag was applied
- **eBay join is different** — eBay `message_id` in this table maps to `ebay_msg.ext_message_id` (cast to text), NOT `ebay_msg.message_id`
- **NULL safety** — all columns are nullable; always handle NULLs in aggregations

---

## Channel Reference

| `channel` | Description |
|---|---|
| `ebay` | eBay messages |
| `shopify` | Shopify messages |
| `amazon` | Amazon messages |
| `bq` | B&Q channel |
| `temu` | Temu channel |
| `unknown` | Unresolved channel |

---

## Tag Name Reference (LLM Categories)

| `tag_name` |
|---|
| Admin related query |
| customer pain points |
| Damage query |
| Defective query |
| Delivery query |
| FAQ |
| opportunity |
| order before shipping |
| Parts missing |
| Pre sales query |
| Return query |
| Wrong description |
| Wrong item sent |
| Wrong quantity sent |

---

## Bridge to Message Tables

| Channel | Target Table | Join Key | Notes |
|---|---|---|---|
| `ebay` | `message.ebay_msg` | `ebay_msg.ext_message_id::text = msg_tag_etl.message_id` | ⚠️ Must cast `ext_message_id` (double precision) to text — do NOT join on `ebay_msg.message_id` |
| `shopify` | `message.shopify_msg` | `shopify_msg.message_id = msg_tag_etl.message_id` | Direct text match |
| `amazon` | `message.amz_msg` | `amz_msg.message_id = msg_tag_etl.message_id` | Direct text match |

---

## Example Queries

### Tag breakdown for eBay (last 30 days)
```sql
SELECT t.tag_name, COUNT(*) AS total
FROM message.msg_tag_etl t
JOIN message.ebay_msg e
  ON e.ext_message_id::text = t.message_id
WHERE t.channel = 'ebay'
  AND e.receive_date >= CURRENT_DATE - INTERVAL '30 days'
GROUP BY t.tag_name
ORDER BY total DESC;
```

### Tag breakdown for Shopify (last 30 days)
```sql
SELECT t.tag_name, COUNT(*) AS total
FROM message.msg_tag_etl t
JOIN message.shopify_msg s
  ON s.message_id = t.message_id
WHERE t.channel = 'shopify'
  AND s.date >= CURRENT_DATE - INTERVAL '30 days'
GROUP BY t.tag_name
ORDER BY total DESC;
```

### Tag breakdown for Amazon (last 30 days)
```sql
SELECT t.tag_name, COUNT(*) AS total
FROM message.msg_tag_etl t
JOIN message.amz_msg a
  ON a.message_id = t.message_id
WHERE t.channel = 'amazon'
  AND a.date >= CURRENT_DATE - INTERVAL '30 days'
GROUP BY t.tag_name
ORDER BY total DESC;
```

### Get tag for a single message by msg id

**eBay** — join via `ext_message_id::text`:
```sql
SELECT t.tag_name, t.phrase
FROM message.msg_tag_etl t
WHERE t.channel = 'ebay'
  AND t.message_id = (
      SELECT ext_message_id::text FROM message.ebay_msg WHERE id = :ebay_msg_id
  );
```

Or as a LEFT JOIN when fetching the message row at the same time:
```sql
SELECT e.id, e.ss_name, e.sender_id, e.receive_date,
       t.tag_name, t.phrase
FROM message.ebay_msg e
LEFT JOIN message.msg_tag_etl t
  ON t.message_id = e.ext_message_id::text
  AND t.channel = 'ebay'
WHERE e.id = :ebay_msg_id;
```

**Shopify / Amazon** — join via `message_id` directly:
```sql
-- Shopify
SELECT e.id, e.from_name, e.order_id, e.date,
       t.tag_name, t.phrase
FROM message.shopify_msg e
LEFT JOIN message.msg_tag_etl t
  ON t.message_id = e.message_id
  AND t.channel = 'shopify'
WHERE e.id = :shopify_msg_id;

-- Amazon
SELECT e.id, e.from_name, e.order_id, e.date,
       t.tag_name, t.phrase
FROM message.amz_msg e
LEFT JOIN message.msg_tag_etl t
  ON t.message_id = e.message_id
  AND t.channel = 'amazon'
WHERE e.id = :amz_msg_id;
```

> If `tag_name` is NULL after the LEFT JOIN, the message has not been tagged by the LLM pipeline yet.

---

### Sample messages for a specific tag with matched phrase
```sql
SELECT e.id, e.ss_name, e.sender_id, t.tag_name, t.phrase, e.receive_date
FROM message.msg_tag_etl t
JOIN message.ebay_msg e
  ON e.ext_message_id::text = t.message_id
WHERE t.channel = 'ebay'
  AND t.tag_name = 'Damage query'
ORDER BY e.receive_date DESC
LIMIT 20;
```
