---
name: text-to-sql-multi
description: "Use this skill when a user question explicitly requires data from two or more of the 6 core domains: Orders, Traffic, PPC, Stock/Inventory, Expenses, or Shipment. Covers the chained CTE approach, all join paths, SKU resolution via listing_data, channel/source consistency rules, aggregation-before-joining rules, and mandatory postgres execution. Always read this skill AND the relevant table definition files before generating SQL."
---

# Text-to-SQL Skill: Multi-Table Queries

## ⚠️ CRITICAL: SQL Alone Is Never the Final Answer

Generating a SQL query is only the **midpoint** — not the end.

**Every data question must follow this full workflow:**

```
1. Identify all required tables
2. Determine join path → choose CTE or Step-by-Step approach
3. Build query / execute supervised steps
4. Execute via postgres:execute_sql
5. Present real data results to the user
```

**Never stop at step 3.** Always execute and always return real results.

---

## When to Use This Skill

Use this skill **only** when the question explicitly needs data from two or more of these 6 core domains:

| Domain | Primary Table |
|---|---|
| Orders / Sales | `public.order_transaction` |
| Organic Traffic | `public.traffic_data` |
| PPC / Campaigns | `public.ppc` + `public.ppc_performance` |
| Stock / Inventory | `public.location_wise_inv_stock` or `public.inv_final_stock` |
| Expenses / Fees | `public.amz_order_expenses`, `public.ebay_order_expenses`, `public.shopify_transactions` |
| Shipment / Billing | `public.order_shipping_billing_detail` |

---

## Step 1 — Identify All Required Tables

List every domain needed and load the matching definition files:

| Domain | Tables                                         | Definition File |
|---|------------------------------------------------|---|
| Orders | `order_transaction`                            | `TABLE_order_transaction.md` |
| Traffic | `traffic_data`                                 | `TABLE_traffic_data.md` |
| PPC | `ppc` + `ppc_performance`                      | `TABLE_ppc.md` |
| Stock | `location_wise_inv_stock` / `inv_final_stock`  | `TABLE_inv_final_stock.md` |
| Expenses | `amz_order_expenses` , `ebay_order_expenses`, `shopify_transactions` | `TABLE_expense_amz_ebay_shopify.md` |
| Shipment | `order_shipping_billing_detail`                | `TABLE_order_transaction.md` |
| SKU Bridge | `listing_data`                                | `SKILL_ppc_stock_lookup.md` |
| Segmentation | `analytics.ph_segment`                         | `TABLE_ph_segment.md` |
| Gate Analysis | `analytics.ph_gate_evolution`                  | `TABLE_gate_Evalution.md` |

---

## Step 2 — Determine the Join Path

### Direct Joins (No Bridge Needed)

| From | To | Join Key |
|---|---|---|
| `order_transaction` | `amz_order_expenses` | `order_id` |
| `order_transaction` | `ebay_order_expenses` | `order_id` |
| `order_transaction` | `order_shipping_billing_detail` | `order_id` |
| `order_transaction` | `location_wise_inv_stock` | `sku` |
| `order_transaction` | `inv_final_stock` | `sku` |
| `order_transaction` | `traffic_data` | `asin/item_id/product_id = ref_id` + `market_place` + channel + sub_source |
| `order_transaction` | `ppc_performance` | `asin/item_id = ref_id` + `market_place` + source + sub_source |
| `traffic_data` | `ppc_performance` | `ref_id` + `market_place` + channel + sub_source |
| `analytics.ph_segment` | `traffic_data` | `ref_id` + `which_channel` + `market_place` |
| `analytics.ph_segment` | `order_transaction` | `ref_id = asin` (channel=1) or `item_id` (channel=2) |
| `analytics.ph_gate_evolution` | `order_transaction` | `asin` |

### Bridge Joins (via `listing_data`)

| From | Bridge | To |
|---|---|---|
| `ppc_performance` | `listing_data` (ref_id + which_channel + sub_source + market_place + wrong_sku=0) | `location_wise_inv_stock` / `inv_final_stock` on resolved SKU |
| `traffic_data` | `listing_data` (ref_id + which_channel + sub_source + market_place + wrong_sku=0) | `location_wise_inv_stock` / `inv_final_stock` on resolved SKU |

---

## Step 2b — Choose Query Approach: CTE vs Step-by-Step

**This decision must be made immediately after the join path is identified — before any SQL is written.**

### Decision Rule

| Join Path Involved | Approach | Reason |
|---|---|---|
| Direct joins only (order_id / sku / ref_id) | **CTE** | Clean, predictable, one-to-one keys — safe to run atomically |
| `listing_data` bridge in path | **Step-by-step (supervised)** | Data quality issues — multiple SKU rows per ASIN, inconsistent mapped_sku, variant suffixes — silent failures in CTE |

```
Join path identified in Step 2
        ↓
Does it involve listing_data?
        ↓
YES → Step-by-step supervised approach (see below)
NO  → CTE chained approach (continue to Step 3)
```

---

### Step-by-Step Supervised Approach (listing_data bridge ONLY)

When `listing_data` is in the join path — for **PPC → stock** or **traffic → stock** — do NOT use CTE. Use the following supervised flow instead.

#### Why CTE fails for listing_data

The `listing_data` table has known data quality issues that cause silent failures in CTE:

| Problem | Risk in CTE |
|---|---|
| Multiple rows per ASIN (base SKU + variants like `_AML`, `_AMD`, `_IDE`) | CTE picks wrong row silently — returns 0 stock with no error thrown |
| Inconsistent `mapped_sku` — sometimes NULL, sometimes filled | Two-path resolution logic picks wrong path silently |
| No single "correct row" flag per ASIN | No programmatic rule can reliably pick the right SKU |
| `wrong_sku = 1` rows mixed with valid rows | One missed filter = wrong SKU passes through with no warning |
| `amzn.gr.*` platform alias SKUs mixed in | Must be excluded manually — only visible when you see the raw rows |

> **A CTE returns 0 stock with no error when SKU resolution fails. Step-by-step makes the failure visible at Step 2 before it corrupts the final result.**

#### The supervised flow

```
Step 1 → Query ppc_performance or traffic_data
          └─ Get ref_ids, listing SKUs, marketplace, sub_source
          └─ Show results to user
          └─ WAIT for confirmation before proceeding

Step 2 → Query listing_data for those ref_ids
          └─ Show ALL raw rows (ref_id, sku, mapped_sku, wrong_sku)
          └─ User visually verifies:
               - How many rows per ASIN?
               - mapped_sku filled or NULL?
               - Any bad variants (_AML, _AMD, _IDE, _CA)?
               - Any amzn.gr.* rows that slipped through?
          └─ WAIT for confirmation / user selects correct SKU per ASIN

Step 3 → Query stock table with VALIDATED SKUs only
          └─ Exact match (=) only — NEVER LIKE
          └─ Filter by correct location (UK / Germany / US)
          └─ Show final combined result
```

#### Key rules in supervised flow

- **Never auto-proceed** — pause after each step, show intermediate result, wait for go-ahead
- **Never use LIKE** on stock table SKU lookup — exact match `=` only
- **Exclude `amzn.gr.*`** SKUs from Step 1 (`sku NOT LIKE 'amzn.gr.%'`)
- **Exclude `wrong_sku = 1`** rows in Step 2 (`wrong_sku = 0`)
- **Prefer `mapped_sku`** over `sku` when `mapped_sku IS NOT NULL AND mapped_sku != ''`
- **If multiple valid rows remain after filters** — show them all to user, do not guess which is correct
- **Follow `SKILL_ppc_stock_lookup.md`** for the full bridge logic, marketplace → location mapping, and eBay multi-variant handling

#### Trigger phrases for this approach

Any question combining PPC or traffic with stock/inventory:

- "top spend PPC ASINs and their stock"
- "high impression listings — do they have stock?"
- "which PPC campaigns are at risk of stockout?"
- "traffic → stock coverage for UK"
- "eBay ads + inventory levels"
- "Shopify PPC + stock remaining"

#### Future migration to CTE

This approach stays as step-by-step **until the data is fixed at source**:

- `listing_data` has exactly **one** `wrong_sku = 0` row per ASIN per marketplace per sub_source
- `mapped_sku` is always populated where listing SKU ≠ inventory SKU (no NULL ambiguity)
- Variant suffixes (`_AML`, `_AMD`, `_IDE`, `_CA`) stripped at ETL time — not at query time

**Until those three conditions are met — step-by-step is the correct and permanent approach for this bridge.**

---

## Step 3 — Core Join Keys — Master Reference

### Chained CTEs — Aggregate First, Join Second

Multi-table queries (CTE path) must be built as a **chain** — each CTE produces a clean, aggregated result that feeds the next. Never join raw tables without aggregating first.

```
CTE 1: Aggregate Domain A by full listing identity keys  (filtered, grouped, summed)
         ↓
CTE 2: Aggregate Domain B by full listing identity keys  (filtered, grouped, summed)
         ↓
CTE 3: Bridge/resolve identifiers if needed
         ↓
Final SELECT: Join CTEs on identity keys, compute combined metrics, ORDER, LIMIT
```

**Why aggregate first?**
Joining before aggregating causes row explosion — 1,000 sales transactions joined to 10 traffic rows = 10,000 rows, multiplying every metric incorrectly.

### 1. Order ↔ Expense ↔ Shipment (via `order_id`)
```
order_transaction.order_id
    → amz_order_expenses.order_id
    → ebay_order_expenses.order_id
    → order_shipping_billing_detail.order_id
```
- Single key links all three
- Use for net profit, true margin, fee analysis, shipment cost per order

### 2. Order ↔ Stock (via `sku` — direct)
```
order_transaction.sku → location_wise_inv_stock.sku
order_transaction.sku → inv_final_stock.sku
```
- Direct join — no bridge needed
- Use for sales rate vs inventory, stockout prevention, overstock detection

### 3. Order ↔ Traffic (via `ref_id`)
```
order_transaction.asin       = traffic_data.ref_id  (which_channel = 1, Amazon)
order_transaction.item_id    = traffic_data.ref_id  (which_channel = 2, eBay)
order_transaction.product_id = traffic_data.ref_id  (which_channel = 3, Shopify)
```
- Always match on `ref_id` + `market_place` + `source/which_channel` + `sub_source` + date range
- ref_id alone is NOT sufficient

### 4. Order ↔ PPC (via `ref_id`)
```
ppc_performance.ref_id = order_transaction.asin    (Amazon, source=1)
ppc_performance.ref_id = order_transaction.item_id (eBay, source=2)
```
- Always match on `ref_id` + `market_place` + `source/which_channel` + `sub_source` + date range
- Use for paid vs organic revenue, ROAS vs actual orders

### 5. Traffic ↔ PPC (via `ref_id`)
```
traffic_data.ref_id = ppc_performance.ref_id
```
- Amazon only (which_channel = 1)
- Always match on `ref_id` + `market_place` + `sub_source` + date range
- Use for organic vs paid CTR/CVR comparison, impression share

### 6. PPC → Stock (via `listing_data` bridge — STEP-BY-STEP MANDATORY)
```
ppc_performance.ref_id
    → listing_data (ref_id + which_channel + sub_source + market_place + wrong_sku=0)
    → resolve SKU: mapped_sku if NOT NULL, else sku
    → location_wise_inv_stock.sku
```
- NEVER join ppc_performance directly to stock
- NEVER use CTE for this path — use step-by-step supervised approach (Step 2b above)
- Always filter `wrong_sku = 0`
- Always exclude `amzn.gr.*` SKUs

### 7. Traffic → Stock (via `listing_data` bridge — STEP-BY-STEP MANDATORY)
```
traffic_data.ref_id
    → listing_data (ref_id + which_channel + sub_source + market_place + wrong_sku=0)
    → resolve SKU: mapped_sku if NOT NULL, else sku
    → location_wise_inv_stock.sku
```
- Same bridge as PPC → Stock
- `traffic_data` has NO SKU column — listing_data is the only correct resolver
- NEVER use order_transaction as a bridge for traffic → stock
- NEVER use CTE for this path — use step-by-step supervised approach (Step 2b above)

---

## Step 4 — Apply Correct Join Types

| Situation | Join Type |
|---|---|
| Period-over-period comparison | `FULL OUTER JOIN` |
| Product may not exist in target table | `LEFT JOIN` |
| Data guaranteed in both tables | `INNER JOIN` acceptable |
| After FULL OUTER JOIN | `COALESCE(t1.key, t2.key) AS key` — never leave join key nullable |

---

## Step 5 — Apply Same Date Range to All CTEs

Push date filters **inside each source CTE** — not only on the final join.

```sql
-- CORRECT: each CTE filters its own date range
CTE orders  →  WHERE "order_date"::date >= start AND "order_date"::date < end
CTE traffic →  WHERE "date" >= start AND "date" < end
CTE ppc     →  WHERE "date" >= start AND "date" < end
CTE expense →  WHERE "date" >= start AND "date" < end

-- WRONG: date filter only on final SELECT — intermediate CTEs pull all data
```

> Stock tables (`location_wise_inv_stock`, `inv_final_stock`) have **no date column** — they are current snapshots only. Never apply date filters to them.

---

## Step 6 — Execute via postgres (MANDATORY — NOT OPTIONAL)

After building the full query (CTE or step-by-step), **immediately call `postgres:execute_sql`**. Do not wait for the user to ask. Do not show the SQL and stop.

### Execution Rule
```
build query  →  call postgres:execute_sql  →  present real results
```

### After Execution — How to Handle Results

| Outcome | What to Do |
|---|---|
| Rows returned | Format clearly — table for multi-row results, sentence for single values |
| Zero rows returned | Inform the user and explain which filters eliminated all records |
| Execution error | Show the error, diagnose the cause, fix, and re-execute immediately |

### Result Presentation Rules
- **Never display the SQL in the final response.** SQL is internal — pass it directly to postgres:execute_sql. The user sees results only, never the query. No ```sql fences, no query summaries, no "here's the SQL I ran" preamble.
- **Lead with the answer** — state the key insight or number first, then show supporting data
- For large result sets (>20 rows): summarise top findings; offer to drill down
- For domain comparisons: show metrics side by side (e.g. organic clicks vs paid clicks, revenue vs stock days remaining)
- **Never paste raw JSON** — always format as a readable table or narrative

---

## SKU Resolution Rule — Universal

| Source Table | Has SKU? | Bridge to Stock |
|---|---|---|
| `order_transaction` | ✅ Yes — direct | No bridge needed — join on `sku` directly → CTE safe |
| `ppc_performance` | ⚠️ Listing SKU only | `listing_data` bridge → **step-by-step mandatory** |
| `traffic_data` | ❌ No SKU | `listing_data` bridge → **step-by-step mandatory** |

### listing_data SKU Resolution Logic
```
IF mapped_sku IS NOT NULL AND mapped_sku != ''
    → use mapped_sku   (corrected inventory SKU)
ELSE
    → use sku          (use listing SKU as-is — prefer shortest if multiple rows)
```

---

## Channel / Source Consistency — MANDATORY

Always enforce channel consistency when joining across tables:

| `traffic_data.which_channel` | `order_transaction.source_name` | `ppc_performance.source` |
|---|---|---|
| `1` | `'AMAZON'` | `1` |
| `2` | `'EBAY'` | `2` |
| `3` | `'SHOPIFY'` | `3` |

> ⚠️ Marketplace names are now consistent across all tables after ETL alignment — no translation or CASE mapping needed when joining on `market_place`.

---

## Identity Key Rule — CRITICAL

**ref_id alone is NEVER sufficient as a join key.**

Always combine ALL of:
```
ref_id + market_place + source/which_channel + sub_source + date range
```

Because the same ref_id (ASIN/item_id) can exist across:
- Multiple marketplaces (UK, Germany, US)
- Multiple sub-sources (amazon Ledsone, amazon Dcvoltage)
- Multiple time periods

Failing to include all identity dimensions causes cross-contamination of metrics across accounts and marketplaces.

---

## Common Multi-Table Patterns

### 1. Order + Traffic (Sales vs Organic Funnel)
Aggregate `order_transaction` (Completed, by ref_id + market_place + source + sub_source) → aggregate `traffic_data` (by ref_id + market_place + which_channel + sub_source_name) → join on ref_id + market_place + channel mapping
**Approach: CTE**
Output: revenue, orders, impressions, clicks, conversions, CTR, CVR

### 2. Order + PPC (Organic vs Paid Revenue)
Aggregate `order_transaction` (Completed) → aggregate `ppc_performance` (by ref_id + marketplace + source + sub_source) → join on ref_id + market_place + source
**Approach: CTE**
Output: organic revenue, ad spend, ACOS, ROAS, total revenue

### 3. Order + Stock (Sales Rate vs Inventory)
Aggregate `order_transaction` (Completed, daily avg units) → join `location_wise_inv_stock` on sku → compute days of stock remaining
**Approach: CTE**
Output: SKU, avg daily units, current stock, days remaining

### 4. Traffic + PPC (Organic vs Paid Performance)
Aggregate `traffic_data` → aggregate `ppc_performance` → join on ref_id + market_place + sub_source (Amazon only)
**Approach: CTE**
Output: organic impressions/CTR/CVR vs paid impressions/CTR/CVR side by side

### 5. Order + Expense (Net Revenue / True Profit)
Aggregate `order_transaction` (Completed, revenue via order_total) → join `amz_order_expenses` or `ebay_order_expenses` on order_id → sum fees by charge_type, exclude pass-through (Principal, Tax, ShippingCharge)
**Approach: CTE**
Output: gross revenue, channel fees, refund impact, net profit

### 6. Order + Expense + Shipment (Full Cost View)
Aggregate `order_transaction` → join `order_shipping_billing_detail` on order_id (carrier charges) → join `amz/ebay_order_expenses` on order_id → compute total landed cost
**Approach: CTE**
Output: revenue, shipment cost, platform fees, net margin

### 7. PPC + Stock (Campaign Inventory Awareness)
Get ref_id from `ppc_performance` → bridge via `listing_data` (wrong_sku=0, resolve mapped_sku) → join `location_wise_inv_stock` on resolved sku + location
**Approach: STEP-BY-STEP SUPERVISED — listing_data bridge**
Output: ASIN/item_id, ad spend, stock remaining, days of stock at current sales rate

### 8. Traffic + Stock (Visibility vs Availability)
Get ref_id from `traffic_data` → bridge via `listing_data` (wrong_sku=0, resolve mapped_sku) → join `location_wise_inv_stock` on resolved sku + location
**Approach: STEP-BY-STEP SUPERVISED — listing_data bridge**
Output: ref_id, impressions, clicks, current stock

### 9. Order + Traffic + PPC (Full Funnel View)
Aggregate all three domains → join on ref_id + market_place + channel + sub_source
**Approach: CTE**
Output: paid impressions, organic impressions, paid clicks, organic clicks, paid revenue, organic revenue, total ACOS, blended ROAS

### 10. Order + PPC + Expense + Stock (Full Profitability + Inventory)
Full chained CTE: orders → expenses (net fees) → ppc (ad spend) → stock (days remaining)
**Approach: CTE** (stock joined via order_transaction.sku — no listing_data bridge needed)
Output: SKU, gross revenue, platform fees, ad spend, net profit, stock days — complete health view
Use for: kill list decisions, portfolio prioritization, emergency stock rationing by channel margin

### 11. Segment + Order (Segment Performance vs Revenue)
Join `analytics.ph_segment` → `order_transaction` on ref_id = asin/item_id + market_place + channel
**Approach: CTE**
Output: segment classification alongside actual revenue and order count

### 12. Gate + Order (Gate Failure vs Sales Impact)
Join `analytics.ph_gate_evolution` → `order_transaction` on asin + market_place
**Approach: CTE**
Output: which gate failed alongside revenue, sessions, return rate

---

## Universal SQL Rules

### Syntax
- Triple backticks + ` ```sql `
- **Double quotes** around every column name
- No `ROUND()` — cast to `::numeric` instead if precision needed
- No `QUALIFY` — rewrite with CTEs or subqueries
- No fixed/hardcoded dates — always use `CURRENT_DATE` or date functions
- No nested window functions — use CTEs
- Exactly **ONE** `sql` block — no alternatives, no variations

### NULL Safety — MANDATORY
```sql
SUM(COALESCE("column", 0))                        -- wrap every SUM
COALESCE(numerator, 0) / NULLIF(denominator, 0)   -- wrap every division
```

### Date Rules
- `CURRENT_DATE` only — never mix with `NOW()`
- Half-open intervals: `"date_col" >= start AND "date_col" < end`
- Apply date filter **inside each source CTE individually**
- Same period model on both sides of any period-over-period comparison
- Stock tables have no date column — never apply date filters to them

### Filter Placement
- Row-level filters → `WHERE` inside each source CTE
- Post-aggregation filters → `HAVING` or outer `WHERE` on CTE result
- Aggregate functions **never** in `WHERE`

---

## Pre-Query Checklist

Before writing any SQL:
- [ ] All required domains identified and definition files loaded
- [ ] Join path determined — direct (order_id / sku / ref_id) or via listing_data bridge
- [ ] **Query approach decided: CTE or step-by-step?** (listing_data in path → step-by-step mandatory)
- [ ] Each domain aggregated in its own CTE before joining (CTE path only)
- [ ] Full identity key used: ref_id + market_place + source/channel + sub_source
- [ ] Channel/source values consistent across all tables
- [ ] listing_data bridge used for PPC→stock and traffic→stock (NOT order_transaction)
- [ ] wrong_sku = 0 filter applied on listing_data
- [ ] mapped_sku resolution applied (mapped_sku if not NULL and not empty, else sku)
- [ ] amzn.gr.* SKUs excluded from ppc_performance before bridge lookup
- [ ] Date filter applied inside each source CTE individually
- [ ] Stock tables have NO date filter (current snapshot only)
- [ ] FULL OUTER JOIN used for period-over-period comparisons
- [ ] COALESCE on all SUM columns
- [ ] NULLIF on all division denominators
- [ ] No ROUND() — use ::numeric cast if needed
- [ ] Exactly one SQL block in the response (CTE path) or one SQL block per step (step-by-step path)

Before sending the response:
- [ ] `postgres:execute_sql` called with the complete query (or per step in supervised flow)
- [ ] Real results formatted and presented to the user
- [ ] Answer leads with the key insight, not the raw table
- [ ] In step-by-step: paused after each step and waited for user confirmation before proceeding