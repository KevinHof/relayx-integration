# ADR-001: Raw and ops layers, database role

Status: ACCEPTED 2026-10-19 (Kevin), with changes a to c folded in. Database objects are
created only after Kevin confirms he ran sql/000_setup_role.sql.

## Scope
This ADR covers the /changes feed only. Raw responses from other endpoints (lookup,
lookup:batch, history, texts, coverage, allergens, market-summary) stay as files in
`data/raw/` until a later ADR extends the raw layer.

## Context
- Roadmap phase 2 (raw load) is gated on this ADR. Phase 3 profiling needs the replay in
  Postgres.
- Phase 1 produced one complete EU /changes replay, stored as files: run
  `20261019T143522Z_eu`, 77 pages, 15,205 entry-version rows, 15,064 logicalEntryIds,
  170 MB raw JSON, about 11 KB per row, `knownSince` never null (results/2026-10-19-kickoff.md).
- Hard rules: write only to schemas approved in an ADR (2); store absence and error states
  explicitly (5); store raw responses append-only with request parameters, timestamp, HTTP
  status and payload hash before any transformation, transformations reproducible from raw
  (6); keep law time and knowledge time separate (7); copy logicalEntryId verbatim.
- Today `DATABASE_URL` connects as superuser `postgres`; the covalo read-only rule is
  enforced only by discipline. The local DB is PostgreSQL 14.
- The model is handed over to the Covalo tech team; the layout should be portable.
- Kevin asked for one raw row per entry version as JSONB, with run id, page, cursor,
  knownSince, logicalEntryId and payload hash.

## Options considered

### 1. Schema layout
- A. Keep everything in schema `kevin`. Fast, but mixes exploration with pipeline tables and
  gives no clean grant boundary.
- B. One schema `relayx` with table prefixes. One grant boundary, weak separation of raw
  (immutable) and ops (mutable state).
- C. Separate schemas `relayx_raw` (append-only responses) and `relayx_ops` (run log,
  cursors), with `relayx_core` and a matching schema added by later ADRs. Matches the Q6
  proposal; raw immutability and ops mutability get different rules.

### 2. Raw grain
- A. One row per response page, whole body as JSONB. Closest to the wire, but every query
  must unnest `changes[]`, and 3 to 4.5 MB values are slow to profile.
- B. One row per entry version (element of `changes[]`) plus one row per page holding the
  request, status, hashes and the response envelope (body without `changes[]`). Page-level
  provenance stored once; entry rows stay small and queryable.
- C. One row per entry version with the page metadata repeated on every row. Simpler joins,
  about 200 duplicated header values per page, and no place for a non-200 page that has no
  rows (breaks rule 5).

### 3. Payload fidelity
- A. `jsonb`: queryable and indexable, but not byte-exact (key order, whitespace, duplicate
  keys are normalised).
- B. `json` or `text`: byte-exact, slow to query.
- C. `jsonb` in the database plus the byte-exact page files kept in `data/raw/` with their
  sha256 recorded per page. Database rows are reproducible from the files.

### 4. Database role
- A. Keep using `postgres`. No setup, no protection of `covalo`.
- B. A dedicated login role `relayx_app`: owns `relayx_raw` and `relayx_ops`, SELECT only on
  `covalo` and `kevin`. One-off setup run by `postgres`; the pipeline connects with a
  separate URL. Mirrors what production will need.
- C. Two roles: a NOLOGIN owner that owns the schemas and tables, and a LOGIN writer with
  INSERT and SELECT only (no UPDATE, DELETE, TRUNCATE, no DDL). Stricter, more setup; this
  is the production route to real immutability of raw.

## Decision
1C: schemas `relayx_raw` and `relayx_ops`. 2B: `relayx_raw.changes_page` plus
`relayx_raw.entry_version`. 3C: `jsonb` plus byte-exact files and hashes. 4B: role
`relayx_app`.

Append-only triggers on the raw tables guard against ACCIDENTAL UPDATE, DELETE or TRUNCATE
from pipeline code. They do not protect against deliberate change: as owner, `relayx_app`
can drop or disable the triggers. Real immutability needs option 4C (separate NOLOGIN
owner), which is the recommended route for production.

### Connections
- `RELAYX_DATABASE_URL` (as `relayx_app`) for all regular database access.
- `POSTGRES_ADMIN_URL` (formerly `DATABASE_URL`, superuser) only for setup steps Kevin
  explicitly approves. Kevin runs the role setup himself.

### Canonical JSON for payload_sha256
Implemented once in `src/relayx/hashing.py` (`canonical_json`, `canonical_sha256`) and used
by the client and the loader. Definition: object keys sorted by Unicode code point,
recursively; separators `,` and `:` with no whitespace; non-ASCII characters written as
themselves (no `\u` escapes); UTF-8 without BOM or trailing newline; arrays keep their
order; values as parsed by Python's json module (NaN and Infinity rejected). The hash is
SHA-256 over those bytes, as 64 lowercase hex characters. `response_sha256` on pages is
SHA-256 over the raw response bytes, not canonical JSON.

### Retention
`data/raw/` is kept indefinitely during the trial. `python -m relayx.archive_run <run_dir>`
zips one run directory with its manifest and a SHA256SUMS file for archiving; Kevin stores
the archives.

### SQL files
- `sql/000_setup_role.sql`: run once by Kevin as `postgres`. Creates `relayx_app` (LOGIN, no
  password in the file; set interactively with `\password`), both schemas and the grants.
- `sql/001_raw_ops.sql`: run as `relayx_app` after the setup is confirmed. Tables below.

### DDL

Setup (`sql/000_setup_role.sql`), as `postgres`:

```sql
CREATE ROLE relayx_app LOGIN;   -- password set separately with \password relayx_app
CREATE SCHEMA relayx_raw AUTHORIZATION relayx_app;
CREATE SCHEMA relayx_ops AUTHORIZATION relayx_app;
GRANT USAGE ON SCHEMA covalo, kevin TO relayx_app;
GRANT SELECT ON ALL TABLES IN SCHEMA covalo, kevin TO relayx_app;
-- tables added to covalo later need a separate grant or default privileges set by their owner
```

Ops and raw tables (`sql/001_raw_ops.sql`), as `relayx_app`:

```sql
-- One row per extractor run. Mutable: status and counters change while the run is going.
CREATE TABLE relayx_ops.extract_run (
    run_id                  text PRIMARY KEY,              -- e.g. 20261019T143522Z_eu
    feed                    text NOT NULL,                 -- 'changes'
    params                  jsonb NOT NULL,                -- since, territory, limit
    started_at              timestamptz NOT NULL,
    finished_at             timestamptz,
    status                  text NOT NULL CHECK (status IN ('running','partial','complete','failed')),
    pages                   int,
    row_count               int,
    requests                int,
    units_used_from_headers int,                           -- undercounts batches (VE-6)
    last_cursor             text,
    final_cursor            text,
    last_next_since         timestamptz,
    raw_dir                 text NOT NULL,                 -- data/raw/changes_replay/<run_id>
    manifest                jsonb NOT NULL,                -- manifest.json as written
    loaded_at               timestamptz NOT NULL DEFAULT now()
);

-- One row per HTTP response, including non-200 (rule 5). Append-only.
CREATE TABLE relayx_raw.changes_page (
    run_id          text NOT NULL REFERENCES relayx_ops.extract_run (run_id),
    page_no         int  NOT NULL,
    requested_at    timestamptz NOT NULL,
    http_status     smallint NOT NULL,
    request_params  jsonb NOT NULL,                        -- as sent, incl. cursor
    cursor_sent     text,                                  -- null for the first page
    next_cursor     text,
    next_since      timestamptz,
    page_total      int,
    page_returned   int,
    truncated       boolean,
    response_bytes  int  NOT NULL,
    response_sha256 text NOT NULL,                         -- sha256 of the raw bytes
    rate_headers    jsonb,
    envelope        jsonb,                                 -- body minus changes[]; error body if non-200
    raw_file        text NOT NULL,                         -- path of the byte-exact page file
    loaded_at       timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (run_id, page_no)
);

-- One row per element of changes[], unchanged. Append-only.
CREATE TABLE relayx_raw.entry_version (
    run_id           text NOT NULL,
    page_no          int  NOT NULL,
    row_no           int  NOT NULL,                        -- position in changes[], from 1
    logical_entry_id text NOT NULL,                        -- verbatim, text not uuid
    known_since      timestamptz,                          -- knowledge time; nullable per contract
    change_kind      text,                                 -- no CHECK: raw accepts new values
    payload          jsonb NOT NULL,                       -- the element as served
    payload_sha256   text NOT NULL,                        -- canonical_sha256(payload), see above
    loaded_at        timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (run_id, page_no, row_no),
    FOREIGN KEY (run_id, page_no) REFERENCES relayx_raw.changes_page (run_id, page_no)
);
CREATE INDEX entry_version_entry_idx ON relayx_raw.entry_version (logical_entry_id, known_since);

-- Cursor of an entry row, as requested: available through its page.
CREATE VIEW relayx_raw.entry_version_with_page AS
SELECT e.*, p.cursor_sent, p.next_cursor, p.requested_at, p.response_sha256
FROM relayx_raw.entry_version e
JOIN relayx_raw.changes_page p USING (run_id, page_no);

-- Append-only guard.
CREATE FUNCTION relayx_raw.forbid_change() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'relayx_raw is append-only (% on %)', TG_OP, TG_TABLE_NAME;
END $$;
CREATE TRIGGER changes_page_append_only BEFORE UPDATE OR DELETE ON relayx_raw.changes_page
    FOR EACH ROW EXECUTE FUNCTION relayx_raw.forbid_change();
CREATE TRIGGER changes_page_no_truncate BEFORE TRUNCATE ON relayx_raw.changes_page
    FOR EACH STATEMENT EXECUTE FUNCTION relayx_raw.forbid_change();
CREATE TRIGGER entry_version_append_only BEFORE UPDATE OR DELETE ON relayx_raw.entry_version
    FOR EACH ROW EXECUTE FUNCTION relayx_raw.forbid_change();
CREATE TRIGGER entry_version_no_truncate BEFORE TRUNCATE ON relayx_raw.entry_version
    FOR EACH STATEMENT EXECUTE FUNCTION relayx_raw.forbid_change();
```

Deferred to phase 6 (diff pull), listed so the ops layer is complete:

```sql
CREATE TABLE relayx_ops.feed_cursor (
    feed          text NOT NULL,
    territory     text NOT NULL,
    cursor        text NOT NULL,                           -- last nextCursor, verbatim
    next_since    timestamptz,                             -- for dating only
    source_run_id text NOT NULL REFERENCES relayx_ops.extract_run (run_id),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (feed, territory)
);
```

### Load procedure (phase 2, after acceptance)
- Loader `src/relayx/load_raw.py` reads one run directory and inserts `extract_run`, then
  pages and rows in one transaction per run, with COPY. It refuses a run_id already loaded.
- Checks after the load: rows = manifest `rows` = sum of `page_returned`; each page's
  `response_sha256` equals the sha256 of its file; no duplicate
  (run_id, logical_entry_id, known_since). Reported in a results file.
- A later replay or diff pull is a new run_id. Duplicates across runs are expected and
  resolved in core, never by changing raw.

## Consequences
- Positive: raw is queryable for profiling; provenance (request, status, hashes, cursor)
  per page; non-200 responses kept as explicit rows; covalo becomes read-only by grant, not
  only by discipline; the layout transfers to production.
- Raw immutability is a guard against mistakes, not a guarantee (see Decision); production
  should move to option 4C.
- Raw responses of endpoints other than /changes are not in the database (see Scope).
- Negative: the replay is stored twice (files about 170 MB, database estimated 250 to
  350 MB with index). `jsonb` is not byte-exact; fidelity relies on the files plus hashes,
  so `data/raw/` must be kept (or archived) as long as the raw rows are.
- Only knowledge time (`known_since`) is a column in raw; law time (`validity.*`) stays in
  the payload until the core model (phase 4).
- `extract_run` is the one mutable table in this ADR; its history is the manifest files.

## Decisions taken on the proposal (Kevin, 2026-10-19)
1. Options 1C, 2B, 3C, 4B accepted, with: trigger rationale corrected and 4C named as the
   production route (a); scope limited to /changes (b); canonical JSON defined and
   implemented once (c).
2. Numbering: no extraction-strategy ADR exists yet, so this stays 001; the extraction
   strategy ADR will take the next free number.
3. Connections: `RELAYX_DATABASE_URL` for regular access; `DATABASE_URL` renamed
   `POSTGRES_ADMIN_URL`, setup only with explicit approval (CLAUDE.md hard rule).
4. Setup: Kevin runs `sql/000_setup_role.sql` and sets the password himself.
5. Retention: keep `data/raw/` during the trial; archive per run with `relayx.archive_run`.

## Date
2026-10-19 (proposed and accepted)
