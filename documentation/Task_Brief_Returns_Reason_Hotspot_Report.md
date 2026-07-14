# Task Brief: Returns Reason Hotspot Report

**Assigned to:** Sarujanan
**Assigned by:** DWC
**Deadline:** TODAY, 3:00 PM
**Deliverable:** ONE self-contained HTML file with real pulled data (not a SQL script, not a raw table export)

---

## 1. What you are building (plain language)

We want a report that answers: **"Which products are being returned the most, why, and how much is it costing us?"**

You will pull return data from Amazon and eBay separately, group it by *reason* and by *SKU*, and put the results into a clean HTML page so anyone can open it in a browser and immediately see the hotspots — no SQL knowledge needed to read it.

Think of it like a "top offenders" list: the SKUs and reasons costing us the most in refunds should be at the top.

---

## 2. Why this matters (so you understand what you're building, not just how)

- **Quality/Product team** uses this to decide which SKU needs a supplier fix, a packaging fix, or a listing fix.
- **Listing/Copywriting team** uses this if the top reason is "not as described" — that means the listing text/photos are setting the wrong expectation, not that the product is faulty.
- **Company benefit:** refunds are a direct cost. This report turns "we get a lot of returns" into "these specific SKUs and reasons are the majority of our refund cost" — so the next fix decision is obvious instead of a guess.
- **Customer benefit:** fixing the root cause means fewer customers receive the wrong/faulty item in future.

Keep this in mind while building — if a number looks like it wouldn't help someone make a decision, it probably doesn't belong in the report.

---

## 3. Scope (read this carefully before writing any SQL)

| Setting | Value |
|---|---|
| Platforms | **Amazon and eBay only** (Shopify is out of scope for today — may be added later) |
| Time window | **Last 3 months** (`request_date >= CURRENT_DATE - INTERVAL '3 months'`) |
| Data type | Real, live data pulled via `postgres:execute_sql` — never present SQL alone as the answer |
| Currency handling | **Never combine Amazon and eBay totals into one number.** Keep them in separate sections. Different currencies and fee structures make a combined total meaningless. |

---

## 4. Tables you'll use

### `public.amazon_returns`
Key columns: `sku`, `asin`, `reason`, `request_date`, `refunded_amount`, `qty`, `comments`

Reason values you'll see: `NO_REASON_GIVEN`, `NOT_AS_DESCRIBED`, `UNWANTED_ITEM`, `NOT_COMPATIBLE`, `QUALITY_UNACCEPTABLE`, `UNDELIVERABLE_UNKNOWN`, `DEFECTIVE`

### `public.ebay_returns`
Key columns: `reason`, `request_date`, `return_qty`, `seller_refund_amount`, `seller_currency`, `order_id`, `res_his_order`

⚠️ **Important:** `ebay_returns` does **not** have a `sku` column. To get the SKU you must join to `public.order_transaction` on `order_id`.

⚠️ **Important:** Always filter `res_his_order = 0` on `ebay_returns`. Any other value is a resolution-history row, not a real return, and will inflate your counts if you forget this filter.

Reason values you'll see: `DOES_NOT_FIT`, `NOT_AS_DESCRIBED`, `DAMAGED_IN_SHIPPING`, `DEFECTIVE_ITEM`, `UNWANTED_GIFT`, `CHANGED_MIND`, `MISSING_PARTS`, `WRONG_ITEM`, `ARRIVED_LATE`

---

## 5. Step-by-step build instructions

### Step 1 — Amazon: Return Reasons Summary

```sql
SELECT
    "reason",
    COUNT(*) AS return_count,
    ROUND((COUNT(*) * 100.0 / SUM(COUNT(*)) OVER())::numeric, 1) AS pct_of_total,
    SUM("refunded_amount") AS total_refunded
FROM public.amazon_returns
WHERE "request_date" >= CURRENT_DATE - INTERVAL '3 months'
GROUP BY "reason"
ORDER BY total_refunded DESC;
```

### Step 2 — Amazon: Top 15 SKUs by Refund Value

```sql
SELECT
    "sku",
    "asin",
    COUNT(*) AS return_count,
    SUM("refunded_amount") AS total_refunded
FROM public.amazon_returns
WHERE "request_date" >= CURRENT_DATE - INTERVAL '3 months'
GROUP BY "sku", "asin"
ORDER BY total_refunded DESC
LIMIT 15;
```

### Step 3 — eBay: Return Reasons Summary

```sql
SELECT
    "reason",
    COUNT(*) AS return_count,
    ROUND((COUNT(*) * 100.0 / SUM(COUNT(*)) OVER())::numeric, 1) AS pct_of_total,
    SUM("seller_refund_amount") AS total_refunded,
    "seller_currency"
FROM public.ebay_returns
WHERE "res_his_order" = 0
  AND "request_date" >= CURRENT_DATE - INTERVAL '3 months'
GROUP BY "reason", "seller_currency"
ORDER BY total_refunded DESC;
```

### Step 4 — eBay: Top 15 SKUs by Refund Value

```sql
SELECT
    ot."sku",
    COUNT(DISTINCT r."order_id") AS return_count,
    SUM(r."seller_refund_amount") AS total_refunded,
    r."seller_currency"
FROM public.ebay_returns r
LEFT JOIN public.order_transaction ot
    ON r."order_id" = ot."order_id"
WHERE r."res_his_order" = 0
  AND r."request_date" >= CURRENT_DATE - INTERVAL '3 months'
GROUP BY ot."sku", r."seller_currency"
ORDER BY total_refunded DESC
LIMIT 15;
```

### Step 5 — Run all four queries via `postgres:execute_sql` and get the real result rows.

### Step 6 — Build the HTML file (see Section 6 below).

**Optional stretch goal (only if you finish early — not required):** for each top SKU, show its single most common return reason next to it. Not mandatory for today's deadline — skip this if you're short on time.

---

## 6. HTML formatting requirements

- **One HTML file**, opens correctly in a browser, no external file dependencies required (styling can be plain CSS in a `<style>` tag inside the file).
- **Header at the top of the page** stating:
  - Report title: "Returns Reason Hotspot Report"
  - Generated date/time (today's date)
  - A one-line note: *"Snapshot as of the date above — this is not a live/auto-updating report."*
- **Four sections in this order:**
  1. Amazon — Return Reasons Summary
  2. Amazon — Top 15 SKUs by Refund Value
  3. eBay — Return Reasons Summary
  4. eBay — Top 15 SKUs by Refund Value
- **Do not merge Amazon and eBay numbers into one table or one total.**
- Rows already sorted by `total_refunded` descending from the SQL — keep that order in the HTML, don't re-shuffle it.
- Nice touch (not mandatory): shade the top 3 rows of each table (e.g. light red background) so the biggest problems are visually obvious.
- Clean formatting: bold table headers, borders or alternating row shading so it's easy to read — this is going in front of a team lead, not just a data dump.

---

## 7. Example of what a finished table should look like

**This is a mock example only — do NOT use these numbers. It exists so you know the expected shape of the output.**

### Amazon — Return Reasons Summary (example)

| Reason | Return Count | % of Total | Total Refunded (£) |
|---|---|---|---|
| NOT_AS_DESCRIBED | 42 | 31.3% | £1,284.50 |
| DEFECTIVE | 35 | 26.1% | £1,102.75 |
| UNWANTED_ITEM | 28 | 20.9% | £640.20 |
| QUALITY_UNACCEPTABLE | 18 | 13.4% | £510.00 |
| NOT_COMPATIBLE | 11 | 8.2% | £298.60 |

### Amazon — Top SKUs by Refund Value (example)

| SKU | ASIN | Return Count | Total Refunded (£) |
|---|---|---|---|
| WCFL180BM2PK | B0XXXXXXX1 | 14 | £412.30 |
| LSFT220BG3PK | B0XXXXXXX2 | 11 | £358.90 |
| TL450CH | B0XXXXXXX3 | 9 | £301.10 |

Build the eBay tables in the same shape, using eBay's own reason list and `seller_currency`.

---

## 8. Common mistakes to avoid

- ❌ Forgetting `res_his_order = 0` on `ebay_returns` (inflates counts with history rows)
- ❌ Trying to pull `sku` directly from `ebay_returns` — it doesn't exist there, you must join `order_transaction`
- ❌ Adding Amazon `refunded_amount` and eBay `seller_refund_amount` into one combined total
- ❌ Delivering the SQL query instead of the actual result data in the HTML
- ❌ Forgetting the "snapshot, not live" note in the header

---

## 9. Definition of done (check every box before sending it back)

- [ ] All 4 queries executed against the real database, real numbers in the file
- [ ] One HTML file, opens cleanly in a browser
- [ ] Header includes report title, generation date, and snapshot disclaimer
- [ ] Amazon and eBay sections kept separate — no merged totals
- [ ] All tables sorted by total refunded value, descending
- [ ] Table formatting is clean and readable (headers bold, borders/shading)
- [ ] File delivered by **3:00 PM today**

---

## 10. If you get stuck

- Reference material is already in the project: `TABLE_amazon_returns.md`, `TABLE_ebay_returns.md`, `TABLE_order_transaction.md` — these have more example queries if you need to adapt something.
- If a query errors out or returns 0 rows unexpectedly, double check the filter conditions in Section 8 first — that covers 90% of likely mistakes.
- If you're genuinely blocked for more than 15–20 minutes, message DWC directly rather than losing time — better to ask than to miss the deadline.
