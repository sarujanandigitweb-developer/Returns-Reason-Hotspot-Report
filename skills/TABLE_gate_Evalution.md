# Table Definitions: `analytics.ph_gate_evolution`

## ⚠️ Execution Requirement
After generating any SQL against these tables, **always execute it immediately using `postgres:execute_sql`** and return the real query results to the user. Never present a SQL query alone as the final answer.

---
## Table Schema

| Column | Type | Description |
|--------|------|-------------|
| `asin` | text | Amazon ASIN |
| `market_place` | text | Marketplace string (e.g. `'UK'`) |
| `sub_source` | bigint | Sub-account identifier |
| `sub_source_name` | text | Human-readable sub-account name |
| `start_date` | date | Period start date (`'YYYY-MM-DD'`) |
| `end_date` | date | Period end date (`'YYYY-MM-DD'`) |
| `impression` | double | Organic impressions |
| `click` | double | Organic clicks |
| `conversion` | double | Organic conversions (orders) |
| `ctr` | double | Click-through rate (%) |
| `cvr` | double | Conversion rate (%) |
| `current_session` | bigint | Sessions in current period |
| `previous_session` | bigint | Sessions in prior period |
| `sessions_bimonthly_change` | double | Sessions % change vs prior period |
| `current_bsr` | bigint | Best Seller Rank — current period |
| `previous_bsr` | bigint | Best Seller Rank — prior period |
| `bsr_change_14d` | bigint | BSR delta over 14 days (positive = worse) |
| `return_count` | bigint | Number of returns |
| `unit_sold` | bigint | Units sold |
| `return_rate` | double | Return rate (%) |
| `total_query_impression_count` | bigint | Search Query Performance impressions (SQP top 1000) |
| `which_gate_failed` | text | First gate that failed: `G0`, `G1`, `G2`, `G3`, `G4`, `G4.5`, `G5`, or `NULL` (all passed) |
| `results` | text | JSON array of gate pass/fail details |
| `username` | text | Account username |
| `category_name` | text | Product category |

---

## Gate Logic Reference

Gates are evaluated sequentially. An ASIN stops at its **first failure**.

| Gate | Name | Fail Condition | Semantic Label |
|------|------|----------------|----------------|
| G1 | Relevancy | `total_query_impression_count` = 0 or below threshold | DISCOVERY |
| G2 | Visibility | `sessions_bimonthly_change` < -15% | DISCOVERY |
| G3 | CTR | `ctr` < category CTR benchmark | REPAIR |
| G4 | CVR | `cvr` < category CVR benchmark | REPAIR |
| G4.5 | Believability | `return_rate` > 5% | REPAIR |
| G5 | Scale | `bsr_change_14d` > 20 (rank worsening) | REPAIR |
| NULL | All passed | — | SCALER |

---

## Common Query Patterns

### 1. All ASINs for a user + period
```sql
SELECT asin, market_place, sub_source_name, which_gate_failed, ctr, cvr, return_rate
FROM analytics.ph_gate_evolution
WHERE username = 'john_doe'
  AND start_date = '2026-02-08'
  AND end_date = '2026-02-21'
ORDER BY which_gate_failed, asin;
```

### 2. Gate failure distribution (FBM_001 style)
```sql
SELECT 
    COALESCE(which_gate_failed, 'NONE (SCALER)') AS gate,
    COUNT(*) AS asin_count
FROM analytics.ph_gate_evolution
WHERE username = 'john_doe'
  AND start_date = '2026-02-08'
GROUP BY which_gate_failed
ORDER BY asin_count DESC;
```

### 3. SCALER ASINs (all gates passed)
```sql
SELECT asin, market_place, ctr, cvr, current_session, bsr_change_14d
FROM analytics.ph_gate_evolution
WHERE which_gate_failed IS NULL
  AND username = 'john_doe'
  AND start_date = '2026-02-08';
```

### 4. High return rate ASINs (FBM_007)
```sql
SELECT asin, return_rate, return_count, unit_sold, which_gate_failed
FROM analytics.ph_gate_evolution
WHERE return_rate > 5
  AND username = 'john_doe'
ORDER BY return_rate DESC;
```

### 5. BSR worsening ASINs (FBM_005)
```sql
SELECT asin, current_bsr, previous_bsr, bsr_change_14d, which_gate_failed
FROM analytics.ph_gate_evolution
WHERE bsr_change_14d > 20
  AND username = 'john_doe'
ORDER BY bsr_change_14d DESC;
```

### 6. Session decline (G2 failures / DISCOVERY)
```sql
SELECT asin, current_session, previous_session, sessions_bimonthly_change
FROM analytics.ph_gate_evolution
WHERE which_gate_failed = 'G2'
  AND username = 'john_doe'
ORDER BY sessions_bimonthly_change ASC;
```

### 7. CTR issues (G3 failures — FBM_006)
```sql
SELECT asin, ctr, impression, click, which_gate_failed
FROM analytics.ph_gate_evolution
WHERE which_gate_failed = 'G3'
  AND username = 'john_doe'
ORDER BY ctr ASC;
```

### 8. "Dying Champions" — high CVR, session decay
```sql
SELECT 
    asin, 
    cvr, 
    current_session, 
    previous_session,
    sessions_bimonthly_change,
    which_gate_failed
FROM analytics.ph_gate_evolution
WHERE sessions_bimonthly_change < -10
  AND cvr > 3   -- above typical benchmark; adjust as needed
  AND username = 'john_doe'
ORDER BY cvr DESC;
```

### 9. Filter by category + marketplace
```sql
SELECT asin, which_gate_failed, ctr, cvr, return_rate
FROM analytics.ph_gate_evolution
WHERE category_name = 'Lighting'
  AND market_place = 'UK'
  AND start_date = '2026-02-08';
```

---

## Interpreting `results` JSON

The `results` column contains a JSON array of passed gates:
```json
[
  {"gate_id": "G0", "gate_name": "Compliance", "message": "listing_status = 'active' AND inventory_units = 50 > 0"},
  {"gate_id": "G1", "gate_name": "Relevancy",  "message": "sqp_top_1000 = 1500 >= 1000"}
]
```

To extract gate details in PostgreSQL:
```sql
SELECT asin, which_gate_failed, JSON_LENGTH(results) AS gates_passed
FROM analytics.ph_gate_evolution
WHERE username = 'john_doe';
```

---

## Key Notes for Analysis

1. **`which_gate_failed = NULL`** means the ASIN passed ALL gates → SCALER status.
2. **`sessions_bimonthly_change`** is the bi-monthly (14-day vs prior 14-day) change — threshold for G2 is **< -15%**.
3. **`bsr_change_14d`** — positive value = rank number went UP = rank got WORSE (lower position).
4. **`return_rate`** is already a percentage. G4.5 threshold is **> 5%**.
5. **`total_query_impression_count`** = SQP top-1000 impressions; if 0, ASIN is not ranking for any top keyword → G1 failure.
6. Always filter by `username` + `start_date` + `end_date` to scope a specific run.
7. A single ASIN can appear multiple times if it exists across different `sub_source` / `market_place` combinations.
8. **Sub-source filter — always use `=`, never `LIKE`**: When filtering by `sub_source_name`, always use exact match (`=`). Using `LIKE` risks matching REPLACEMENT/RESEND suffix variants (e.g. `electricalsone_ebay`, `led_sone_ebay_replacement`) and cross-platform name overlaps.
