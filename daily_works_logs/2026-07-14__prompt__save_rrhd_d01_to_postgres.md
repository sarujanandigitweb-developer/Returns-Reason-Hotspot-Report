# Claude Code Prompt — Save RRHD D01 Daily Progress to PostgreSQL

**NOT YET RUN.** Copy everything inside the fenced block below into Claude Code as a single prompt.

---

````text
Use the connected PostgreSQL MCP to save today's RRHD daily progress record.

## TARGET
Schema: daily_task
Table:  daily_task.tbl_rrhd_sarujanan

## SOURCE
CSV:   daily_works_logs/2026-07-14__sarujanan__rrhd_daily-activities.csv
Skill: daily_works_logs/2026-07-14__sarujanan__rrhd__REQ-02-D01.md
Rows:  14  (activity_id D01-A01 .. D01-A14, all activity_date = 2026-07-14)

## STEP 1 — EXISTENCE CHECK (do this first, do not assume)
Run:
    SELECT to_regclass('daily_task.tbl_rrhd_sarujanan') AS tbl;

- Returns NULL   -> the table does NOT exist. Do STEP 2, then STEP 3.
- Returns a name -> the table EXISTS. SKIP STEP 2. Go straight to STEP 3.

Do not trust any prior claim about whether this table exists. Verify with the query.
As of 2026-07-14 this table did NOT exist; the daily_task schema DID, holding 30+ sibling
tables including daily_task.tbl_prsd_sarujanan. Re-verify anyway — never assume.

## STEP 2 — CREATE (only if STEP 1 returned NULL)
Mirror daily_task.tbl_prsd_sarujanan exactly — same 25 columns, same PK, same defaults.

    CREATE SCHEMA IF NOT EXISTS daily_task;

    CREATE TABLE IF NOT EXISTS daily_task.tbl_rrhd_sarujanan (
      project_code                 text        NOT NULL,
      activity_id                  text        NOT NULL,
      activity_date                date        NOT NULL DEFAULT CURRENT_DATE,
      developer                    text        NOT NULL DEFAULT 'sarujanan',
      project_name                 text,
      requirement_id               text,
      deliverable_id               text,
      activity_type                text        NOT NULL,
      activity_title               text        NOT NULL,
      activity_summary             text        NOT NULL,
      systems_touched              text,
      files_touched                text,
      evidence_refs                text,
      reusable_asset_created       boolean     NOT NULL DEFAULT false,
      reusable_pattern             text,
      validation_rule              text,
      gap_or_risk                  text,
      next_action                  text,
      status                       text        NOT NULL DEFAULT 'completed',
      priority                     text        NOT NULL DEFAULT 'medium',
      llm_queryable                boolean     NOT NULL DEFAULT true,
      company_knowledge_candidate  boolean     NOT NULL DEFAULT false,
      memory_tags                  text,
      source_skill_file            text,
      source_type                  text        NOT NULL DEFAULT 'skill_file',
      created_at                   timestamptz NOT NULL DEFAULT now(),
      updated_at                   timestamptz NOT NULL DEFAULT now(),
      CONSTRAINT pk_tbl_rrhd_sarujanan PRIMARY KEY (project_code, activity_id)
    );

## STEP 3 — INSERT (idempotent)
Insert all 14 rows from the CSV.

Primary key is (project_code, activity_id). Use an UPSERT so re-running never duplicates:

    INSERT INTO daily_task.tbl_rrhd_sarujanan (...25 columns...)
    VALUES (...), (...), ...
    ON CONFLICT (project_code, activity_id) DO UPDATE SET
      activity_date               = EXCLUDED.activity_date,
      developer                   = EXCLUDED.developer,
      project_name                = EXCLUDED.project_name,
      requirement_id              = EXCLUDED.requirement_id,
      deliverable_id              = EXCLUDED.deliverable_id,
      activity_type               = EXCLUDED.activity_type,
      activity_title              = EXCLUDED.activity_title,
      activity_summary            = EXCLUDED.activity_summary,
      systems_touched             = EXCLUDED.systems_touched,
      files_touched               = EXCLUDED.files_touched,
      evidence_refs               = EXCLUDED.evidence_refs,
      reusable_asset_created      = EXCLUDED.reusable_asset_created,
      reusable_pattern            = EXCLUDED.reusable_pattern,
      validation_rule             = EXCLUDED.validation_rule,
      gap_or_risk                 = EXCLUDED.gap_or_risk,
      next_action                 = EXCLUDED.next_action,
      status                      = EXCLUDED.status,
      priority                    = EXCLUDED.priority,
      llm_queryable               = EXCLUDED.llm_queryable,
      company_knowledge_candidate = EXCLUDED.company_knowledge_candidate,
      memory_tags                 = EXCLUDED.memory_tags,
      source_skill_file           = EXCLUDED.source_skill_file,
      source_type                 = EXCLUDED.source_type,
      updated_at                  = now()
    RETURNING activity_id, (xmax = 0) AS inserted;

Rules:
- Escape single quotes by doubling them ('').
- Cast booleans explicitly: reusable_asset_created, llm_queryable, company_knowledge_candidate.
- Do NOT insert created_at / updated_at literals — let the defaults fire.
- Do NOT alter, drop or truncate anything. INSERT and CREATE only.
- Write ONLY to daily_task.tbl_rrhd_sarujanan. Touch no other schema or table.
- Never write customer PII into this table. No order-level customer data appears in these rows.
- Never write the database password into this table. It appears in no row.

## STEP 4 — VALIDATION (STOP on any failure)
Abort and report if any of these fail. Do not "fix and continue".

1. Row count for 2026-07-14 is exactly 14.
2. activity_id values are exactly D01-A01 .. D01-A14 — no gaps, no duplicates.
3. No NOT NULL column is null.
4. No other daily_task table was touched — in particular daily_task.tbl_prsd_sarujanan
   must be unchanged. Compare its max(updated_at) before and after; it must not move.
5. RETURNING reports 14 inserted on a first run, or 0 inserted / 14 updated on a re-run.
   Any other split means the key is wrong — STOP.

## STEP 5 — CONFIRM WITH A SELECT (required before closing)
Run all four and print the results:

    -- 5a. The 14 rows just written
    SELECT activity_id, activity_date, activity_type, priority, status, activity_title
    FROM daily_task.tbl_rrhd_sarujanan
    WHERE activity_date = DATE '2026-07-14'
    ORDER BY activity_id;

    -- 5b. Count + integrity
    SELECT activity_date, count(*) AS rows,
           count(*) FILTER (WHERE status = 'completed') AS completed,
           count(DISTINCT activity_id) AS distinct_ids
    FROM daily_task.tbl_rrhd_sarujanan
    GROUP BY activity_date ORDER BY activity_date;
    -- expect: 2026-07-14 -> 14 rows, 14 distinct ids

    -- 5c. Prove the sibling PRSD memory was not disturbed
    SELECT count(*) AS prsd_rows, max(updated_at) AS prsd_last_touched
    FROM daily_task.tbl_prsd_sarujanan;

    -- 5d. The critical findings are queryable
    SELECT activity_id, priority, status, gap_or_risk
    FROM daily_task.tbl_rrhd_sarujanan
    WHERE activity_date = DATE '2026-07-14' AND priority = 'critical'
    ORDER BY activity_id;
    -- expect 6 rows: D01-A02 (eBay join fan-out +12.7%),
    --                D01-A03 (Amazon multi-currency sum),
    --                D01-A07 (Amazon refund coverage 42.7% NULL),
    --                D01-A08 (return rate not computable - SKU key mismatch),
    --                D01-A11 (non-deterministic ORDER BY - 760/2106 rows),
    --                D01-A13 (stale SQL file - would have gutted the dashboard),
    --                D01-A14 (credential exposure - rotate temp_user)

## STEP 6 — REPORT
State plainly:
- Whether the table already existed or was created.
- Rows inserted vs updated (from the RETURNING split).
- The output of 5a, 5b, 5c and 5d.
- Confirm daily_task.tbl_prsd_sarujanan is untouched.

If any STEP 4 validation fails, report the failure and the exact SQL that failed.
Do not report success. Do not summarise around a failure.
````

---

## Record being saved — 14 activities (2026-07-14, D01)

| activity_id | Type | Priority | Status | Title |
|---|---|---|---|---|
| D01-A01 | discovery | medium | completed | No existing returns dashboard — confirmed build, not extend |
| D01-A02 | investigation | **critical** | completed | **DR-001** — eBay SKU join double-counts refunds by **+12.7%** |
| D01-A03 | investigation | **critical** | completed | Requirement's Amazon SQL sums **4 currencies** into one `£` number |
| D01-A04 | investigation | high | completed | `CR-` prefix drift splits one reason across two rows |
| D01-A05 | implementation | high | completed | Self-contained HTML report built from real pulled data |
| D01-A06 | validation | high | completed | Zero-trust revalidation — 896 cells re-diffed |
| D01-A07 | investigation | **critical** | gap_identified | **Amazon refund coverage 42.7% NULL** — undisclosed on the page |
| D01-A08 | investigation | **critical** | gap_identified | **Return rate not computable** — Amazon SKU key mismatch (46%) |
| D01-A09 | implementation | high | completed | Rebuilt as tabbed dashboard — all 2,106 records, no top-15 cap |
| D01-A10 | implementation | medium | completed | Units / Marketplace / Last Return added after fan-out test |
| D01-A11 | investigation | **critical** | completed | Non-deterministic `ORDER BY` — 760/2,106 rows reshuffle |
| D01-A12 | implementation | high | completed | Daily refresh script — fails closed, atomic, backed up |
| D01-A13 | investigation | **critical** | completed | **Stale SQL file would have gutted the dashboard** (817 → 15 rows) |
| D01-A14 | implementation | **critical** | follow_up_required | `.env` migration — **credential exposed, rotate `temp_user`** |

## Duplicate risk: GREEN

- `daily_task.tbl_rrhd_sarujanan` **does not exist** — verified 2026-07-14. No prior RRHD memory to conflict with.
- The CSV follows the **existing 25-column PRSD standard exactly** — no competing schema was created.
- Dedup key `(project_code, activity_id)` matches the sibling table's PK. `project_code = 'rrhd'` is unique across the 30+ tables in `daily_task`.
- The UPSERT is idempotent: re-running writes 0 new rows.

## ⚠️ Escalation carried in this record

`D01-A14` carries a **credential exposure**. The `temp_user` password was transmitted in
plaintext and lived in the refresh script's source before migration. **It must be rotated.**
The password appears in **no row of this CSV** and must never be written to the memory table.
