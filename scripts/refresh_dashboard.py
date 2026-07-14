#!/usr/bin/env python3
"""
Returns Reason Hotspot Dashboard — daily data refresh.

Re-runs the four queries in sql/returns_hotspot_queries.sql against PostgreSQL
and rewrites ONLY the embedded data block inside the dashboard HTML. All HTML,
CSS and JavaScript are preserved byte-for-byte.

Run manually:
    python3 scripts/refresh_dashboard.py

Schedule daily at 09:00 (see README section at the bottom of this file):
    0 9 * * * /usr/bin/python3 /home/led-247/Returns-Reason-Hotspot-Report/scripts/refresh_dashboard.py

Safety properties:
  * The dashboard is only overwritten once every query has succeeded and the
    output has passed sanity checks. Any failure leaves the previous dashboard
    completely untouched and exits non-zero.
  * The write is atomic (temp file + os.replace), so a crash mid-write cannot
    leave a truncated dashboard on disk.
  * A timestamped backup of the previous dashboard is kept.
"""

from __future__ import annotations

import json
import logging
import os
import re
import shutil
import sys
import time
from datetime import date, datetime
from decimal import Decimal
from pathlib import Path

try:
    import psycopg2
except ImportError:  # pragma: no cover
    sys.stderr.write("psycopg2 is required:  pip install psycopg2-binary\n")
    sys.exit(2)

try:
    from dotenv import load_dotenv
except ImportError:  # pragma: no cover
    sys.stderr.write("python-dotenv is required:  pip install python-dotenv\n")
    sys.exit(2)


PROJECT   = Path(__file__).resolve().parent.parent


# --------------------------------------------------------------------------
# Configuration — credentials come from .env, never from this file.
# --------------------------------------------------------------------------
# The path is explicit on purpose. Bare load_dotenv() searches the *current
# working directory*, and cron runs jobs from $HOME — so it would never find
# the project's .env and the 09:00 job would fail every morning. Anchoring to
# the project root makes the script work identically from any cwd.
ENV_FILE = PROJECT / ".env"
load_dotenv(ENV_FILE)

REQUIRED_ENV = ["PGHOST", "PGPORT", "PGDATABASE", "PGUSER", "PGPASSWORD"]


def load_db_config() -> dict:
    """Build DB_CONFIG from the environment. No fallbacks — missing means stop."""
    missing = [k for k in REQUIRED_ENV if not os.environ.get(k)]
    if missing:
        print("\n----------------------------------", file=sys.stderr)
        print("Dashboard Refresh FAILED", file=sys.stderr)
        print("Missing required environment variable:", file=sys.stderr)
        for k in missing:
            print(f"  {k}", file=sys.stderr)
        if not ENV_FILE.is_file():
            print(f"\nNo .env file found at: {ENV_FILE}", file=sys.stderr)
            print("Create one from the template:", file=sys.stderr)
            print(f"  cp {PROJECT / '.env.example'} {ENV_FILE}", file=sys.stderr)
            print("then fill in the credentials.", file=sys.stderr)
        else:
            print(f"\n.env found at {ENV_FILE}, but the variable(s) above are "
                  f"absent or empty.", file=sys.stderr)
        print("\nNot connecting. Dashboard left unchanged.", file=sys.stderr)
        print("----------------------------------\n", file=sys.stderr)
        sys.exit(1)

    return {
        "host":     os.environ["PGHOST"],
        "port":     os.environ["PGPORT"],
        "dbname":   os.environ["PGDATABASE"],
        "user":     os.environ["PGUSER"],
        "password": os.environ["PGPASSWORD"],
    }


DB_CONFIG = load_db_config()
CONNECT_TIMEOUT = 30
STATEMENT_TIMEOUT_MS = 120_000  # a runaway query must not hang the cron job

SQL_FILE  = PROJECT / "sql" / "returns_hotspot_queries.sql"
LOG_DIR   = PROJECT / "logs"
LOG_FILE  = LOG_DIR / "dashboard_refresh.log"
BACKUP_DIR = PROJECT / "backups"

# The dashboard has moved before, so find it rather than assume.
HTML_CANDIDATES = [
    PROJECT / "Dashboard" / "index.html",
    PROJECT / "index.html",
    PROJECT / "dashboard" / "index.html",
]

# Currency scopes the dashboard renders. Fixed order, so the emitted JSON is
# stable and diffable between runs.
CURRENCIES = ["GBP", "EUR", "USD", "CAD", "UNSPECIFIED"]

# Each query's rows become one array per currency, in exactly the column order
# the dashboard's build() function unpacks. Changing these tuples changes the
# dashboard's data contract — don't, without changing build() to match.
#   AMAZON_REASONS: [reason, count, pct, refund, units, lastReturn]
#   AMAZON_SKUS   : [sku, asin, count, refund, topReason, units, marketplace, lastReturn]
#   EBAY_REASONS  : [reason, count, pct, refund, units, lastReturn]
#   EBAY_SKUS     : [sku, count, refund, topReason, units, marketplace, lastReturn]
QUERY_TO_KEY = {
    "amazon_reasons": "AMAZON_REASONS",
    "amazon_skus":    "AMAZON_SKUS",
    "ebay_reasons":   "EBAY_REASONS",
    "ebay_skus":      "EBAY_SKUS",
}

# Sanity floors. A refresh that returns wildly less than the validated dashboard
# is far more likely to be a broken filter than a real collapse in returns, and
# must not be allowed to silently overwrite a good dashboard.
MIN_ROWS = {
    "amazon_reasons": 40,
    "amazon_skus":    900,
    "ebay_reasons":   20,
    "ebay_skus":      250,
}


# --------------------------------------------------------------------------
# Logging
# --------------------------------------------------------------------------
def setup_logging() -> logging.Logger:
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    logger = logging.getLogger("refresh")
    logger.setLevel(logging.INFO)
    logger.handlers.clear()

    fh = logging.FileHandler(LOG_FILE, encoding="utf-8")  # append is the default
    fh.setFormatter(logging.Formatter("%(asctime)s | %(levelname)-7s | %(message)s",
                                      datefmt="%Y-%m-%d %H:%M:%S"))
    logger.addHandler(fh)

    sh = logging.StreamHandler(sys.stdout)
    sh.setFormatter(logging.Formatter("%(message)s"))
    logger.addHandler(sh)
    return logger


# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------
def find_dashboard() -> Path:
    for p in HTML_CANDIDATES:
        if p.is_file():
            return p
    raise FileNotFoundError(
        "Dashboard HTML not found. Looked in:\n  " +
        "\n  ".join(str(p) for p in HTML_CANDIDATES)
    )


def parse_sql(path: Path) -> "dict[str, str]":
    """Split the .sql file on '-- name: <id>' markers, preserving each block."""
    if not path.is_file():
        raise FileNotFoundError(f"SQL file not found: {path}")
    text = path.read_text(encoding="utf-8")

    parts = re.split(r"^--\s*name:\s*([a-z_]+)\s*$", text, flags=re.MULTILINE)
    # re.split with one capture group -> [preamble, name1, body1, name2, body2, ...]
    queries: "dict[str, str]" = {}
    for i in range(1, len(parts) - 1, 2):
        name = parts[i].strip()
        body = parts[i + 1].strip()
        if body:
            queries[name] = body

    missing = set(QUERY_TO_KEY) - set(queries)
    if missing:
        raise ValueError(
            f"{path.name} is missing query block(s): {', '.join(sorted(missing))}. "
            "Each query must be preceded by a '-- name: <id>' marker."
        )
    return queries


def jsonable(v):
    """Postgres types -> JSON. Decimals become float; a whole number stays whole."""
    if isinstance(v, Decimal):
        f = float(v)
        return int(f) if f.is_integer() else f
    if isinstance(v, (datetime, date)):
        return v.isoformat()[:10]
    return v


def group_by_currency(rows: "list[tuple]") -> "dict[str, list]":
    """First column is the currency scope; the rest become the row, in order."""
    out = {c: [] for c in CURRENCIES}
    for row in rows:
        ccy = row[0]
        if ccy not in out:      # a currency the dashboard doesn't render yet
            out[ccy] = []
        out[ccy].append([jsonable(v) for v in row[1:]])
    return out


def replace_data_block(html: str, data_js: str, generated: str) -> str:
    """
    Swap ONLY `const DATA = {...};` (brace-balanced) and the GENERATED_AT string.
    Everything else in the file — markup, CSS, every line of JS — is untouched.
    """
    marker = None
    for candidate in ("const DATA = ", "const DATA=", "const dashboardData = ", "const dashboardData="):
        if candidate in html:
            marker = candidate
            break
    if marker is None:
        raise ValueError("Could not find the embedded data marker "
                         "(`const DATA = ...` or `const dashboardData = ...`) in the dashboard.")

    start = html.index(marker)
    brace = html.index("{", start)
    depth = 0
    end = None
    for i in range(brace, len(html)):
        ch = html[i]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                end = html.index(";", i) + 1
                break
    if end is None:
        raise ValueError("The embedded data block is malformed — unbalanced braces.")

    html = html[:start] + f"const DATA = {data_js};" + html[end:]

    # Keep the header's date honest; otherwise the page claims a stale snapshot date.
    html, n = re.subn(r'const GENERATED_AT\s*=\s*"[^"]*"',
                      f'const GENERATED_AT = "{generated}"', html, count=1)
    if n == 0:
        raise ValueError("Could not find GENERATED_AT in the dashboard.")
    return html


def structure_fingerprint(html: str) -> dict:
    """Cheap structural census, used to prove nothing but the data moved."""
    style = html.find("</style>")
    return {
        "style_bytes":  len(html[:style]) if style != -1 else 0,
        "tags_style":   html.count("<style>"),
        "tags_script":  html.count("<script>"),
        "tags_svg":     html.count("<svg"),
        "tabs":         html.count('plat:"'),
        "functions":    len(re.findall(r"\nfunction \w+\(", html)),
        "external":     len(re.findall(r'(?:src|href)="https?://', html)),
    }


# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------
def main() -> int:
    log = setup_logging()
    started = datetime.now()
    t0 = time.perf_counter()

    log.info("=" * 62)
    log.info("Refresh started | %s", started.strftime("%Y-%m-%d %H:%M:%S"))

    conn = None
    try:
        html_path = find_dashboard()
        queries   = parse_sql(SQL_FILE)
        log.info("Dashboard : %s", html_path)
        log.info("SQL       : %s (%d queries)", SQL_FILE, len(queries))

        original_html = html_path.read_text(encoding="utf-8")
        before = structure_fingerprint(original_html)

        # ---- connect ----------------------------------------------------
        conn = psycopg2.connect(connect_timeout=CONNECT_TIMEOUT, **DB_CONFIG)
        conn.set_session(readonly=True, autocommit=False)
        log.info("Connected : %s@%s:%s/%s",
                 DB_CONFIG["user"], DB_CONFIG["host"], DB_CONFIG["port"], DB_CONFIG["dbname"])

        data: "dict[str, dict]" = {}
        row_counts: "dict[str, int]" = {}

        with conn.cursor() as cur:
            cur.execute(f"SET statement_timeout = {STATEMENT_TIMEOUT_MS};")

            # Order matters only for the log; each query is independent.
            for name in ("amazon_reasons", "amazon_skus", "ebay_reasons", "ebay_skus"):
                qt0 = time.perf_counter()
                cur.execute(queries[name])
                rows = cur.fetchall()
                dt = time.perf_counter() - qt0

                if not rows:
                    raise RuntimeError(f"Query '{name}' returned 0 rows — refusing to "
                                       f"overwrite the dashboard with an empty table.")
                floor = MIN_ROWS.get(name, 1)
                if len(rows) < floor:
                    raise RuntimeError(
                        f"Query '{name}' returned only {len(rows)} rows, below the "
                        f"sanity floor of {floor}. This looks like a broken filter, "
                        f"not a real drop. Dashboard left unchanged."
                    )

                data[QUERY_TO_KEY[name]] = group_by_currency(rows)
                row_counts[name] = len(rows)
                log.info("  %-16s %6d rows  (%.2fs)", name, len(rows), dt)

        conn.rollback()   # read-only; close the snapshot cleanly
        total_rows = sum(row_counts.values())

        # ---- rebuild the HTML -------------------------------------------
        generated = started.strftime("%Y-%m-%d")
        data_js = json.dumps(data, ensure_ascii=False, separators=(",", ":"))
        new_html = replace_data_block(original_html, data_js, generated)

        # ---- prove only the data changed --------------------------------
        after = structure_fingerprint(new_html)
        if before != after:
            diff = {k: (before[k], after[k]) for k in before if before[k] != after[k]}
            raise RuntimeError(f"Refusing to write: the HTML structure changed ({diff}). "
                               f"Only the data block should have moved.")

        # ---- back up, then write atomically -----------------------------
        BACKUP_DIR.mkdir(parents=True, exist_ok=True)
        backup = BACKUP_DIR / f"index.{started.strftime('%Y%m%d_%H%M%S')}.html"
        shutil.copy2(html_path, backup)

        tmp = html_path.with_suffix(".html.tmp")
        tmp.write_text(new_html, encoding="utf-8")
        os.replace(tmp, html_path)      # atomic on POSIX

        finished = datetime.now()
        elapsed = time.perf_counter() - t0

        log.info("Backup    : %s", backup.name)
        log.info("Finished  | %s | %.2fs | %d rows | SUCCESS",
                 finished.strftime("%Y-%m-%d %H:%M:%S"), elapsed, total_rows)

        print("\n----------------------------------")
        print("Dashboard Refresh Complete")
        print(f"Generated:      {generated} {finished.strftime('%H:%M:%S')}")
        print(f"Rows fetched:   {total_rows}")
        for n, c in row_counts.items():
            print(f"  {n:<16} {c}")
        print(f"Execution time: {elapsed:.2f}s")
        print(f"Output:         {html_path}")
        print("----------------------------------\n")
        return 0

    except Exception as exc:
        if conn is not None:
            try:
                conn.rollback()
            except Exception:
                pass
        elapsed = time.perf_counter() - t0
        log.error("Finished  | %s | %.2fs | FAILED | %s: %s",
                  datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
                  elapsed, type(exc).__name__, exc)
        log.error("Dashboard left UNCHANGED.")

        print("\n----------------------------------", file=sys.stderr)
        print("Dashboard Refresh FAILED", file=sys.stderr)
        print(f"Error:          {type(exc).__name__}: {exc}", file=sys.stderr)
        print(f"Execution time: {elapsed:.2f}s", file=sys.stderr)
        print("Output:         unchanged — previous dashboard preserved", file=sys.stderr)
        print("----------------------------------\n", file=sys.stderr)

        import traceback
        traceback.print_exc(file=sys.stderr)
        return 1

    finally:
        if conn is not None:
            conn.close()


if __name__ == "__main__":
    sys.exit(main())
