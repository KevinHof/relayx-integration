-- ADR-001: raw and ops tables for the /changes feed.
-- Run as relayx_app (RELAYX_DATABASE_URL) after sql/000_setup_role.sql has been run by Kevin.
-- Not yet executed.

\set ON_ERROR_STOP on

BEGIN;

-- One row per extractor run. Mutable: status and counters change while the run is going.
CREATE TABLE relayx_ops.extract_run (
    run_id                  text PRIMARY KEY,
    feed                    text NOT NULL,
    params                  jsonb NOT NULL,
    started_at              timestamptz NOT NULL,
    finished_at             timestamptz,
    status                  text NOT NULL CHECK (status IN ('running','partial','complete','failed')),
    pages                   int,
    row_count               int,
    requests                int,
    units_used_from_headers int,
    last_cursor             text,
    final_cursor            text,
    last_next_since         timestamptz,
    raw_dir                 text NOT NULL,
    manifest                jsonb NOT NULL,
    loaded_at               timestamptz NOT NULL DEFAULT now()
);

-- One row per HTTP response, including non-200. Append-only.
CREATE TABLE relayx_raw.changes_page (
    run_id          text NOT NULL REFERENCES relayx_ops.extract_run (run_id),
    page_no         int  NOT NULL,
    requested_at    timestamptz NOT NULL,
    http_status     smallint NOT NULL,
    request_params  jsonb NOT NULL,
    cursor_sent     text,
    next_cursor     text,
    next_since      timestamptz,
    page_total      int,
    page_returned   int,
    truncated       boolean,
    response_bytes  int  NOT NULL,
    response_sha256 text NOT NULL,          -- sha256 of the raw response bytes
    rate_headers    jsonb,
    envelope        jsonb,                  -- body minus changes[]; error body if non-200
    raw_file        text NOT NULL,
    loaded_at       timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (run_id, page_no)
);

-- One row per element of changes[], unchanged. Append-only.
CREATE TABLE relayx_raw.entry_version (
    run_id           text NOT NULL,
    page_no          int  NOT NULL,
    row_no           int  NOT NULL,         -- position in changes[], from 1
    logical_entry_id text NOT NULL,         -- verbatim
    known_since      timestamptz,
    change_kind      text,
    payload          jsonb NOT NULL,
    payload_sha256   text NOT NULL,         -- relayx.hashing.canonical_sha256(payload)
    loaded_at        timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (run_id, page_no, row_no),
    FOREIGN KEY (run_id, page_no) REFERENCES relayx_raw.changes_page (run_id, page_no)
);
CREATE INDEX entry_version_entry_idx ON relayx_raw.entry_version (logical_entry_id, known_since);

CREATE VIEW relayx_raw.entry_version_with_page AS
SELECT e.*, p.cursor_sent, p.next_cursor, p.requested_at, p.response_sha256
FROM relayx_raw.entry_version e
JOIN relayx_raw.changes_page p USING (run_id, page_no);

-- Guard against accidental change from pipeline code. Not a guarantee: the owner can
-- drop or disable these triggers (see ADR-001, option 4C for production).
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

-- ADR-001 Amendment 1: one row per API call to any endpoint except /changes. Append-only.
CREATE TABLE relayx_raw.api_response (
    run_id          text NOT NULL REFERENCES relayx_ops.extract_run (run_id),
    call_no         int  NOT NULL,
    endpoint        text NOT NULL,
    method          text NOT NULL,
    request_params  jsonb NOT NULL,
    request_body    jsonb,
    source_ref      jsonb,
    requested_at    timestamptz NOT NULL,
    http_status     smallint NOT NULL,
    response_bytes  int  NOT NULL,
    response_sha256 text NOT NULL,          -- sha256 of the raw bytes
    body_sha256     text,                   -- relayx.hashing.canonical_sha256(body)
    rate_headers    jsonb,
    body            jsonb,
    raw_file        text NOT NULL,
    loaded_at       timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (run_id, call_no)
);
CREATE INDEX api_response_endpoint_idx ON relayx_raw.api_response (endpoint, requested_at);
CREATE TRIGGER api_response_append_only BEFORE UPDATE OR DELETE ON relayx_raw.api_response
    FOR EACH ROW EXECUTE FUNCTION relayx_raw.forbid_change();
CREATE TRIGGER api_response_no_truncate BEFORE TRUNCATE ON relayx_raw.api_response
    FOR EACH STATEMENT EXECUTE FUNCTION relayx_raw.forbid_change();

COMMIT;
