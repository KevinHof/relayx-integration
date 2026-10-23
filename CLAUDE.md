# Relay X to Covalo regulatory data integration

## Purpose
Ingest Relay X EU cosmetics regulatory data via their API, reconstruct it locally in
Postgres, analyse it, match it to Covalo ingredient/product identifiers, and build a
periodic SQL ingestion pipeline. Development and validation happen locally; production
implementation is handed over to the Covalo tech team (target Q1 2027).
This work is also an evaluation of Relay X as a data vendor, so data quality findings
are deliverables, not side notes.
Phases, gates and grain hypotheses: docs/roadmap.md (do not start a phase before its gate).
Principle: extract broadly, model late. All content our key can access goes to raw with provenance and a completeness report; core models only per content type when a use needs them.

Background and current state: @docs/project-brief.md
Open questions that block design decisions: @docs/open-questions.md
Decisions taken so far: docs/decisions/ (one ADR per decision)

## Owner and working style
- Owner: Kevin (Data Product Lead). Decisions are made by Kevin, often after design
  discussion in a separate Claude chat; they arrive here as ADR files.
- Ask clarifying questions instead of assuming. Do not infer heavily from partial data.
- Propose a plan and wait for approval before: creating or altering database schemas,
  adding dependencies, deleting files, or running anything that calls the Relay X API
  more than a handful of times.
- Report findings neutrally: separate what is demonstrated from what is unvalidated.
- Writing style for docs and summaries: concise, factual, no em dashes.

## Environment
- Windows machine, Python via Anaconda. Conda env `relayx` (Python 3.12, requirements.txt).
- Local Postgres: covalo-local-complete, PostgreSQL 14 in Docker, port 5434.
  Connection strings come from .env: RELAYX_DATABASE_URL (role relayx_app, regular use)
  and POSTGRES_ADMIN_URL (superuser, approved setup only). Never hard-code credentials.
- Covalo source tables live in schema `covalo` (e.g. covalo.product, covalo.company;
  product.company is the FK to company.id). Existing Relay X exploration tables and the
  view kevin.product_identifiers live in schema `kevin`.
- Relay X API: base URL and key come from RELAYX_BASE_URL and RELAYX_API_KEY in .env.
  Header: X-Api-Key. The binding contract is GET /api/regulatory/v1/openapi.json;
  the PDF in docs/relayx/ is hand-written and can lag behind it.

## Hard rules
1. Never connect to the production read replica or use the SSH bastion tunnel.
   Only the local database on port 5434. All database access goes through
   RELAYX_DATABASE_URL. Using POSTGRES_ADMIN_URL or `docker exec` as postgres is allowed
   only for setup steps Kevin explicitly approves.
2. Treat schema `covalo` as read-only. Write only to schemas approved in an ADR
   (until then: propose, do not create).
3. Never commit .env, API keys, or raw data dumps. Raw API payloads live in the
   database or in data/ (gitignored).
4. Relay X API behaviour:
   - Respect the quota: 60 requests per minute per subscription, shared across all our
     keys (more keys do not add throughput; Relay X, 2026-10-19). Trial rate raised to 300
     per minute on 2026-10-22 (stated by Relay X, observed in the pre-flight headers). The
     code follows the rate-limit headers: the RateLimit-* response headers remain the
     runtime source of truth; never hard-code limits. Parse RateLimit-Reset defensively (seconds or Unix timestamp).
     A batch entry costs one unit. Honour Retry-After on 429, handle `truncated: true`.
   - Page /changes only with the returned opaque `nextCursor` (passed back as `cursor`),
     never with `offset`, `nextSince` or the local clock. Store `nextSince` for dating a
     sync only; it is inclusive, so dedupe on (logicalEntryId, knownSince).
   - Copy logicalEntryId values verbatim; never construct them.
5. Absence is not permission. 403, 404, withheldByScope, missingZones,
   INSUFFICIENT_DATA and empty results are licensing or coverage states, never
   "unregulated". Store them as explicit states; never drop them silently.
6. Store raw API responses append-only, with request parameters, timestamp, HTTP
   status and a payload hash, before any transformation. Transformations must be
   reproducible from raw.
7. Two time axes exist: law validity (asOf, effective dates) and knowledge
   (knownFrom / knownUntil). Keep them separate in any model.

## Repository layout (target)
- src/        Python: API client, full extract, diff pull, normalisation
- sql/        schema migrations (numbered), matching views and queries
- tests/      tests for parsing, normalisation and matching logic
- docs/       project brief, open questions, ADRs, Relay X docs and openapi snapshot
- results/    short markdown summary per meaningful run (counts, match rates, anomalies)
- legacy/     earlier exploration scripts, kept for reference until superseded
- data/       local raw files (gitignored)

## After each meaningful run
Write results/YYYY-MM-DD-<topic>.md: what was run, row counts, key metrics, anomalies,
and open points. Keep it under one page. These summaries are shared back for review.

## Working conventions (learned 2026-10-19 to 2026-10-23)
- Python in Claude Code: `conda` is not on the PowerShell path. Call the env's interpreter
  directly and set the import path:
  `$env:PYTHONPATH = 'src'; & "$env:USERPROFILE\anaconda3\envs\relayx\python.exe" -m relayx.<module> ...`
  Tests: `& "$env:USERPROFILE\anaconda3\envs\relayx\python.exe" -m pytest -q` (no PYTHONPATH needed).
  Kevin runs API commands himself in an Anaconda Prompt (cmd); see docs/runbook.md section 5a.
- The relayx-regulatory MCP tools (mcp__relayx-regulatory__*) call the Relay X API and share
  the subscription quota. Treat every call as an API call: do not use them without Kevin's
  explicit approval in the message.
- Output to a file: PowerShell pipes re-encode text. Set `$env:PYTHONIOENCODING = 'utf-8'` and
  redirect inside cmd: `cmd /c "<python.exe> -m ... > <file> 2> <errfile>"`. With `-I` the PYTHON*
  variables are ignored; use `-X utf8` instead.
- Commits: PowerShell here-strings break `git commit -m`. Write the message to a file in the
  scratchpad and run `git commit -F <file>`. Commit locally only; never push unless asked.
- Report runner (relayx.provisional_report): the part before `-- REPORT` is setup (TEMP objects);
  each later section is one statement with a `-- <title>` line, separated by a blank line (no
  blank lines inside a section); everything is rolled back. `--setup <file>` runs another file's
  setup first. `--param name=value` fills `{{name}}` in the main file only, not in `--setup`
  files. `--timeout` is in seconds.
- Standard invocations:
  - F1 objects (cov_*, rx_*, cat_val, parser functions) come from
    `--setup sql/provisional/f1_matching_assessment.sql`; most provisional files need it.
  - F3: `python -m relayx.provisional_report sql/provisional/f3_cosing_bridge.sql --setup sql/provisional/f1_matching_assessment.sql --param cosing_table=kevin.cosing_ingredients --timeout 3600`
  - F2 profile: `sql/provisional/f2_lookup_profile.sql` with the F1 setup; F2 figures use the full
    run 20261022T075923Z_covalo_lookup_eu only, never the canary run.
- Slow parts (run in the background): F1 setup about 10 s; F3 setup about 90 s (CosIng parsing,
  part 2 matching, 2b tiers, part 3 options); F3 section o11 about 410 s (NOT EXISTS checks of
  derived values against cov_val, rx_val and cat_val); covalo_cas_quality.sql section a5 about
  350 s (per-company correlated subqueries) and a3e about 90 s.
- PostgreSQL regex: the first quantifier of a pattern sets its greediness, so a lazy `.*?` after a
  greedy atom is not lazy. Capture with a negated class instead (e.g. `([^0-9]*)`).
- docs/relayx/*.pdf is gitignored (hashes in docs/relayx/README.md); no PDF reader is installed in
  the relayx env, so the PDF guides cannot be read here.
- Long outputs: write TSV to the scratchpad and read sections from there; scratchpad files are not
  part of the repo.
