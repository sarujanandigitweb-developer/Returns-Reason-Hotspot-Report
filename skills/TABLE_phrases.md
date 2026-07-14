# Table Definition: `message.phrases`

## ⚠️ Execution Requirement
After generating any SQL against this table, **always execute it immediately using `postgres:execute_sql`** and return the real query results to the user. Never present a SQL query alone as the final answer.

---

## Purpose
Master phrase dictionary in the **`message`** schema. Each row is one phrase rule with an action type (`send_type`) — warning, block, root cause, corrective action, listing flag, etc. **`send_type = 4` rows are the canonical root-cause categories** and map to `root_cause` values on channel message tables (`message.ebay_msg`, `message.amz_msg`, `message.shopify_msg`).

---

## Root Cause Mapping (`send_type = 4`)

| Source | Column | Mapping rule |
|---|---|---|
| `message.ebay_msg` | `root_cause` | Match `ebay_msg.root_cause` to `message.phrases.phrase` where `send_type = 4` |
| `message.amz_msg` | `root_cause` | Match `amz_msg.root_cause` to `message.phrases.phrase` where `send_type = 4` |
| `message.shopify_msg` | `root_cause` | Match `shopify_msg.root_cause` to `message.phrases.phrase` where `send_type = 4` |

**Category rule:**
- If `root_cause` on a message row **matches** a `message.phrases.phrase` with `send_type = 4` → use that phrase as the category label.
- If `root_cause` is populated but **does not exist** in `message.phrases` (`send_type = 4`) → classify as **`Other`**.
- If `root_cause` is NULL or blank → treat as uncategorised (exclude from root-cause breakdown unless user asks for NULLs).

---

## Schema

| Column | Type | Description |
|--------|------|-------------|
| `id` | bigint | Primary key (auto-increment) |
| `phrase` | text | Phrase or keyword text — may be NULL |
| `send_type` | bigint | Action/category type — see Send Type Reference below |
| `add_by` | bigint | User id who added the phrase — may be NULL |
| `created_at` | timestamp | When the phrase was created (default `current_timestamp`) |

---

## Send Type Reference

| `send_type` | Meaning |
|---|---|
| `1` | Warning |
| `2` | Block |
| `3` | Own warning |
| `4` | Root cause |
| `5` | Corrective actions |
| `6` | Listing flag issue |

---

## Key Business Rules

- **One row = one phrase rule** in the master dictionary
- **`send_type`** determines how the phrase is used operationally (warn, block, root-cause label, etc.)
- **`phrase`** is the match text — filter with `TRIM()` and case handling when searching
- **`add_by`** identifies who created the rule; NULL if unknown or system-added
- **`created_at`** is the authoritative created timestamp for this table (no `updated_at`)
- **`send_type = 4`** defines valid root-cause categories — `message.phrases.phrase` values are the allowed labels for `root_cause` on message tables
- **Unmapped `root_cause`** on any message table (value not found in `message.phrases` where `send_type = 4`) → report as **`Other`**
- Compare using trimmed text: `TRIM(message.root_cause) = TRIM(message.phrases.phrase)`

---

## Common Query Patterns

### All phrases by send type
```sql
SELECT id, phrase, send_type, add_by, created_at
FROM message.phrases
WHERE send_type = :send_type
ORDER BY created_at DESC, id DESC;
```

### Search phrase text
```sql
SELECT id, phrase, send_type, add_by, created_at
FROM message.phrases
WHERE phrase ILIKE '%' || :search_text || '%'
ORDER BY created_at DESC
LIMIT 100;
```

### Phrase count by send type
```sql
SELECT send_type, COUNT(*) AS phrase_count
FROM message.phrases
WHERE phrase IS NOT NULL
  AND TRIM(phrase) <> ''
GROUP BY send_type
ORDER BY phrase_count DESC;
```

### Recent phrases added
```sql
SELECT id, phrase, send_type, add_by, created_at
FROM message.phrases
ORDER BY created_at DESC, id DESC
LIMIT 50;
```

### Phrases added by a user
```sql
SELECT id, phrase, send_type, created_at
FROM message.phrases
WHERE add_by = :user_id
ORDER BY created_at DESC;
```

### Full phrase by id
```sql
SELECT id, phrase, send_type, add_by, created_at
FROM message.phrases
WHERE id = :phrase_id;
```

### Block / warning phrase lists
```sql
-- Block phrases (send_type = 2)
SELECT id, phrase, add_by, created_at
FROM message.phrases
WHERE send_type = 2
  AND phrase IS NOT NULL
  AND TRIM(phrase) <> ''
ORDER BY phrase ASC;

-- Warning phrases (send_type = 1)
SELECT id, phrase, add_by, created_at
FROM message.phrases
WHERE send_type = 1
  AND phrase IS NOT NULL
  AND TRIM(phrase) <> ''
ORDER BY phrase ASC;
```

### Root cause and corrective action phrases
```sql
SELECT id, phrase, send_type, add_by, created_at
FROM message.phrases
WHERE send_type IN (4, 5)
  AND phrase IS NOT NULL
  AND TRIM(phrase) <> ''
ORDER BY send_type, phrase ASC;
```

### Root cause category list (canonical labels)
```sql
SELECT id, phrase
FROM message.phrases
WHERE send_type = 4
  AND phrase IS NOT NULL
  AND TRIM(phrase) <> ''
ORDER BY phrase ASC;
```

### Root cause breakdown on Amazon messages (with Other)
```sql
SELECT
  CASE
    WHEN p.phrase IS NOT NULL THEN p.phrase
    ELSE 'Other'
  END AS root_cause_category,
  COUNT(*) AS message_count
FROM message.amz_msg am
LEFT JOIN message.phrases p
  ON p.send_type = 4
 AND TRIM(p.phrase) = TRIM(am.root_cause)
WHERE am.root_cause IS NOT NULL
  AND TRIM(am.root_cause) <> ''
  AND am.date >= ':target_date 00:00:00'
  AND am.date <= ':target_date 23:59:59'
GROUP BY 1
ORDER BY message_count DESC;
```

### Root cause breakdown on Shopify messages (with Other)
```sql
SELECT
  CASE
    WHEN p.phrase IS NOT NULL THEN p.phrase
    ELSE 'Other'
  END AS root_cause_category,
  COUNT(*) AS message_count
FROM message.shopify_msg sm
LEFT JOIN message.phrases p
  ON p.send_type = 4
 AND TRIM(p.phrase) = TRIM(sm.root_cause)
WHERE sm.root_cause IS NOT NULL
  AND TRIM(sm.root_cause) <> ''
  AND sm.date >= ':target_date 00:00:00'
  AND sm.date <= ':target_date 23:59:59'
GROUP BY 1
ORDER BY message_count DESC;
```

### Root cause breakdown on eBay messages (with Other)
```sql
SELECT
  CASE
    WHEN p.phrase IS NOT NULL THEN p.phrase
    ELSE 'Other'
  END AS root_cause_category,
  COUNT(*) AS message_count
FROM message.ebay_msg em
LEFT JOIN message.phrases p
  ON p.send_type = 4
 AND TRIM(p.phrase) = TRIM(em.root_cause)
WHERE em.root_cause IS NOT NULL
  AND TRIM(em.root_cause) <> ''
  AND em.response_date >= ':target_date 00:00:00'
  AND em.response_date <= ':target_date 23:59:59'
GROUP BY 1
ORDER BY message_count DESC;
```

### Messages with unmapped root_cause (Other bucket detail)
```sql
SELECT am.id, am.from_msg, am.order_id, am.root_cause, am.date
FROM message.amz_msg am
LEFT JOIN message.phrases p
  ON p.send_type = 4
 AND TRIM(p.phrase) = TRIM(am.root_cause)
WHERE am.root_cause IS NOT NULL
  AND TRIM(am.root_cause) <> ''
  AND p.id IS NULL
ORDER BY am.date DESC
LIMIT 100;
```

### List all block phrases
```sql
SELECT id, phrase, add_by, created_at
FROM message.phrases
WHERE send_type = 2
  AND phrase IS NOT NULL
  AND TRIM(phrase) <> ''
ORDER BY phrase ASC;
```

### Search phrase text
```sql
SELECT id, phrase, send_type, created_at
FROM message.phrases
WHERE phrase ILIKE '%refund%'
ORDER BY send_type, id;
```

### Phrase count by date
```sql
SELECT send_type, COUNT(*) AS phrase_count
FROM message.phrases
WHERE DATE(created_at) = ':target_date'
GROUP BY send_type
ORDER BY phrase_count DESC;
```

### Amazon root-cause counts for a day (mapped + Other)
```sql
SELECT
  CASE
    WHEN p.phrase IS NOT NULL THEN p.phrase
    ELSE 'Other'
  END AS root_cause_category,
  COUNT(*) AS message_count
FROM message.amz_msg am
LEFT JOIN message.phrases p
  ON p.send_type = 4
 AND TRIM(p.phrase) = TRIM(am.root_cause)
WHERE am.root_cause IS NOT NULL
  AND TRIM(am.root_cause) <> ''
  AND am.date >= ':target_date 00:00:00'
  AND am.date <= ':target_date 23:59:59'
GROUP BY 1
ORDER BY message_count DESC;
```

---

## Bridge to Other Tables

| Target Table | Join Key | Notes |
|---|---|---|
| `message.ebay_msg` | `TRIM(ebay_msg.root_cause) = TRIM(message.phrases.phrase)` AND `message.phrases.send_type = 4` | eBay root-cause category mapping; unmapped → **Other** |
| `message.amz_msg` | `TRIM(amz_msg.root_cause) = TRIM(message.phrases.phrase)` AND `message.phrases.send_type = 4` | Amazon root-cause category mapping; unmapped → **Other** |
| `message.shopify_msg` | `TRIM(shopify_msg.root_cause) = TRIM(message.phrases.phrase)` AND `message.phrases.send_type = 4` | Shopify root-cause category mapping; unmapped → **Other** |

---

## Reference Lists

**Send Types (`send_type`):** `1` = Warning, `2` = Block, `3` = Own warning, `4` = Root cause (maps to message `root_cause`), `5` = Corrective actions, `6` = Listing flag issue

**Root Cause Phrases (`send_type = 4`):** Charge Back, CUSTOMER_MISUSE, Delivery Issue, EBAY_RECALL, FULFILMENT_CARRIER, FULFILMENT_WAREHOUSE, INVOICE, LISTING_CONTENT, MARKETPLACE_ADMIN, OTHER, OUT OF STOCK, PRE_SALES_QUERY, PRODUCT_QUALITY, RETURN, Wrong Address

**Root Cause Fallback:** Unmapped message `root_cause` values → **`Other`**
