# Claude Code Prompt — Save RRHD D02 Daily Progress to PostgreSQL

**NOT YET RUN.** Copy everything inside the fenced block below into Claude Code as a single prompt.
It uses the connected PostgreSQL MCP. As of 2026-07-15 the target table EXISTS (14 rows, all D01 /
2026-07-14), so this run will INSERT — but the prompt still handles the create-if-missing case.

---

````text
Use the connected PostgreSQL MCP to save today's RRHD D02 daily progress record.

## TARGET
Schema: daily_task
Table:  daily_task.tbl_rrhd_sarujanan

## SOURCE
CSV:   daily_works_logs/2026-07-15__sarujanan__rrhd_daily-activities.csv
Skill: daily_works_logs/2026-07-15__sarujanan__rrhd__REQ-01-D02.md
Rows:  12  (activity_id D02-A01 .. D02-A12, all activity_date = 2026-07-15, deliverable_id = D02)

## STEP 1 — EXISTENCE CHECK (do this first, do not assume)
Run:
    SELECT to_regclass('daily_task.tbl_rrhd_sarujanan') AS tbl;

- Returns a name -> the table EXISTS. SKIP STEP 2. Go straight to STEP 3 (INSERT).
- Returns NULL   -> the table does NOT exist. Do STEP 2 (CREATE), then STEP 3.

Do not trust any prior claim about whether this table exists. Verify with the query.

## STEP 2 — CREATE (only if STEP 1 returned NULL)
Mirror the existing daily_task standard exactly — 25 data columns + timestamps, PK
(project_code, activity_id), and the CHECK constraints below.

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
      CONSTRAINT pk_rrhd_sarujanan PRIMARY KEY (project_code, activity_id),
      CONSTRAINT ck_rrhd_sarujanan_activity_type_format CHECK (activity_type ~ '^[a-z][a-z0-9_]*$'),
      CONSTRAINT ck_rrhd_sarujanan_priority   CHECK (priority = ANY (ARRAY['low','medium','high','critical'])),
      CONSTRAINT ck_rrhd_sarujanan_status     CHECK (status = ANY (ARRAY['completed','handoff_ready','gap_identified','validation_needed','follow_up_required','in_progress','blocked'])),
      CONSTRAINT ck_rrhd_sarujanan_source_type CHECK (source_type = ANY (ARRAY['skill_file','manual','import','automation'])),
      CONSTRAINT ck_rrhd_sarujanan_updated_after_created CHECK (updated_at >= created_at)
    );
    CREATE INDEX IF NOT EXISTS idx_rrhd_sarujanan_activity_date  ON daily_task.tbl_rrhd_sarujanan (activity_date DESC);
    CREATE INDEX IF NOT EXISTS idx_rrhd_sarujanan_activity_type  ON daily_task.tbl_rrhd_sarujanan (activity_type);
    CREATE INDEX IF NOT EXISTS idx_rrhd_sarujanan_deliverable_id ON daily_task.tbl_rrhd_sarujanan (deliverable_id);
    CREATE INDEX IF NOT EXISTS idx_rrhd_sarujanan_developer      ON daily_task.tbl_rrhd_sarujanan (developer);
    CREATE INDEX IF NOT EXISTS idx_rrhd_sarujanan_requirement_id ON daily_task.tbl_rrhd_sarujanan (requirement_id);
    CREATE INDEX IF NOT EXISTS idx_rrhd_sarujanan_status         ON daily_task.tbl_rrhd_sarujanan (status);

## STEP 3 — INSERT the 12 D02 rows (idempotent)
Read the 12 rows from the CSV and INSERT them. The 25 CSV columns map 1:1 to the table's first
25 columns (do NOT set created_at / updated_at — let the defaults fire). Primary key is
(project_code, activity_id); use an UPSERT so re-running never duplicates:

    INSERT INTO daily_task.tbl_rrhd_sarujanan (
      activity_id, activity_date, developer, project_code, project_name, requirement_id,
      deliverable_id, activity_type, activity_title, activity_summary, systems_touched,
      files_touched, evidence_refs, reusable_asset_created, reusable_pattern, validation_rule,
      gap_or_risk, next_action, status, priority, llm_queryable, company_knowledge_candidate,
      memory_tags, source_skill_file, source_type
    )
    VALUES
      (...12 rows from the CSV...)
    ON CONFLICT (project_code, activity_id) DO UPDATE SET
      activity_date=EXCLUDED.activity_date, developer=EXCLUDED.developer,
      project_name=EXCLUDED.project_name, requirement_id=EXCLUDED.requirement_id,
      deliverable_id=EXCLUDED.deliverable_id, activity_type=EXCLUDED.activity_type,
      activity_title=EXCLUDED.activity_title, activity_summary=EXCLUDED.activity_summary,
      systems_touched=EXCLUDED.systems_touched, files_touched=EXCLUDED.files_touched,
      evidence_refs=EXCLUDED.evidence_refs, reusable_asset_created=EXCLUDED.reusable_asset_created,
      reusable_pattern=EXCLUDED.reusable_pattern, validation_rule=EXCLUDED.validation_rule,
      gap_or_risk=EXCLUDED.gap_or_risk, next_action=EXCLUDED.next_action,
      status=EXCLUDED.status, priority=EXCLUDED.priority, llm_queryable=EXCLUDED.llm_queryable,
      company_knowledge_candidate=EXCLUDED.company_knowledge_candidate,
      memory_tags=EXCLUDED.memory_tags, source_skill_file=EXCLUDED.source_skill_file,
      source_type=EXCLUDED.source_type, updated_at=now()
    RETURNING activity_id, (xmax = 0) AS inserted;

Rules:
- Escape single quotes by doubling them ('').
- Cast booleans explicitly (reusable_asset_created, llm_queryable, company_knowledge_candidate).
- Do NOT alter, drop or truncate anything. INSERT (and CREATE if STEP 2) only.
- Write ONLY to daily_task.tbl_rrhd_sarujanan. Touch no other schema or table.
- Never write customer PII or any database password into this table (none appears in the rows).

## STEP 4 — VALIDATION (STOP on any failure; do not "fix and continue")
1. Row count for 2026-07-15 is exactly 12.
2. activity_id values are exactly D02-A01 .. D02-A12 — no gaps, no duplicates.
3. No NOT NULL column is null.
4. The existing D01 rows (2026-07-14) are UNTOUCHED — compare max(updated_at) for
   activity_date = 2026-07-14 before and after; it must not change.
5. RETURNING reports 12 inserted on a first run, or 0 inserted / 12 updated on a re-run.
   Any other split means the key is wrong — STOP.

## STEP 5 — CONFIRM WITH A SELECT (required before closing)
Run all four and print the results:

    -- 5a. The 12 rows just written
    SELECT activity_id, activity_date, activity_type, priority, status, activity_title
    FROM daily_task.tbl_rrhd_sarujanan
    WHERE activity_date = DATE '2026-07-15'
    ORDER BY activity_id;

    -- 5b. Count + integrity across both deliverables
    SELECT deliverable_id, activity_date, count(*) AS rows,
           count(*) FILTER (WHERE status='completed') AS completed,
           count(DISTINCT activity_id) AS distinct_ids
    FROM daily_task.tbl_rrhd_sarujanan
    GROUP BY deliverable_id, activity_date ORDER BY activity_date;
    -- expect: D01 / 2026-07-14 -> 14 rows, D02 / 2026-07-15 -> 12 rows

    -- 5c. Prove D01 was not disturbed
    SELECT count(*) AS d01_rows, max(updated_at) AS d01_last_touched
    FROM daily_task.tbl_rrhd_sarujanan WHERE activity_date = DATE '2026-07-14';

    -- 5d. The critical D02 findings are queryable
    SELECT activity_id, priority, gap_or_risk
    FROM daily_task.tbl_rrhd_sarujanan
    WHERE activity_date = DATE '2026-07-15' AND priority = 'critical'
    ORDER BY activity_id;
    -- expect 2 rows: D02-A01 (Amazon NAD reason signal wrong / AMZ-PG-BAD-DESC),
    --                D02-A11 (eBay title correctness — item_id keying, mojibake)

## STEP 6 — REPORT
State plainly:
- Whether the table already existed or was created.
- Rows inserted vs updated (from the RETURNING split).
- The output of 5a, 5b, 5c and 5d.
- Confirm the 2026-07-14 (D01) rows are untouched.

If any STEP 4 validation fails, report the failure and the exact SQL that failed.
Do not report success. Do not summarise around a failure.
````

---

## Record being saved — 12 activities (2026-07-15, D02, REQ-01)

| activity_id | Type | Priority | Title |
|---|---|---|---|
| D02-A01 | investigation | **critical** | Amazon NAD reason signal wrong in brief — `AMZ-PG-BAD-DESC`, not literal `NOT_AS_DESCRIBED` |
| D02-A02 | investigation | high | Reused validated eBay bridge; proved 0 eBay candidates is real (max 2/SKU) |
| D02-A03 | implementation | high | `listing_data` integration — `wrong_sku=0`, COALESCE SKU, dedup fan-out |
| D02-A04 | implementation | high | Built the NAD Mismatch section as a 5th tab in the existing dashboard |
| D02-A05 | validation | high | Zero-trust eBay validation — fixed a structureless empty state |
| D02-A06 | implementation | low | Moved the Flag column to the right |
| D02-A07 | implementation | low | Made Last Return sortable on all four tables |
| D02-A08 | implementation | high | Removed threshold — show all 175/69 with pagination; badge marks strict candidates |
| D02-A09 | implementation | medium | Amazon/eBay sub-tabs — fixed "eBay not appearing" |
| D02-A10 | investigation | medium | Sticky-header offset bug (`overflow-x:auto` scroll container); reviewer CSS fix kept |
| D02-A11 | investigation | **critical** | **eBay title correctness** — item_id keying, English-preferred, mojibake removed |
| D02-A12 | implementation | medium | Restored KPI summary cards / removed Data Notes (corrected an ambiguous instruction) |

## Duplicate-risk: GREEN
- Table exists with **14 D01 rows only**; **0 D02 rows** — no conflict.
- CSV follows the existing 25-column standard exactly; dedup key `(project_code, activity_id)` = the table PK.
- UPSERT is idempotent: re-running writes 0 new rows.

## Carried-over escalation (from D01, still open)
The `temp_user` database password was exposed in plaintext earlier in this project and **must be rotated**. It appears in no row of this CSV and must never be written to the memory table.
