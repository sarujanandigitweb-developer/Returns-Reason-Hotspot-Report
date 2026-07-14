# Validation — credential migration to `.env`

Configuration-only change. Run 2026-07-14 against the live database
(`149.28.134.54:5435/order_management_copy`).

**Result: PASS.** The regenerated dashboard is **byte-for-byte identical** to the validated
version — not equivalent, identical (`md5 13bb1f8fbf146b2376459aa7028cf6cb`, unchanged).

---

## 1. Discovery findings (read-only)

| Question | Finding |
|---|---|
| Where is `DB_CONFIG` defined? | `scripts/refresh_dashboard.py:96`, built by `load_db_config()` from the environment |
| Is `python-dotenv` already used? | **Yes** — imported at line 44, `load_dotenv(ENV_FILE)` at line 61 |
| Is `.env` already ignored? | **Yes** — `.gitignore:2`; confirmed with `git check-ignore -v .env` |
| Credentials hardcoded anywhere? | **No.** The password literal appears in **zero** tracked files |
| Do cron instructions reference credentials? | **No** — the cron line carries only the interpreter and script path |
| `requirements.txt` present? | **No — gap. Created.** |

The configuration migration was already complete from prior work; this pass verified it and
closed the one real gap (`requirements.txt`).

## 2. Files modified

| File | Change |
|---|---|
| `requirements.txt` | **Created** — `python-dotenv`, `psycopg2-binary`, plus the PEP 668 note |
| `data-maps/`, `capability/`, `workflows/`, `query-packs/`, `prompts/`, `closure/` | **Populated** — were empty |
| `scripts/refresh_dashboard.py` | **Unchanged** — already env-only |
| `.env.example`, `.gitignore`, `README.md` | **Unchanged** — already correct |
| SQL, HTML, CSS, JavaScript | **Untouched** |

## 3. Environment-variable validation

Each variable removed in turn:

| Omitted | Exit code | Reported |
|---|---|---|
| `PGHOST` | 1 | `PGHOST` |
| `PGPORT` | 1 | `PGPORT` |
| `PGDATABASE` | 1 | `PGDATABASE` |
| `PGUSER` | 1 | `PGUSER` |
| `PGPASSWORD` | 1 | `PGPASSWORD` |

In every case: no connection attempted, dashboard untouched, exit 1. **No fallback credentials
exist in the source.**

## 4. Successful refresh

Run from `$HOME` — deliberately, because that is cron's working directory:

```
amazon_reasons     66 rows  (0.10s)
amazon_skus      1580 rows  (0.52s)
ebay_reasons       28 rows  (0.11s)
ebay_skus         432 rows  (0.12s)
Finished | 1.65s | 2106 rows | SUCCESS      exit 0
```

## 5. Dashboard reconciliation

| Metric | Value | Expected |
|---|---|---|
| Amazon refund (all currencies) | 36,899.74 | 36,899.74 |
| eBay refund (all currencies) | 11,384.44 | 11,384.44 |
| Amazon units | 2,789 | 2,789 |
| eBay units | 794 | 794 |

## 6. Row-count comparison, before vs after

| Section | Before | After | |
|---|---|---|---|
| `AMAZON_REASONS` | 66 | 66 | MATCH |
| `AMAZON_SKUS` | 1,580 | 1,580 | MATCH |
| `EBAY_REASONS` | 28 | 28 | MATCH |
| `EBAY_SKUS` | 432 | 432 | MATCH |

**2,106 values compared cell by cell — 0 differences.**

## 7. Byte comparison

```
md5 before : 13bb1f8fbf146b2376459aa7028cf6cb
md5 after  : 13bb1f8fbf146b2376459aa7028cf6cb
cmp        : byte-for-byte IDENTICAL
```

With the data block masked, `diff` reports no difference at all — HTML, CSS and JavaScript are
untouched. Structure holds: 0 external references, 1 `<style>`, 1 `<script>`, 8 `<svg>`, 4 tabs,
JS parses.

Backups: 4 → 5 (new backup written). Log: 58 → 69 lines (appended, not truncated).
Zero leftover `.tmp` files — the atomic write completed cleanly.

## 8. No credentials remain

- `grep -rn '12we34rt'` across the repo, excluding `.env` and `backups/`: **no matches**
- `git status --untracked-files=all`: `.env` **not** among the files git would commit
- `.env` is `chmod 600`, gitignored, and present only on this machine

`.env.example` contains host/port/database/user (non-secret, as your spec requires) and
`PGPASSWORD=your_password_here`.

---

## Deviations from the instructions, and why

**1. A real `.env` exists.** Your spec said *"Do NOT create a real .env file."* One already
existed from the previous turn, and Step 5 required executing the refresh — which is impossible
without credentials. It is `chmod 600` and gitignored, so it is not a repository-safety risk.
**Delete it if you want a clean checkout;** the script will then print the missing variables and
exit 1 until one is created.

**2. `load_dotenv()` takes an explicit path.** Your snippet used the bare call, which searches
the *current working directory*. Cron runs jobs from `$HOME`, so the bare call would never find
the project's `.env` and **the 09:00 job would fail every morning.** It is anchored to the
project root instead. This was verified by running from `$HOME`. **The cron command is unchanged.**

**3. `pip install python-dotenv` does not work on this machine.** Ubuntu blocks system-wide pip
installs (PEP 668). `python-dotenv 1.0.1` is already present via the `python3-dotenv` apt
package. The README and `requirements.txt` document both routes, otherwise the setup
instructions would fail for the next person.

---

## PASS / FAIL

| Criterion | |
|---|---|
| No hardcoded credentials remain | **PASS** |
| Refresh script works without modification | **PASS** |
| Dashboard output matches the validated version | **PASS** — byte-identical |
| Repository is safe to commit | **PASS** |
| Existing functionality preserved exactly | **PASS** |

## **OVERALL: PASS**

One caveat that is not a test failure: the database password was transmitted in plaintext and
previously lived in the script's source. **Treat `temp_user` as exposed and rotate it.**
