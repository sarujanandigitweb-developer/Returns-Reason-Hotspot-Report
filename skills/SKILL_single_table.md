---
name: text-to-sql-single
description: "Use this skill when a user question can be answered from a single data domain: sales/orders, organic traffic, PPC campaigns, or warehouse stock. Covers intent detection, table routing, SQL generation rules, and mandatory postgres execution. Always read this skill before generating any SQL. If the question clearly needs data from two or more domains, switch to the multi-table skill instead."
---

# Text-to-SQL Skill: Single-Table Queries

## ⚠️ CRITICAL: SQL Alone Is Never the Final Answer

Generating a SQL query is only the **midpoint** of answering a question — not the end.

**Every data question must follow this full workflow:**

```
1. Detect intent → choose correct table
2. Generate the SQL query
3. Execute the SQL via postgres:execute_sql
4. Return the actual data results to the user
```

**Never stop at step 2.** A SQL block shown to the user without execution is an incomplete response. The user asked a data question — they need the data, not just the query.

---

## Step 1 — Detect Intent and Route to the Right Table

Use these **strict priority rules** (top rule wins):

| Priority | Trigger Keywords / Pattern | Intent | Table |
|---|---|---|---|
| 1 (highest) | spend, acos, roas, ppc, adgroup, ad group, campaign, campaigns, advertising spend, ad spend | `campaign` | `public.ppc` |
| 2 | impressions, organic clicks, organic conversions, CTR, CVR, conversion rate *(no spend keywords)* | `traffic` | `public.traffic_data` |
| 3 | stock, inventory, warehouse, SKU availability, out of stock, low stock | `stock` | `public.inv_final_stock` |
| 4 (default) | orders, revenue, sales, completed, transactions, platforms, marketplaces, carriers | `sales` | `public.order_transaction` |

> If a question needs data from **two or more** of the above domains → stop and use the **multi-table skill** instead.

---

## Step 2 — Load the Correct Table Definition

After detecting intent, load the matching table definition file:

| Intent | Table Definition File |
|---|---|
| `sales` | `TABLE_order_transaction.md` |
| `traffic` | `TABLE_traffic_data.md` |
| `campaign` | `TABLE_ppc.md` |
| `stock` | `TABLE_inv_final_stock.md` |

Read the table definition for: column names, types, business rules, reference lists, and listing identity keys.

---

## Step 3 — Internal Planning (Before Writing Any SQL)

Complete all four steps mentally before writing the query:

1. **Filters** — list every filter the user mentioned; classify each as row-level (→ WHERE) or aggregated (→ HAVING)
2. **Grouping keys** — list all GROUP BY columns
3. **Metrics** — list all numeric columns to aggregate
4. **Period model** — is this a completed period (full prior calendar unit) or period-to-date?

---

## Step 4 — Generate the SQL

### Output Rules (CRITICAL)
- **Exactly ONE** `sql` code block in the entire response — no exceptions
- No sample data, no mock rows, no example output tables
- No alternative queries or variations
- All assumptions and explanations go **outside** the SQL block
- Never write SQL code inside explanation text — use plain English descriptions only
- **Never display the SQL block to the user in the final response.** The SQL is internal — pass it directly to postgres:execute_sql. The user sees only the executed results and your interpretation.

### Syntax Rules
1. Triple backticks + ` ```sql ` tag
2. **Double quotes** around every column name: `"column_name"`
3. No `ROUND()` anywhere
4. No `QUALIFY` — rewrite with CTEs, subqueries, or HAVING
5. No fixed/hardcoded dates — always use `CURRENT_DATE` or date functions
6. No nested window functions — use CTEs if multiple window operations needed

### NULL Safety — MANDATORY on Every SUM
```
SUM(COALESCE("column", 0))            ← wrap every SUM
COALESCE(num, 0) / NULLIF(denom, 0)   ← wrap every division
```
No exceptions — a bare `SUM("column")` without COALESCE is always wrong.

### CTE Decision Rule
| Question Type | SQL Style |
|---|---|
| Single straightforward question, no sub-parts | Plain SQL — no CTEs |
| Has sub-parts: comparisons, multiple aggregations, filtering after aggregation | Use CTEs |

When CTEs are used, the final `SELECT` must reference them in `FROM`.

### Filter Placement
| Filter Type | Clause |
|---|---|
| Non-aggregated column filter (row-level) | `WHERE` |
| Filter on an aggregated result | `HAVING` |

Putting an aggregate function in `WHERE` is invalid PostgreSQL and will cause an error.

### Date Rules
- Use `CURRENT_DATE` for all calendar-based reporting; never mix with `NOW()`
- Use **half-open intervals**: `"date_col" >= start AND "date_col" < end`
- Exclude `CURRENT_DATE` from ranges unless explicitly required
- TIMESTAMP subtraction: `(CURRENT_DATE - "order_date"::date)::integer` — always cast first
- **Completed period** = full prior calendar unit (e.g., last month = full prior calendar month)
- **Period-to-date** = from start of current unit to yesterday
- Never compare a partial period to a full period

### Period-over-Period Comparisons
- Always `FULL OUTER JOIN` between period CTEs — never `INNER JOIN`
- After FULL OUTER JOIN: `COALESCE(t1.key_col, t2.key_col) AS key_col` to prevent NULL keys

---

## Step 5 — Execute via postgres (MANDATORY — NOT OPTIONAL)

After generating the SQL, **immediately call `postgres:execute_sql`**. Do not wait for the user to ask. Do not show the SQL and stop. Execution is always required.
- **No SQL in the response body.** Do not paste the query, do not wrap it in ```sql fences, do not summarise the query structure. Lead with the answer and the data table only.

### Execution Rule
```
generate SQL  →  call postgres:execute_sql  →  present real results
```

Pass the exact SQL string from Step 4 as the query. The tool runs it against the connected PostgreSQL database and returns live rows.

### After Execution — How to Handle Results

| Outcome | What to Do |
|---|---|
| Rows returned | Present the data clearly — formatted table for multi-row/multi-column results, direct sentence for a single value |
| Zero rows returned | Inform the user: "No records matched the given criteria" and briefly explain what filters were applied |
| Execution error | Show the error message, diagnose the cause, correct the SQL, and re-execute immediately |

### Result Presentation Rules
- **Lead with the answer** — state the key insight or number first, then show the supporting data
- For large result sets (>20 rows): summarise the top findings first; offer to show more or export
- For a single-value result (e.g., total revenue): state the number directly in a sentence, no table needed
- For comparisons: clearly highlight differences, percentage changes, or rankings
- **Never paste raw JSON** from postgres — always format as a readable table or narrative

---

## Domain-Specific Rules Quick Reference

### Sales (`order_transaction`)
- Revenue = `order_total`; always add `WHERE "order_status" = 'Completed'`
- SKU filter = `LIKE '%pattern%'` (never exact `=`)
- Listing = `sku` + `market_place` + `ss_name`

### Traffic (`traffic_data`)
- Organic only — no spend, no ad cost
- Always pair `ref_id` with `which_channel` (1 = Amazon, 2 = eBay)
- Metrics = `impression`, `click`, `conversion` — must aggregate over date ranges
- Listing = `ref_id` + `market_place` + `sub_source_name`

### Campaign (`ppc`)
- KPIs always from aggregated values: ACOS = `SUM(spend) / NULLIF(SUM(sales), 0)`
- Campaign name filter = exact match `=`; pipe `|` in name → split into separate campaigns
- SKU filter = `LIKE '%pattern%'`
- Listing = `ref_id` + `marketplace` + `sub_source`
- Note: column is `marketplace` (not `market_place`)

### Stock (`inv_final_stock`)
- No date column — current snapshot only
- SKU types: single (exact `=`), pack (`LIKE '%PK'`), combo (`LIKE '%+%'`)
- Always `SUM(COALESCE("stock", 0))` when aggregating across warehouses

---

## Conversational Behavior

- If no SQL is needed → answer conversationally; no SQL block, no postgres call
- When question is vague → state your assumption clearly before generating and executing
- Maintain context across follow-up questions in the same conversation
- If user mixes a general question + data question → answer both; always execute SQL for the data part

---

## Full Response Workflow Summary

```
User asks a data question
        ↓
Detect intent → select table → load table definition
        ↓
Plan internally (filters, groups, metrics, period)
        ↓
Generate SQL (one block, all rules applied)
        ↓
Execute via postgres:execute_sql  ← ALWAYS REQUIRED
        ↓
Present real data results to the user clearly