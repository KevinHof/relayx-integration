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

Resume: the command always starts new run directories. To continue an interrupted list in
its existing directory (offset paging restarts after the rows already stored):

```powershell
python -c "import json,sys; from pathlib import Path; from dotenv import load_dotenv; load_dotenv('.env'); from relayx.api_extract import run_list; from relayx.client import RelayXClient; d=Path(sys.argv[1]); m=json.loads((d/'manifest.json').read_text(encoding='utf-8')); p={k:v for k,v in m['params'].items() if k!='limit'}; print(run_list(RelayXClient(), d, '/'+m['feed'], p, m['params']['limit'])['status'])" data/raw/api/<run_dir>
```

For three one-page lists it is usually simpler to rerun the command and load only the
complete run directories.

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

Output: `data/raw/api/<UTCstamp>_history_narrow_eu/`, with `specs.json` (the planned calls).
`compare` prints a JSON summary: versions matched to feed rows on knownFrom = knownSince,
keys present on one side only, content fields that differ, knowledge-block values.

Resume: `run` always starts a new directory. To continue in the existing one (calls already
stored are skipped, `specs.json` is reused):

```powershell
python -c "import json,sys; from pathlib import Path; from dotenv import load_dotenv; load_dotenv('.env'); from relayx.api_extract import run_keyed; from relayx.client import RelayXClient; d=Path(sys.argv[1]); m=json.loads((d/'manifest.json').read_text(encoding='utf-8')); print(run_keyed(RelayXClient(), d, m['feed'], [], m['params'])['status'])" data/raw/api/<run_dir>
```

Check: `manifest.json` `calls` = number of entries in `specs.json`, `by_status` only `200`;
`compare` reports `history_versions_unmatched` = 0 (2026-10-19: all 288 versions matched).

## 5. Per-substance runs

Only the redundancy pilot exists as a command. The full per-substance run and the F2 Covalo
lookup run (docs/plans/2026-10-20-f2-covalo-lookup.md) are not built yet and not approved.

**API**, pilot: about 460 units (lookup:batch counts one unit per item; GET endpoints one
unit per call). Draws 100 catalogue items (seed 20261020) from `kevin.relayx_eu_identifiers_v2`
and sends each through lookup:batch, market-summary, impurity-limits, screening and opinions.

```powershell
python -m relayx.substance_pilot run
python -m relayx.substance_pilot analyse data/raw/api/<run_dir>
```

Options: `--out` (default `data/raw/api`). Output: `data/raw/api/<UTCstamp>_substance_pilot_eu/`
with `sample.json` (items, strata, NOT_QUERYABLE items) and `specs.json`. `analyse` prints
the per-stratum comparison used in results/2026-10-19-phase2-extraction.md.

Resume: same one-liner as section 4 (keyed run). A lookup:batch answer with
`truncated: true` gets its unevaluated items appended as a new call, also on resume.

Check: `by_status` only `200`; the number of lookup items answered equals the sample size;
`analyse` output against the previous results file.

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
Other runs: calls in the database = manifest calls, body hashes match. Quick look in SQL:

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
(28 on 2026-10-20).

## 10. After a run

Write `results/YYYY-MM-DD-<topic>.md` (CLAUDE.md): what was run with run ids, counts, units,
anomalies, open points. Update `docs/relayx/coverage-inventory.md` for new extraction runs.
