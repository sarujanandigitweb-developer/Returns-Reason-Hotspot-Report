# Claude Code Prompt — Save RRHD D03 Daily Progress to PostgreSQL

**ALREADY RUN.** On 2026-07-16 this record was inserted directly via the PostgreSQL MCP:
all 4 rows returned `inserted = true`, and a confirming SELECT shows D01 (14) / D02 (12) /
D03 (4) = 30 rows total, with D01 and D02 untouched. The fenced block below reproduces the
same operation for re-run / audit (the UPSERT is idempotent — re-running writes 0 new rows).

---

````text
Use the connected PostgreSQL MCP to save today's RRHD D03 daily progress record.

## TARGET
Schema: daily_task
Table:  daily_task.tbl_rrhd_sarujanan

## SOURCE
CSV:   daily_works_logs/2026-07-16__sarujanan__rrhd_daily-activities.csv
Skill: daily_works_logs/2026-07-16__sarujanan__rrhd__REQ-01-D03.md
Rows:  4  (activity_id D03-A01 .. D03-A04, all activity_date = 2026-07-16, deliverable_id = D03)

## STEP 1 — EXISTENCE CHECK (do this first, do not assume)
Run:
    SELECT to_regclass('daily_task.tbl_rrhd_sarujanan') AS tbl;

- Returns a name -> the table EXISTS. SKIP STEP 2. Go straight to STEP 3 (INSERT).
- Returns NULL   -> the table does NOT exist. Do STEP 2 (CREATE), then STEP 3.

As of 2026-07-16 the table EXISTS (26 rows before this insert: 14 D01 + 12 D02), so this
run INSERTs 4 rows. Verify with the query anyway; do not trust this note blindly.

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

## STEP 3 — INSERT the 4 D03 rows (idempotent)
Read the 4 rows from the CSV and INSERT them. The 25 CSV columns map 1:1 to the table's first
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
      (...4 rows from the CSV...)
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
- Never write any database password into this table (none appears in the rows).

## STEP 4 — VALIDATION (STOP on any failure; do not "fix and continue")
1. Row count for 2026-07-16 is exactly 4.
2. activity_id values are exactly D03-A01 .. D03-A04 — no gaps, no duplicates.
3. No NOT NULL column is null.
4. The existing D01 (2026-07-14) and D02 (2026-07-15) rows are UNTOUCHED — compare
   max(updated_at) for those dates before and after; it must not change.
5. RETURNING reports 4 inserted on a first run, or 0 inserted / 4 updated on a re-run.

## STEP 5 — CONFIRM WITH A SELECT (required before closing)

    -- 5a. The 4 rows just written
    SELECT activity_id, activity_date, activity_type, priority, status, activity_title
    FROM daily_task.tbl_rrhd_sarujanan
    WHERE activity_date = DATE '2026-07-16'
    ORDER BY activity_id;

    -- 5b. Count + integrity across all three deliverables
    SELECT deliverable_id, activity_date, count(*) AS rows,
           count(*) FILTER (WHERE status='completed') AS completed,
           count(DISTINCT activity_id) AS distinct_ids
    FROM daily_task.tbl_rrhd_sarujanan
    GROUP BY deliverable_id, activity_date ORDER BY activity_date;
    -- expect: D01 -> 14 rows, D02 -> 12 rows, D03 -> 4 rows

    -- 5c. The D03 findings are queryable
    SELECT activity_id, priority, gap_or_risk
    FROM daily_task.tbl_rrhd_sarujanan
    WHERE activity_date = DATE '2026-07-16' AND priority IN ('critical','high')
    ORDER BY activity_id;
    -- expect 4 rows, all priority = 'high', and 0 rows at 'critical'.
    -- Priority bar (set by D01/D02): 'critical' is reserved for wrong numbers shipped,
    -- wrong attribution shipped, an undisclosed material gap, unstable/destroyed output,
    -- or a security exposure. D03 is title-completeness + refresh automation: blank is not
    -- wrong, and A04 mirrors D01-A12 (built the refresh script) which was rated 'high'.

## STEP 6 — REPORT
State plainly: table existed or created; rows inserted vs updated (RETURNING split);
output of 5a/5b/5c; and confirm D01 + D02 rows are untouched.
If any STEP 4 validation fails, report the failure and the exact SQL that failed.
````

---

## Record saved — 4 activities (2026-07-16, D03, REQ-01)

| activity_id | Type | Priority | Title |
|---|---|---|---|
| D03-A01 | investigation | high | eBay blank-title root cause — titles live in `order_item_info`, not `listing_data` |
| D03-A02 | investigation | high | Amazon blank titles recovered by ASIN; discovered dual-backend `order_management_copy` |
| D03-A03 | validation | high | Dashboard verified, auto-vs-Claude output compared, daily 10:00 cron configured |
| D03-A04 | implementation | high | Wired Mismatch Candidates into the daily refresh — deterministic `const MISMATCH` regeneration |

> **Priority note.** A01 and A04 were first recorded as `critical` and corrected to `high` on
> review. Against the D01/D02 bar, `critical` means wrong numbers or wrong attribution shipped,
> an undisclosed material gap, unstable/destroyed output, or a security exposure. D03-A01 fixed
> **blank** (not wrong) titles while every decision-driving field stayed correct, and it closes
> D02 GAP-2 which D02 itself rated HIGH. D03-A04 closes D02 GAP-4 (rated MEDIUM) and mirrors
> D01-A12 "built the refresh script", which was rated `high`.

## Duplicate-risk: GREEN
- Table already held **26 rows (14 D01 + 12 D02), 0 D03** — no conflict.
- Dedup key `(project_code, activity_id)` = the table PK; UPSERT is idempotent.
- Insert confirmed: 4 rows `inserted = true`; post-insert totals D01 14 / D02 12 / D03 4 = 30.

## Carried-over escalations (still open)
- The `temp_user` database password was exposed in plaintext (D01) and **must be rotated**. It appears in no CSV row and was never written to the memory table.
- **New (D03):** MCP and the refresh `.env` resolve to two different databases both named `order_management_copy`; reconcile / pin one authoritative backend.
