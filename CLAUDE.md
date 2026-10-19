# Relay X to Covalo regulatory data integration

## Purpose
Ingest Relay X EU cosmetics regulatory data via their API, reconstruct it locally in
Postgres, analyse it, match it to Covalo ingredient/product identifiers, and build a
periodic SQL ingestion pipeline. Development and validation happen locally; production
implementation is handed over to the Covalo tech team (target Q1 2027).
This work is also an evaluation of Relay X as a data vendor, so data quality findings
are deliverables, not side notes.

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
- Windows machine, Python via Anaconda. Use a dedicated env (see README once created).
- Local Postgres: covalo-local-complete, PostgreSQL 14 in Docker, port 5434.
  Connection string comes from DATABASE_URL in .env. Never hard-code credentials.
- Covalo source tables live in schema `covalo` (e.g. covalo.product, covalo.company;
  product.company is the FK to company.id). Existing Relay X exploration tables and the
  view kevin.product_identifiers live in schema `kevin`.
- Relay X API: base URL and key come from RELAYX_BASE_URL and RELAYX_API_KEY in .env.
  Header: X-Api-Key. The binding contract is GET /api/regulatory/v1/openapi.json;
  the PDF in docs/relayx/ is hand-written and can lag behind it.

## Hard rules
1. Never connect to the production read replica or use the SSH bastion tunnel.
   Only the local database on port 5434.
2. Treat schema `covalo` as read-only. Write only to schemas approved in an ADR
   (until then: propose, do not create).
3. Never commit .env, API keys, or raw data dumps. Raw API payloads live in the
   database or in data/ (gitignored).
4. Relay X API behaviour:
   - Respect the quota (60 units/min per key; a batch entry costs one unit).
     Read RateLimit-* headers, honour Retry-After on 429, handle `truncated: true`.
   - Advance the /changes cursor only with the returned `nextSince`, never the local clock.
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
