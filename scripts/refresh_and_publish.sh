#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Returns Reason Hotspot Dashboard — daily refresh, then publish to the Hub.
#
# Called by cron at 10:00 (see `crontab -l`). Two stages:
#   1. refresh_dashboard.py  -> rewrites const DATA / GENERATED_AT / MISMATCH
#   2. push_to_hub.js        -> upserts the refreshed HTML into varman_aios.hub_pages
#
# Stage 2 runs ONLY if stage 1 exited 0. A failed refresh leaves the dashboard
# untouched, so there is nothing new to publish and the hub keeps yesterday's copy.
#
# Credentials: read from the project's gitignored, chmod-600 .env at run time.
# Never hardcoded here, never printed — the connection string is redacted out of
# the log as a backstop in case a driver error ever echoes it.
#
# Scope: only ever writes varman_aios.hub_pages for MEMBER_NAME below (upsert on
# (member_name, page_slug)). The credential can reach other tables; this must not.
# ---------------------------------------------------------------------------
set -uo pipefail

PROJECT="/home/led-247/Returns-Reason-Hotspot-Report"
MEMBER_NAME="sarujanan"
PAGE_SLUG="returns-reason-hotspot-report"
PAGE_TITLE="Returns Reason Hotspot Report"
HTML="$PROJECT/Dashboard/index.html"
LOG="$PROJECT/logs/hub_publish.log"
MIN_BYTES=100000          # a healthy dashboard is ~290KB; never publish a stub

# cron gets a bare environment — set an explicit PATH.
PATH=/usr/local/bin:/usr/bin:/bin
export PATH

mkdir -p "$PROJECT/logs"

log()    { printf '%s | %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }
# strips the password out of anything a subprocess writes to the log
redact() { sed -E 's#(postgres(ql)?://[^:/@]+:)[^@]*@#\1***REDACTED***@#g' >> "$LOG" 2>&1; }

log "================ refresh + publish started ================"

# --- stage 1: refresh the embedded data --------------------------------------
if /usr/bin/python3 "$PROJECT/scripts/refresh_dashboard.py" 2>&1 | redact; then
  log "stage 1 refresh: OK"
else
  log "stage 1 refresh: FAILED — dashboard left unchanged, skipping publish"
  exit 1
fi

# --- pre-publish sanity: never ship a truncated or structurally broken page ---
if [ ! -r "$HTML" ]; then
  log "stage 2 publish: SKIPPED — $HTML not readable"; exit 1
fi
BYTES=$(wc -c < "$HTML")
if [ "$BYTES" -lt "$MIN_BYTES" ]; then
  log "stage 2 publish: SKIPPED — HTML only ${BYTES}B (< ${MIN_BYTES}B floor)"; exit 1
fi
for marker in 'const DATA =' 'const MISMATCH =' 'const GENERATED_AT ='; do
  if ! grep -qF "$marker" "$HTML"; then
    log "stage 2 publish: SKIPPED — '$marker' missing from HTML"; exit 1
  fi
done

# --- build the hub connection string (URL-encoded, never logged) --------------
# The hub table varman_aios.hub_pages lives on the hub DB, which is a DIFFERENT
# database from the dashboard data source (PG* -> LEDSone since 2026-09-14). So the
# publish uses its own HUB_PG* vars, read straight from .env; it never reuses the
# PG* refresh connection. Missing HUB_PG* -> publish is skipped (dashboard already
# refreshed locally), it never falls back to the LEDSone connection.
if [ ! -r "$PROJECT/.env" ]; then
  log "stage 2 publish: SKIPPED — .env not readable"; exit 1
fi
HUB_DB_URL="$(/usr/bin/python3 - "$PROJECT/.env" <<'PY'
import sys, urllib.parse
from dotenv import dotenv_values
v = dotenv_values(sys.argv[1])
need = ["HUB_PGHOST", "HUB_PGPORT", "HUB_PGDATABASE", "HUB_PGUSER", "HUB_PGPASSWORD"]
if any(not v.get(k) for k in need):
    sys.exit(0)   # missing hub creds -> empty output -> publish skipped, never PG* fallback
q = lambda s: urllib.parse.quote(s, safe="")
print("postgresql://%s:%s@%s:%s/%s" % (
    q(v["HUB_PGUSER"]), q(v["HUB_PGPASSWORD"]),
    v["HUB_PGHOST"], v["HUB_PGPORT"], v["HUB_PGDATABASE"]))
PY
)"
if [ -z "${HUB_DB_URL:-}" ]; then
  log "stage 2 publish: SKIPPED — HUB_PG* hub-database vars missing/empty in .env"; exit 1
fi
export HUB_DB_URL

# --- stage 2: publish to the hub (upsert; same slug updates in place) ---------
cd "$PROJECT/scripts" || { log "stage 2 publish: FAILED — cannot cd to scripts/"; unset HUB_DB_URL; exit 1; }
if /usr/bin/node push_to_hub.js "$MEMBER_NAME" "$PAGE_SLUG" "$PAGE_TITLE" "$HTML" 2>&1 | redact; then
  log "stage 2 publish: OK — ${MEMBER_NAME}/${PAGE_SLUG} (${BYTES} bytes)"
  STATUS=0
else
  log "stage 2 publish: FAILED — dashboard refreshed locally but hub not updated"
  STATUS=1
fi

unset HUB_DB_URL
log "================ finished (exit $STATUS) ================"
exit "$STATUS"
