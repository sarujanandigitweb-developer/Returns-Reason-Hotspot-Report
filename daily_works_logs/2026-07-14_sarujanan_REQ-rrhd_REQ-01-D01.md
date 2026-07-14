# Daily Requirement Document

---

# 1. Metadata Block

| Field | Value |
|-------|-------|
| daily_requirement_submitted_date | 2026-07-14 |
| expected_deadline_date | 2026-07-14 (Before 3:00 PM) |
| end_user | DWC |
| expected_roi | Enables rapid identification of high-return SKUs and return reasons for quality, listing, and supplier improvement decisions. Reduces manual return analysis effort. |
| developer | Sarujanan |
| project | Returns Reason Hotspot Report |
| project_code | RRHD |
| phase | Phase-01 – Discovery, Data Extraction & HTML Dashboard Delivery |
| requirement_id | REQ-01 |
| deliverable_id | REQ-01-D01 |
| blos_keys | Last 3 Months Data Only · Amazon & eBay must remain separate · eBay must filter res_his_order = 0 · Self-contained HTML only · Use real PostgreSQL data |
| domain | Returns Analytics – Amazon & eBay |
| planned_benefits | Automatically identify highest refund reasons. Highlight highest refund SKUs. Reduce manual analysis for Product and Listing teams. Deliver browser-ready HTML report with live PostgreSQL data. |

---

# 2. Today Requirement Block

## 2.1 Today Requirement

### Task Name

Returns Reason Hotspot Report Dashboard

---

### Business Purpose

Build a professional HTML dashboard that identifies:

* Products generating the highest refund cost.
* Most common return reasons.
* Top refund SKUs.
* Return hotspots for Amazon and eBay separately.

The dashboard will support Product, Listing, and Quality teams in prioritising corrective actions.

---

### Source Information

**Source System**

PostgreSQL

**Tables**

* public.amazon_returns
* public.ebay_returns
* public.order_transaction

---

### Filter Conditions

**Amazon**

* request_date >= CURRENT_DATE - INTERVAL '3 months'

**eBay**

* request_date >= CURRENT_DATE - INTERVAL '3 months'
* res_his_order = 0

**Platform Scope**

* Amazon
* eBay
* (Shopify excluded)

---

### Required Data Output

**Amazon Return Reasons Summary**

| Field | Purpose |
|-------|---------|
| Reason | Return category |
| Return Count | Number of returns |
| % of Total | Contribution percentage |
| Total Refunded | Refund value |

**Amazon Top 15 Refund SKUs**

| Field | Purpose |
|-------|---------|
| SKU | Product identifier |
| ASIN | Amazon product |
| Return Count | Number of returns |
| Total Refunded | Refund value |

**eBay Return Reasons Summary**

| Field | Purpose |
|-------|---------|
| Reason | Return category |
| Return Count | Number of returns |
| % of Total | Contribution percentage |
| Total Refunded | Refund value |
| Seller Currency | Currency grouping |

**eBay Top 15 Refund SKUs**

| Field | Purpose |
|-------|---------|
| SKU | Product identifier |
| Return Count | Number of returns |
| Total Refunded | Refund value |
| Seller Currency | Currency grouping |

---

# 3. Business Logic Block

## Amazon

### Rules

* Filter last 3 months.
* Group by Return Reason.
* Group by SKU and ASIN.
* Sort by Total Refunded descending.

---

## eBay

### Rules

* Filter last 3 months.
* Apply res_his_order = 0.
* Join order_transaction to obtain SKU.
* Group by Return Reason.
* Group by SKU.
* Keep currency separated.
* Sort by Total Refunded descending.

---

## Dashboard Rules

* Single self-contained HTML file (index.html).
* Internal CSS and JavaScript only.
* Header theme colour #15243D.
* Display generated date/time.
* Display snapshot disclaimer.
* Amazon and eBay sections must remain completely separate.
* Highlight Top 3 rows in each table.
* Professional responsive layout.
* Browser-ready without external dependencies.

---

# 4. Data Enrichment Block

## Purpose

Enhance the dashboard with business-friendly presentation and summary information.

## Source

PostgreSQL Query Results

## Required Data

| Field | Reason |
|-------|--------|
| Generated Date | Snapshot timestamp |
| Report Title | Dashboard heading |
| Platform | Amazon / eBay separation |
| Currency | Display refund values correctly |
| KPI Cards | Executive summary |
| Top 3 Highlight | Visual hotspot identification |
| Table Styling | Improved readability |
| Snapshot Disclaimer | Inform users report is not live |

---

# 5. Today's Planned Deliverables

* Execute all required PostgreSQL queries.
* Validate returned datasets.
* Prepare embedded JavaScript data.
* Develop a professional index.html dashboard.
* Build all four required report sections.
* Validate HTML rendering.
* Produce final browser-ready dashboard.
* Save evidence and validation outputs.
