# Runbook: running the pipeline by hand (Windows)

All commands run from the repository root (`C:\dev\relayx-integration`) in PowerShell.
Commands that call the Relay X API are marked **API** with their unit cost; check the quota
rules in CLAUDE.md (rule 4) before starting one. Every API run writes raw files first and is
loaded into Postgres in a separate step.

## 1. Environment

One-off setup (already done on Kevin's machine):

```powershell
conda create -n relayx python=3.12
conda activate relayx
pip install -r requirements.txt
```

Each new PowerShell session:

```powershell
conda activate relayx
$env:PYTHONPATH = "src"
```

- If `conda` is not recognised in PowerShell, use the "Anaconda PowerShell Prompt", or run
  `conda init powershell` once and reopen the terminal. Without conda on the path,
  `C:\Users\kevin\anaconda3\envs\relayx\python.exe` can replace `python` in every command.
- `PYTHONPATH=src` is needed because the package is not installed. Tests do not need it
  (`tests/conftest.py` adds `src`).
- Optional: `$env:PYTHONIOENCODING = "utf-8"` when redirecting output to a file.

`.env` in the repo root (template: `.env.example`, never committed):

| Variable | Used by | Purpose |
|---|---|---|
| `RELAYX_DATABASE_URL` | loader, history, reports | role `relayx_app` on `localhost:5434`; the code refuses any other host or port |
| `POSTGRES_ADMIN_URL` | nothing in `src/` | superuser, only for approved setup steps (`sql/000_setup_role.sql`) |
| `RELAYX_BASE_URL` | API runs | Relay X host, with or without the API prefix |
| `RELAYX_API_KEY` | API runs | sent as `X-Api-Key` |

Every command accepts `--env <path>` to use another file. The local database must be up:
Docker container `covalo-local-complete` (PostgreSQL 14, port 5434).

Raw output lands under `data/` (gitignored). Each run directory holds the byte-exact
responses (`page_*.json` or `call_*.json`), one `*.meta.json` per response (request,
timestamp, status, hashes, rate headers) and a `manifest.json` with the run status
(`running`, `partial`, `complete`, `failed`). The meta files are the source of truth;
the manifest is rewritten after every response.

Quota handling is inside the client: it waits on `RateLimit-Remaining` and `RateLimit-Reset`,
honours `Retry-After` on 429 and retries 5xx up to 3 times. Ctrl+C is safe at any point:
a response is only counted once its meta file is written.

## 2. /changes replay (full extract of constraint entries)

**API**, one unit per page (200 rows per page; the EU replay is 77 pages, about 75 s plus
one quota wait).

```powershell
python -m relayx.changes_replay --territory EU --since 2000-01-01T00:00:00Z
```

| Option | Default | Meaning |
|---|---|---|
| `--territory` | `EU` | territory filter |
| `--since` | `2000-01-01T00:00:00Z` | start of the replay (ADR-002) |
| `--limit` | `200` | rows per page (200 is the maximum) |
| `--max-pages` | none | stop after N pages (status `partial`), for tests |
| `--out` | `data/raw/changes_replay` | parent directory |
| `--resume <run_dir>` | | continue an interrupted run |

Output: `data/raw/changes_replay/<UTCstamp>_eu/` (run id = folder name). The command
prints the run id, status, pages, rows and `first_page_total`; exit code 0 only if complete.

Resume: `python -m relayx.changes_replay --resume data/raw/changes_replay/<run_id>`. It takes
the `nextCursor` of the last stored page (never `nextSince`) and refuses if the parameters
differ from the original run. A complete run is not re-fetched.

Check:
- `manifest.json`: `status` = `complete`, `rows` = `first_page_total`.
- `python -m relayx.replay_stats data/raw/changes_replay/<run_id> [--json out.json]`:
  entries, versions, changeKind counts, annexes, identifier coverage.
- Optional cross-check against lookup (**API**, about 1 unit per sampled item, default
  210 items): `python -m relayx.completeness data/raw/changes_replay/<run_id>
  [--n CAS=100,EC_ONLY=50,INCI_ONLY=50,NAME_ONLY=10] [--seed N]`. Output in
  `data/raw/completeness/<run_id>/`; nothing is written to the database.
- Then load it (section 6).

## 3. Corpus lists (/texts, /coverage, /allergens)

**API**, one unit per page; each EU list currently fits in one page (3 units in total).

```powershell
python -m relayx.api_extract lists --territory EU
```

Output: three run directories `data/raw/api/<UTCstamp>_{texts,coverage,allergens}_eu/`.
One JSON line per list is printed with run id, status, calls and units.

Resume: without `--resume` the command always starts new run directories. To continue
interrupted lists in their own directories (offset paging restarts after the rows already
stored, with the parameters the run was started with; a complete run makes no call):

```powershell
python -m relayx.api_extract lists --resume data/raw/api/<run_dir> [data/raw/api/<run_dir> ...]
```

Exit code 0 only if every list is complete.

Check: `manifest.json` `status` = `complete` and `by_status` only `200`; the run stops only
when the rows received add up to `total`. Row totals for /texts: the sum of
`constraintCount` should equal the replay row count (15,205 on 2026-10-19).

## 4. Entry history (narrow option)

**API**, one unit per entry. Narrow selection = entries with more than one version or a
RETRACTED row in a loaded replay (147 entries for `20261019T143522Z_eu`). Reads the ids from
`relayx_raw.entry_version`, so the replay must be loaded first.

```powershell
python -m relayx.history_extract run --replay-run 20261019T143522Z_eu
python -m relayx.history_extract compare data/raw/api/<run_dir> --replay-run 20261019T143522Z_eu
```

| Option | Default | Meaning |
|---|---|---|
| `--replay-run` | `20261019T143522Z_eu` | loaded replay run used for selection and comparison |
| `--out` | `data/raw/api` | parent directory |
| `--resume <run_dir>` | | continue an interrupted run (with `run`) |

Output: `data/raw/api/<UTCstamp>_history_narrow_eu/`, with `specs.json` (the planned calls).
`compare` prints a JSON summary: versions matched to feed rows on knownFrom = knownSince,
keys present on one side only, content fields that differ, knowledge-block values.

Resume: `python -m relayx.history_extract run --resume data/raw/api/<run_dir>`. Calls already
stored are skipped, `specs.json` and the original parameters are reused, and the command
refuses a directory that is not a history run.

Check: `manifest.json` `calls` = number of entries in `specs.json`, `by_status` only `200`;
`compare` reports `history_versions_unmatched` = 0 (2026-10-19: all 288 versions matched).

## 5. Per-substance runs

Two commands exist: the redundancy pilot (below) and the F2 Covalo lookup run (section 5a).
The full per-substance run over the catalogue is not built.

**API**, pilot: about 460 units (lookup:batch counts one unit per item; GET endpoints one
unit per call). Draws 100 catalogue items (seed 20261020) from `kevin.relayx_eu_identifiers_v2`
and sends each through lookup:batch, market-summary, impurity-limits, screening and opinions.

```powershell
python -m relayx.substance_pilot run
python -m relayx.substance_pilot analyse data/raw/api/<run_dir>
```

Options: `--out` (default `data/raw/api`), `--resume <run_dir>`. Output:
`data/raw/api/<UTCstamp>_substance_pilot_eu/`
with `sample.json` (items, strata, NOT_QUERYABLE items) and `specs.json`. `analyse` prints
the per-stratum comparison used in results/2026-10-19-phase2-extraction.md.

Resume: `python -m relayx.substance_pilot run --resume data/raw/api/<run_dir>` (same behaviour
as section 4). A lookup:batch answer with `truncated: true` gets its unevaluated items
appended as a new call, also on resume.

Check: `by_status` only `200`; the number of lookup items answered equals the sample size;
`analyse` output against the previous results file.

### 5a. F2 Covalo lookup run

**API**, one unit per item: 23,503 items in 941 lookup:batch calls (plan:
docs/plans/2026-10-20-f2-covalo-lookup.md, approved by Timo 2026-10-22). Value list:
data/f2_lookup/20261022/values.csv, built with `python -m relayx.lookup_values build` (local,
read-only). Quota handling differs from the shared client: units are counted by the command
(one per item sent), calls are paced to `--rate-per-minute` (default 60, at most 300), the
hard cap is `--max-units` (default 24000). The RateLimit-* headers are logged after every batch
next to that count. Never run two API commands at the same time: the quota is shared by every
key of the subscription.

**(b) and (c) may only be used after the pre-flight (a) shows a policy of 300**
(`RateLimit-Policy` starting with `300;`, printed as `"policy_is_300": true`). Otherwise run them
without `--rate-per-minute 300` (default 60) and expect about 6.5 h for (c).

Open a PowerShell window outside Claude Code and prepare it (every window, including the second
one for (d)):

```powershell
Set-Location C:\dev\relayx-integration
conda activate relayx
$env:PYTHONPATH = "src"
```

(a) Pre-flight, 1 unit: one GET /texts. Prints and saves RateLimit-Limit, -Remaining, -Reset
and -Policy to `data/raw/api/<UTCstamp>_preflight/preflight.json`.

```powershell
python -m relayx.substance_pilot preflight
```

(b) Canary: the first 100 items at 300 per minute (100 units, 4 calls).

```powershell
python -m relayx.substance_pilot lookup --values data/f2_lookup/20261022/values.csv --max-items 100 --rate-per-minute 300
```

(c) Full run at 300 per minute (about 93 min; calls take about 6 s each, so latency, not the
quota, sets the pace).

```powershell
python -m relayx.substance_pilot lookup --values data/f2_lookup/20261022/values.csv --rate-per-minute 300 --max-units 24000
```

(d) Follow the log of the latest full run from a second window:

```powershell
$run = Get-ChildItem data\raw\api -Directory | Where-Object Name -like "*_covalo_lookup_eu" | Sort-Object Name | Select-Object -Last 1
Get-Content (Join-Path $run.FullName "run.log") -Wait -Tail 20
```

(e) Resume the latest full run after an interruption (Ctrl+C, crash, reboot, unit cap). It
restarts at the first unrecorded item, re-sends nothing recorded and refuses a changed value
list. The unit cap counts the units of the whole run, not only the resumed part. `--resume`
keeps the `--max-units` and `--rate-per-minute` of the original run (read from its manifest),
not the defaults; an explicit `--max-units` or `--rate-per-minute` on the resume command
replaces them. The value list and `--max-items` always come from the original run.

```powershell
$run = Get-ChildItem data\raw\api -Directory | Where-Object Name -like "*_covalo_lookup_eu" | Sort-Object Name | Select-Object -Last 1
python -m relayx.substance_pilot lookup --resume $run.FullName --rate-per-minute 300
```

(f) Load the latest full run afterwards (local, no API call):

```powershell
$run = Get-ChildItem data\raw\api -Directory | Where-Object Name -like "*_covalo_lookup_eu" | Sort-Object Name | Select-Object -Last 1
python -m relayx.load_raw $run.FullName
```

The canary run directory ends in `_covalo_lookup_eu_canary100`; to follow or load it, use
`-like "*_covalo_lookup_eu_canary100"` in the same commands.

Anaconda Prompt (cmd) variant, as used for the run of 2026-10-22: prepare the window, then the
same `python` commands as (a) to (c); load by the explicit run folder.

```bat
cd /d C:\dev\relayx-integration
conda activate relayx
set PYTHONPATH=src
python -m relayx.substance_pilot preflight
python -m relayx.substance_pilot lookup --values data/f2_lookup/20261022/values.csv --max-items 100 --rate-per-minute 300
python -m relayx.substance_pilot lookup --values data/f2_lookup/20261022/values.csv --rate-per-minute 300 --max-units 24000
python -m relayx.load_raw data/raw/api/20261022T075600Z_covalo_lookup_eu_canary100
python -m relayx.load_raw data/raw/api/20261022T075923Z_covalo_lookup_eu
```

Resume in cmd also takes the explicit run folder, e.g.
`python -m relayx.substance_pilot lookup --resume data/raw/api/20261022T075923Z_covalo_lookup_eu`.

Plan without API calls: `python -m relayx.substance_pilot lookup --dry-run` (add
`--rate-per-minute` or `--max-items` as for the run) prints calls, units, duration at 60 and
300 per minute, a disk estimate and free space on C:.

Output: `data/raw/api/<UTCstamp>_covalo_lookup_eu/` with `call_*.json`, `call_*.meta.json`,
`manifest.json` (status, units, truncations, `failed_items`, `call_log` with the SHA-256 of
every request, per-item `ledger` with ok, error, message and ingredientStatus) and `run.log`
(one line per batch, one progress line per minute: items done, units used, errors,
truncations, ETA). Exit code 0 only if every selected item is recorded; 130 after Ctrl+C.
Windows is kept awake while the command runs.

Behaviour: 429 waits Retry-After + 2 s, else until RateLimit-Reset + 2 s. `truncated: true`
records `truncatedReason` and resends exactly the unevaluated items. `ok: false` items are
recorded, not retried, and listed at the end. 5xx and network errors are retried 3 times with
backoff; 401, 403 or any 400 stop the run (the 400 body goes to `run.log`); 10 consecutive
failed batches stop it.

Check: `manifest.json` `status` = `complete`, `items_recorded` = `params.items_selected`,
`units_used` within the cap, `truncations` and `failed_items` reviewed. The loader then
reconciles the ledger with every stored body and refuses the run on any mismatch.

### Targeted checks

**API**, opinions about 100 units, impurity 20, IFRA 20. Samples are drawn locally from the
loaded replay and allergen list (seed 20261020).

```powershell
python -m relayx.targeted_checks run opinions
python -m relayx.targeted_checks run impurity
python -m relayx.targeted_checks run ifra
python -m relayx.targeted_checks run opinions --resume data/raw/api/<run_dir>
python -m relayx.targeted_checks analyse data/raw/api/<run_dir>
```

Output: `data/raw/api/<UTCstamp>_check_<name>_eu/` with `sample.json` and `specs.json`.
Check with `analyse`, then load (section 6). Results 2026-10-20:
results/2026-10-20-targeted-checks.md.

## 6. Loader (raw files into Postgres)

Local only, no API calls.

```powershell
python -m relayx.load_raw data/raw/changes_replay/<run_id>
python -m relayx.load_raw data/raw/api/<run_a> data/raw/api/<run_b>
```

- Detects the run type: `page_*` files go to `relayx_ops.extract_run`,
  `relayx_raw.changes_page` and `relayx_raw.entry_version`; `call_*` files go to
  `relayx_ops.extract_run` and `relayx_raw.api_response`.
- Every raw file is checked against its stored sha256 before insert. One transaction per run.
- A run id that is already loaded is refused. Raw tables are append-only (triggers refuse
  UPDATE, DELETE and TRUNCATE).
- Load only runs whose manifest says `complete`; finish or resume the run first.

Resume: nothing to resume. An interrupted load rolls back its run; run the same command again.

Check: the command prints JSON per run with a `checks` block and exits with 1 if any check
fails. /changes runs: rows = manifest rows = sum of `page_returned` = first page `total`,
no non-200 pages, no duplicate (logical_entry_id, known_since), every payload hash recomputed.
Other runs: calls in the database = manifest calls, body hashes match. F2 Covalo lookup runs
also print `ledger_check` (calls and items reconciled, ingredientStatus counts); the per-item
ledger is stored with the manifest in `relayx_ops.extract_run.manifest`. Quick look in SQL:

```sql
SELECT run_id, feed, status, pages, row_count, requests, loaded_at
FROM relayx_ops.extract_run ORDER BY loaded_at;
```

## 7. Reports (local, no API calls)

```powershell
python -m relayx.provisional_report sql/provisional/f1_matching_assessment.sql > f1_out.tsv
```

Runs a report file from `sql/provisional/` or `sql/reports/`: the part before `-- REPORT`
creates TEMP objects, each titled section after it is printed as a tab-separated table, and
the transaction is rolled back, so nothing persists. `--timeout` sets the statement timeout
in seconds (default 300). Progress per section goes to stderr.

## 8. Archiving a run

```powershell
python -m relayx.archive_run data/raw/changes_replay/<run_id> [--out data/archive] [--allow-incomplete]
```

Zips the run directory with its manifest and a SHA256SUMS file. Refuses runs that are not
`complete` unless `--allow-incomplete` is given.

## 9. Tests

```powershell
python -m pytest -q
python -m pytest -q tests/test_changes_replay.py
```

No database or API access needed; HTTP calls are faked in the tests. Expected: all pass
(61 on 2026-10-22).

## 10. After a run

Write `results/YYYY-MM-DD-<topic>.md` (CLAUDE.md): what was run with run ids, counts, units,
anomalies, open points. Update `docs/relayx/coverage-inventory.md` for new extraction runs.
