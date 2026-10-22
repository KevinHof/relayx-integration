-- PROVISIONAL. F2 lookup run profile (docs/plans/2026-10-20-f2-covalo-lookup.md).
-- Full run 20261022T075923Z_covalo_lookup_eu only (never the canary). Read-only; TEMP objects only.
-- Needs the F1 TEMP objects (cov_id, cov_raw, cov_val, rx_val):
--   python -m relayx.provisional_report sql/provisional/f2_lookup_profile.sql
--       --setup sql/provisional/f1_matching_assessment.sql --timeout 900
--
-- Rules:
--   Item = one element of a call's results[], tied to the item sent at the same index
--     (api_response.source_ref). Status = ingredientStatus.status when ok is true, 'ok=false'
--     otherwise. Units sent = items in request_body per call.
--   Server-side units per call = RateLimit-Limit - RateLimit-Remaining; our count = units sent
--     by this run in calls carrying the same RateLimit-Reset (one fixed 60-second window), up to
--     and including the call.
--   Product level: F1 cov_id values of the 70,664 products with a usable identifier, joined on
--     (type, value) to the items. CAS/EC values failing the check digit were not queried.
--   F1 replay match: product has at least one cov_id value found in the replay
--     (cov_val.in_replay, literal or enriched), as in F1 section c (24,677).
--   Returned logicalEntryIds: constraints[].logicalEntryId and upcoming[].logicalEntryId;
--     replay = relayx_raw.entry_version of run 20261019T143522Z_eu (all versions).

CREATE TEMP TABLE f2_call AS
SELECT call_no, http_status, request_body, source_ref, rate_headers, body
FROM relayx_raw.api_response WHERE run_id = '20261022T075923Z_covalo_lookup_eu';
CREATE UNIQUE INDEX ON f2_call (call_no);
ANALYZE f2_call;

CREATE TEMP TABLE f2_sent AS
SELECT c.call_no, (s.ord - 1)::int AS idx, (s.ref ->> 'item')::int AS seq, s.ref ->> 'type' AS id_type,
       s.ref ->> 'value' AS value, (s.ref ->> 'products')::int AS products
FROM f2_call c CROSS JOIN LATERAL jsonb_array_elements(c.source_ref) WITH ORDINALITY AS s(ref, ord);
CREATE INDEX ON f2_sent (call_no, idx);

CREATE TEMP TABLE f2_item AS
SELECT c.call_no, (r ->> 'index')::int AS idx, s.seq, s.id_type, s.value, s.products,
       (r ->> 'ok')::boolean AS ok, r ->> 'error' AS error, r ->> 'message' AS message,
       CASE WHEN (r ->> 'ok')::boolean THEN r -> 'ingredientStatus' ->> 'status' ELSE 'ok=false' END AS status,
       (r ->> 'total')::int AS total, (r ->> 'returned')::int AS returned,
       CASE WHEN jsonb_typeof(r -> 'constraints') = 'array' THEN jsonb_array_length(r -> 'constraints') END AS n_constraints,
       (r ->> 'scanCapped')::boolean AS scan_capped, (r ->> 'truncated')::boolean AS item_truncated
FROM f2_call c
CROSS JOIN LATERAL jsonb_array_elements(CASE WHEN jsonb_typeof(c.body -> 'results') = 'array' THEN c.body -> 'results' ELSE '[]' END) AS r
LEFT JOIN f2_sent s ON s.call_no = c.call_no AND s.idx = (r ->> 'index')::int;
CREATE INDEX ON f2_item (id_type, value);
CREATE INDEX ON f2_item (seq);
ANALYZE f2_item;

-- Returned logicalEntryIds per item.
CREATE TEMP TABLE f2_entry AS
SELECT c.call_no, (r ->> 'index')::int AS idx, b.block, e ->> 'logicalEntryId' AS logical_entry_id
FROM f2_call c
CROSS JOIN LATERAL jsonb_array_elements(CASE WHEN jsonb_typeof(c.body -> 'results') = 'array' THEN c.body -> 'results' ELSE '[]' END) AS r
CROSS JOIN (VALUES ('constraints'), ('upcoming')) AS b(block)
CROSS JOIN LATERAL jsonb_array_elements(CASE WHEN jsonb_typeof(r -> b.block) = 'array' THEN r -> b.block ELSE '[]' END) AS e
WHERE e ? 'logicalEntryId';
CREATE INDEX ON f2_entry (logical_entry_id);

CREATE TEMP TABLE f2_replay_id AS
SELECT DISTINCT logical_entry_id FROM relayx_raw.entry_version WHERE run_id = '20261019T143522Z_eu';
CREATE UNIQUE INDEX ON f2_replay_id (logical_entry_id);

-- Product x queried value x status (products with a usable F1 identifier).
CREATE TEMP TABLE f2_prod_val AS
SELECT i.product_id, i.id_type, i.value, i.check_ok, f.status
FROM cov_id i LEFT JOIN f2_item f ON f.id_type = i.id_type AND f.value = i.value;
CREATE INDEX ON f2_prod_val (product_id);
ANALYZE f2_prod_val;

CREATE TEMP TABLE f2_prod AS
SELECT product_id,
       bool_or(status = 'HAS_DATA') AS has_data,
       bool_or(status = 'KNOWN_WITHOUT_DATA') AS kwd,
       bool_or(status = 'UNKNOWN_IDENTIFIER') AS unk,
       bool_or(status = 'NOT_SEARCHED') AS not_searched,
       bool_or(status = 'ok=false') AS ok_false,
       bool_or(status IS NOT NULL) AS queried,
       bool_or(status IS NULL) AS has_unqueried
FROM f2_prod_val GROUP BY product_id;
ALTER TABLE f2_prod ADD COLUMN category text;
UPDATE f2_prod SET category = CASE
    WHEN has_data THEN 'a. at least one HAS_DATA'
    WHEN not_searched THEN 'f. NOT_SEARCHED involved, no HAS_DATA'
    WHEN kwd AND NOT unk THEN 'b. only KNOWN_WITHOUT_DATA'
    WHEN unk AND NOT kwd THEN 'c. only UNKNOWN_IDENTIFIER'
    WHEN kwd AND unk THEN 'd. KNOWN_WITHOUT_DATA and UNKNOWN_IDENTIFIER'
    WHEN ok_false THEN 'e. only ok=false'
    ELSE 'g. no queried value (check-digit failures only)' END;

CREATE TEMP TABLE f2_f1_match AS
SELECT DISTINCT i.product_id FROM cov_id i JOIN cov_val v USING (id_type, value) WHERE v.in_replay;

-- Drill-down (sections b1 to b6) -------------------------------------------------------------
-- B4 (Kevin, 2026-10-22), per group (product, matched replay entry, matched Covalo value), first
--   class that applies in this order:
--   2 guard: entryScope not GROUP / GENERIC_CLASS, and the lookup body for the matched value has an
--     identifierCaveats note reporting entries set aside (note text "were NOT returned" or "were
--     removed"). 2a confirmed: the note names this entry's logicalEntryId, or a number this entry
--     prints in its own identifier field of the searched type (identifiers cas/casList for a CAS
--     search, ec/ecList for an EC search; F1 tokens); numbers are taken from the note only by exact
--     CAS (\d{2,7}-\d{2}-\d) or EC (\d{3}-\d{3}-\d) pattern. 2b probable: otherwise.
--   1 GROUP: entryScope GROUP or GENERIC_CLASS.
--   3 exemption or inventory: annexType EXEMPTION or INVENTORY_LISTED.
--   4 other.
--   F1 match route per group (F1 rules unchanged, value derivations as in rx_id): own printed field
--   (identifiers cas/ec/inci/name/nameEn/clpIndex/colourIndex strings and casList/ecList/inciList),
--   linked substance with printedByText true, enriched (linked substance printedByText false,
--   nomenclature, synonyms). The v1.1 guide could not be read here (no PDF reader).
--   Scope class as in sql/provisional/f1b_additions.sql (docs/data-model/cosmetics-scope.md, PROPOSED).
-- B5 routes, per (product, HAS_DATA value, returned constraint): reachedViaGroupEntry true; INCI
--   index enrichment = INCI item and matchedBy contains substanceIndex; other.

CREATE TEMP TABLE f2_item_extra AS
SELECT f.call_no, f.idx, f.id_type, f.value, r -> 'identifierCaveats' AS caveats, r -> 'withheldByIdentifier' AS withheld,
       EXISTS (SELECT 1 FROM jsonb_array_elements(CASE WHEN jsonb_typeof(r -> 'identifierCaveats') = 'array' THEN r -> 'identifierCaveats' ELSE '[]' END) e
               WHERE e ->> 'note' LIKE '%its own text prints a DIFFERENT number in the field you searched%') AS guard_caveat
FROM f2_item f JOIN f2_call c USING (call_no)
CROSS JOIN LATERAL jsonb_array_elements(c.body -> 'results') r
WHERE (r ->> 'index')::int = f.idx;
CREATE INDEX ON f2_item_extra (id_type, value);

CREATE TEMP TABLE f2_constraint AS
SELECT c.call_no, (r ->> 'index')::int AS idx, k ->> 'logicalEntryId' AS logical_entry_id, k -> 'matchedBy' AS matched_by,
       coalesce((k ->> 'reachedViaGroupEntry')::boolean, false) AS via_group, k ->> 'annexType' AS annex_type,
       k ->> 'annexRef' AS annex_ref, k ->> 'entryRef' AS entry_ref, k ->> 'entryScope' AS entry_scope
FROM f2_call c
CROSS JOIN LATERAL jsonb_array_elements(c.body -> 'results') r
CROSS JOIN LATERAL jsonb_array_elements(CASE WHEN jsonb_typeof(r -> 'constraints') = 'array' THEN r -> 'constraints' ELSE '[]' END) k;
CREATE INDEX ON f2_constraint (call_no, idx);

CREATE TEMP TABLE f2_entry_class AS
SELECT DISTINCT ON (e.logical_entry_id) e.logical_entry_id, e.annex_type, e.entry_scope, ev.annex_ref, ev.entry_ref,
       CASE WHEN ev.annex_ref IN ('Annex II', 'Annex III', 'Annex IV', 'Annex V', 'Annex VI', 'Article 15(1)', 'Article 15(2)')
                 THEN '1 core cosmetics'
            WHEN ev.annex_ref IN ('Annex VI Table 3', 'REACH Annex XVII', 'REACH Annex XIV', 'REACH Candidate List',
                               'POPs Regulation', 'Annex I, part A') THEN '2 indirectly relevant'
            WHEN ev.annex_ref IN ('CMR category 1A', 'CMR category 1B', 'Mutagens', 'Toxic category 1', 'Toxic category 2')
                 THEN '3 REACH CMR appendices (class open)'
            WHEN ev.text_ref IN ('32026R1383', '32025R0006') THEN '4 marginal'
            WHEN ev.annex_ref IN ('Exemptions', 'REACH Annex V') THEN '5 not relevant'
            ELSE '9 unclassified' END AS scope_class
FROM rx_entry e
JOIN (SELECT DISTINCT logical_entry_id, payload ->> 'annexRef' AS annex_ref, payload ->> 'entryRef' AS entry_ref,
             payload -> 'text' ->> 'officialRef' AS text_ref
      FROM relayx_raw.entry_version WHERE run_id = '20261019T143522Z_eu') ev USING (logical_entry_id)
ORDER BY e.logical_entry_id;
CREATE UNIQUE INDEX ON f2_entry_class (logical_entry_id);

-- B4: F1 values per entry, tagged with the route F1 took (same derivations as F1 rx_id).
CREATE TEMP TABLE f2_rx_route AS
SELECT p.logical_entry_id, p.id_type, t.value, 'own field' AS route
FROM rx_printed p CROSS JOIN LATERAL pg_temp.tokens(p.raw_value, p.id_type) AS t(value) WHERE p.id_type IN ('CAS', 'EC')
UNION
SELECT e.logical_entry_id, l.id_type, CASE WHEN l.id_type = 'INCI' THEN pg_temp.norm_inci(v #>> '{}') ELSE v #>> '{}' END, 'own field'
FROM rx_entry e
CROSS JOIN (VALUES ('casList', 'CAS'), ('ecList', 'EC'), ('inciList', 'INCI')) AS l(key, id_type)
CROSS JOIN LATERAL jsonb_array_elements(
    CASE WHEN jsonb_typeof(e.payload -> 'identifiers' -> l.key) = 'array' THEN e.payload -> 'identifiers' -> l.key ELSE '[]' END) AS v
UNION
SELECT p.logical_entry_id, p.id_type, CASE p.id_type WHEN 'INCI' THEN pg_temp.norm_inci(s) ELSE pg_temp.norm_name(s) END, 'own field'
FROM rx_printed p CROSS JOIN LATERAL regexp_split_to_table(p.raw_value, '\s*\[\d+\]\s*|;') AS s
WHERE p.id_type IN ('INCI', 'NAME')
UNION
SELECT p.logical_entry_id, p.id_type, pg_temp.norm_inci(p.raw_value), 'own field'
FROM rx_printed p WHERE p.id_type IN ('CLP_INDEX', 'COLOUR_INDEX')
UNION
SELECT e.logical_entry_id,
       CASE WHEN i ->> 'type' IN ('LOCAL_NAME', 'SYNONYM') THEN 'NAME' ELSE i ->> 'type' END,
       CASE WHEN i ->> 'type' IN ('LOCAL_NAME', 'SYNONYM') THEN pg_temp.norm_name(i ->> 'value')
            WHEN i ->> 'type' IN ('CAS', 'EC') THEN pg_temp.prep(btrim(i ->> 'value'))
            ELSE pg_temp.norm_inci(i ->> 'value') END,
       CASE WHEN (i ->> 'printedByText')::boolean THEN 'linked printedByText' ELSE 'enriched' END
FROM rx_entry e
CROSS JOIN LATERAL jsonb_array_elements(
    CASE WHEN jsonb_typeof(e.payload -> 'linkedSubstances') = 'array' THEN e.payload -> 'linkedSubstances' ELSE '[]' END) AS ls
CROSS JOIN LATERAL jsonb_array_elements(
    CASE WHEN jsonb_typeof(ls -> 'identifiers') = 'array' THEN ls -> 'identifiers' ELSE '[]' END) AS i
UNION
SELECT e.logical_entry_id, n.id_type,
       CASE WHEN n.id_type = 'NAME' THEN pg_temp.norm_name(n.v) ELSE pg_temp.norm_inci(n.v) END, 'enriched'
FROM rx_entry e
CROSS JOIN LATERAL (VALUES
    ('INCI', e.payload -> 'nomenclature' ->> 'inciEu'),
    ('INCI', e.payload -> 'nomenclature' ->> 'inciUs'),
    ('INCI', e.payload -> 'nomenclature' ->> 'inciIecic'),
    ('NAME', e.payload -> 'nomenclature' ->> 'chemicalName'),
    ('COLOUR_INDEX', e.payload -> 'nomenclature' ->> 'colourIndex')) AS n(id_type, v)
WHERE n.v IS NOT NULL
UNION
SELECT e.logical_entry_id, 'NAME', pg_temp.norm_name(s #>> '{}'), 'enriched'
FROM rx_entry e
CROSS JOIN LATERAL jsonb_array_elements(
    CASE WHEN jsonb_typeof(e.payload -> 'nomenclature' -> 'synonyms') = 'array' THEN e.payload -> 'nomenclature' -> 'synonyms' ELSE '[]' END) AS s;
DELETE FROM f2_rx_route WHERE value IS NULL;
CREATE INDEX ON f2_rx_route (id_type, value);
CREATE INDEX ON f2_rx_route (logical_entry_id);

-- B4: set-aside caveat notes per queried value, with the numbers they show (exact patterns).
CREATE TEMP TABLE f2_setaside AS
SELECT x.id_type, x.value, e ->> 'note' AS note,
       ARRAY(SELECT DISTINCT m[1] FROM regexp_matches(e ->> 'note', '(?<!\d)(\d{2,7}-\d{2}-\d)(?!\d)', 'g') m) AS cas_in_note,
       ARRAY(SELECT DISTINCT m[1] FROM regexp_matches(e ->> 'note', '(?<!\d)(\d{3}-\d{3}-\d)(?!\d)', 'g') m) AS ec_in_note
FROM f2_item_extra x
CROSS JOIN LATERAL jsonb_array_elements(CASE WHEN jsonb_typeof(x.caveats) = 'array' THEN x.caveats ELSE '[]' END) e
WHERE e ->> 'note' ~ '(were NOT returned|were removed)';
CREATE INDEX ON f2_setaside (id_type, value);

-- B4: replay-only products, matched (entry, value) groups with route, flags and class.
CREATE TEMP TABLE f2_b4 AS
WITH m AS (
    SELECT i.product_id, i.id_type, i.value, r.logical_entry_id,
           bool_or(r.route = 'own field') AS own_field, bool_or(r.route = 'linked printedByText') AS linked_printed,
           bool_or(r.route = 'enriched') AS enriched
    FROM cov_id i JOIN f2_rx_route r USING (id_type, value)
    WHERE i.product_id IN (SELECT product_id FROM f2_f1_match)
      AND i.product_id IN (SELECT product_id FROM f2_prod WHERE NOT has_data)
    GROUP BY 1, 2, 3, 4),
g AS (
    SELECT m.*, ec.annex_type, ec.entry_scope, ec.annex_ref, ec.entry_ref, ec.scope_class, f.status,
           ec.entry_scope IN ('GROUP', 'GENERIC_CLASS') AS c_group,
           ec.annex_type IN ('EXEMPTION', 'INVENTORY_LISTED') AS c_exempt,
           ec.entry_scope NOT IN ('GROUP', 'GENERIC_CLASS')
               AND EXISTS (SELECT 1 FROM f2_setaside s WHERE s.id_type = m.id_type AND s.value = m.value) AS c_setaside,
           EXISTS (SELECT 1 FROM f2_setaside s WHERE s.id_type = m.id_type AND s.value = m.value
                   AND (position(m.logical_entry_id IN s.note) > 0
                        OR (m.id_type = 'CAS' AND s.cas_in_note && ARRAY(SELECT o.value FROM f2_rx_route o WHERE o.logical_entry_id = m.logical_entry_id
                                                                           AND o.id_type = 'CAS' AND o.route = 'own field'))
                        OR (m.id_type = 'EC' AND s.ec_in_note && ARRAY(SELECT o.value FROM f2_rx_route o WHERE o.logical_entry_id = m.logical_entry_id
                                                                         AND o.id_type = 'EC' AND o.route = 'own field')))) AS attributable,
           (SELECT string_agg(DISTINCT o.value, ' | ') FROM f2_rx_route o WHERE o.logical_entry_id = m.logical_entry_id
              AND o.id_type = m.id_type AND o.route = 'own field') AS entry_own_field
    FROM m JOIN f2_entry_class ec USING (logical_entry_id)
    LEFT JOIN f2_item f ON f.id_type = m.id_type AND f.value = m.value)
SELECT g.*,
       CASE WHEN own_field THEN 'own printed field' WHEN linked_printed THEN 'linked substance printedByText' ELSE 'enriched' END AS f1_route,
       CASE WHEN c_setaside AND attributable THEN '2a guard, confirmed'
            WHEN c_setaside THEN '2b guard, probable'
            WHEN c_group THEN '1 GROUP'
            WHEN c_exempt THEN '3 exemption or inventory'
            ELSE '4 other' END AS b4_class,
       CASE WHEN c_setaside THEN 1 WHEN c_group THEN 2 WHEN c_exempt THEN 3 ELSE 4 END AS prec
FROM g;

-- B5: lookup-only products, routes of their HAS_DATA constraints.
CREATE TEMP TABLE f2_b5 AS
SELECT DISTINCT v.product_id, f.id_type, f.value, k.logical_entry_id, k.annex_type, k.annex_ref, k.entry_ref,
       CASE WHEN k.via_group THEN '1 reachedViaGroupEntry'
            WHEN f.id_type = 'INCI' AND k.matched_by ? 'substanceIndex' THEN '2 INCI index enrichment'
            ELSE '3 other' END AS route, k.matched_by::text AS matched_by
FROM f2_prod_val v
JOIN f2_item f ON f.id_type = v.id_type AND f.value = v.value AND f.status = 'HAS_DATA'
JOIN f2_constraint k ON k.call_no = f.call_no AND k.idx = f.idx
WHERE v.product_id IN (SELECT product_id FROM f2_prod WHERE has_data)
  AND v.product_id NOT IN (SELECT product_id FROM f2_f1_match);

-- REPORT

-- r1. PROVISIONAL. Run integrity: calls, units sent, results, distinct items, value-list size, HTTP status
SELECT (SELECT count(*) FROM f2_call) AS calls,
       (SELECT count(*) FILTER (WHERE http_status <> 200) FROM f2_call) AS non_200_calls,
       (SELECT sum(jsonb_array_length(request_body -> 'items')) FROM f2_call) AS units_sent,
       (SELECT (manifest ->> 'units_used')::int FROM relayx_ops.extract_run WHERE run_id = '20261022T075923Z_covalo_lookup_eu') AS manifest_units_used,
       (SELECT (manifest -> 'params' ->> 'items_selected')::int FROM relayx_ops.extract_run WHERE run_id = '20261022T075923Z_covalo_lookup_eu') AS items_selected,
       (SELECT count(*) FROM f2_item) AS result_rows,
       (SELECT count(DISTINCT seq) FROM f2_item) AS distinct_items_answered,
       (SELECT count(*) FROM f2_item WHERE seq IS NULL) AS results_without_sent_item,
       (SELECT min(seq) || '..' || max(seq) FROM f2_item) AS seq_range,
       (SELECT count(*) FROM f2_call WHERE (body ->> 'truncated')::boolean) AS truncated_calls,
       (SELECT sum((body ->> 'requested')::int) FROM f2_call) AS sum_requested,
       (SELECT sum((body ->> 'returned')::int) FROM f2_call) AS sum_returned

-- r2. PROVISIONAL. RateLimit-Remaining vs our own count (per call, same RateLimit-Reset window)
WITH c AS (
    SELECT call_no, jsonb_array_length(request_body -> 'items') AS n,
           (rate_headers ->> 'RateLimit-Limit')::int AS lim, (rate_headers ->> 'RateLimit-Remaining')::int AS rem,
           rate_headers ->> 'RateLimit-Reset' AS reset, rate_headers ->> 'RateLimit-Policy' AS policy
    FROM f2_call),
w AS (
    SELECT c.*, lim - rem AS server_used,
           sum(n) OVER (PARTITION BY reset ORDER BY call_no) AS ours_in_window
    FROM c)
SELECT count(*) AS calls, count(DISTINCT reset) AS windows,
       string_agg(DISTINCT policy, ', ') AS policies, string_agg(DISTINCT lim::text, ', ') AS limits,
       count(*) FILTER (WHERE server_used = ours_in_window) AS equal,
       count(*) FILTER (WHERE server_used > ours_in_window) AS server_higher,
       count(*) FILTER (WHERE server_used < ours_in_window) AS server_lower,
       max(ours_in_window) AS max_ours_in_window, max(server_used) AS max_server_used,
       count(*) FILTER (WHERE rem = 0) AS calls_remaining_0
FROM w

-- r2b. PROVISIONAL. Calls where RateLimit-Remaining and our count disagree (first 20)
WITH c AS (
    SELECT call_no, jsonb_array_length(request_body -> 'items') AS n,
           (rate_headers ->> 'RateLimit-Limit')::int AS lim, (rate_headers ->> 'RateLimit-Remaining')::int AS rem,
           rate_headers ->> 'RateLimit-Reset' AS reset, (body ->> 'returned')::int AS returned, body ->> 'truncatedReason' AS reason
    FROM f2_call),
w AS (SELECT c.*, lim - rem AS server_used, sum(n) OVER (PARTITION BY reset ORDER BY call_no) AS ours_in_window FROM c)
SELECT call_no, n AS sent, returned, reason, lim, rem, reset, server_used, ours_in_window, server_used - ours_in_window AS diff
FROM w WHERE server_used <> ours_in_window ORDER BY call_no LIMIT 20

-- r3. PROVISIONAL. Truncated calls and the next call: items sent, returned, reason, unevaluated items, items of the next call
SELECT c.call_no, jsonb_array_length(c.request_body -> 'items') AS sent, (c.body ->> 'returned')::int AS returned,
       c.body ->> 'truncatedReason' AS reason, c.rate_headers ->> 'Retry-After' AS retry_after,
       (SELECT string_agg(s.seq::text, ',' ORDER BY s.idx) FROM f2_sent s WHERE s.call_no = c.call_no
           AND NOT EXISTS (SELECT 1 FROM f2_item i WHERE i.call_no = c.call_no AND i.idx = s.idx)) AS unevaluated_seq,
       (SELECT max(i.idx) FROM f2_item i WHERE i.call_no = c.call_no) AS last_returned_index,
       (SELECT string_agg(s.seq::text, ',' ORDER BY s.idx) FROM f2_sent s WHERE s.call_no = c.call_no + 1) AS next_call_seq,
       (SELECT count(*) FROM f2_sent s WHERE s.call_no = c.call_no + 1) AS next_call_items
FROM f2_call c WHERE (c.body ->> 'truncated')::boolean

-- r3b. PROVISIONAL. Unevaluated items of truncated calls: answered later exactly once, never in the truncated call's ledger
SELECT s.call_no AS truncated_call, s.idx, s.seq, s.id_type, s.value,
       (SELECT count(*) FROM f2_item i WHERE i.seq = s.seq) AS times_answered,
       (SELECT string_agg(i.call_no::text, ',') FROM f2_item i WHERE i.seq = s.seq) AS answered_in_call,
       (SELECT count(*) FROM relayx_ops.extract_run x, jsonb_array_elements(x.manifest -> 'ledger') l
         WHERE x.run_id = '20261022T075923Z_covalo_lookup_eu' AND (l ->> 'call_no')::int = s.call_no
           AND (l ->> 'index')::int = s.idx) AS ledger_rows_in_truncated_call
FROM f2_sent s JOIN f2_call c ON c.call_no = s.call_no AND (c.body ->> 'truncated')::boolean
WHERE NOT EXISTS (SELECT 1 FROM f2_item i WHERE i.call_no = s.call_no AND i.idx = s.idx)
ORDER BY s.idx

-- r3c. PROVISIONAL. Items answered more than once, items sent but never answered
SELECT (SELECT count(*) FROM (SELECT seq FROM f2_item GROUP BY seq HAVING count(*) > 1) x) AS answered_more_than_once,
       (SELECT count(DISTINCT s.seq) FROM f2_sent s WHERE NOT EXISTS (SELECT 1 FROM f2_item i WHERE i.seq = s.seq)) AS sent_never_answered,
       (SELECT count(*) FROM f2_sent) AS sent_rows, (SELECT count(DISTINCT seq) FROM f2_sent) AS distinct_sent

-- r4. PROVISIONAL. Ledger in relayx_ops.extract_run.manifest vs stored bodies (call_no, index, item, type, value, ok, error, message, status)
WITH l AS (
    SELECT (e ->> 'call_no')::int AS call_no, (e ->> 'index')::int AS idx, (e ->> 'item')::int AS seq, e ->> 'type' AS id_type,
           e ->> 'value' AS value, (e ->> 'ok')::boolean AS ok, e ->> 'error' AS error, e ->> 'message' AS message,
           e ->> 'ingredient_status' AS ingredient_status
    FROM relayx_ops.extract_run x, jsonb_array_elements(x.manifest -> 'ledger') e
    WHERE x.run_id = '20261022T075923Z_covalo_lookup_eu'),
b AS (
    SELECT call_no, idx, seq, id_type, value, ok, error, message, CASE WHEN ok THEN status END AS ingredient_status FROM f2_item)
SELECT (SELECT count(*) FROM l) AS ledger_rows, (SELECT count(*) FROM b) AS body_results,
       count(*) FILTER (WHERE l.call_no IS NULL) AS only_in_bodies, count(*) FILTER (WHERE b.call_no IS NULL) AS only_in_ledger,
       count(*) FILTER (WHERE l.call_no IS NOT NULL AND b.call_no IS NOT NULL
           AND (l.seq, l.id_type, l.value, l.ok, coalesce(l.error, ''), coalesce(l.message, ''), coalesce(l.ingredient_status, ''))
               IS DISTINCT FROM (b.seq, b.id_type, b.value, b.ok, coalesce(b.error, ''), coalesce(b.message, ''), coalesce(b.ingredient_status, ''))) AS field_mismatches
FROM l FULL JOIN b USING (call_no, idx)

-- r5. PROVISIONAL. ok=false items: error, value, Covalo products (value list) and raw strings behind the value
SELECT f.seq, f.id_type, f.value, f.error, f.message, f.products,
       (SELECT count(DISTINCT r.raw_value) FROM cov_raw r WHERE r.id_type = 'INCI' AND pg_temp.norm_inci(r.raw_value) = f.value) AS raw_variants,
       (SELECT string_agg(DISTINCT '[' || r.raw_value || ']', ' ') FROM cov_raw r WHERE r.id_type = 'INCI' AND pg_temp.norm_inci(r.raw_value) = f.value) AS raw_strings,
       (SELECT round(avg(n), 1) FROM (SELECT count(*) AS n FROM cov_raw r2 WHERE r2.id_type = 'INCI'
            AND r2.product_id IN (SELECT r.product_id FROM cov_raw r WHERE r.id_type = 'INCI' AND pg_temp.norm_inci(r.raw_value) = f.value)
            GROUP BY r2.product_id) x) AS avg_inci_elements_on_those_products
FROM f2_item f WHERE NOT f.ok ORDER BY f.products DESC, f.value

-- r5b. PROVISIONAL. ok=false items: totals (distinct products carrying at least one of them, by product type)
SELECT count(*) AS ok_false_items, string_agg(DISTINCT f.error, ', ') AS errors, string_agg(DISTINCT f.id_type, ', ') AS types,
       sum(f.products) AS product_links,
       (SELECT count(DISTINCT i.product_id) FROM cov_id i JOIN f2_item g ON g.id_type = i.id_type AND g.value = i.value WHERE NOT g.ok) AS distinct_products,
       (SELECT count(DISTINCT i.product_id) FROM cov_id i JOIN f2_item g ON g.id_type = i.id_type AND g.value = i.value
         JOIN f2_prod p USING (product_id) WHERE NOT g.ok AND p.category = 'e. only ok=false') AS products_with_only_ok_false,
       max(length(f.value)) AS max_length, min(length(f.value)) AS min_length
FROM f2_item f WHERE NOT f.ok

-- r6. PROVISIONAL. ingredientStatus by identifier type (share of the queried items of that type)
SELECT id_type, status, count(*) AS items,
       round(100.0 * count(*) / sum(count(*)) OVER (PARTITION BY id_type), 1) AS pct_of_type,
       sum(products) AS product_links
FROM f2_item GROUP BY 1, 2 ORDER BY 1, 2

-- r6b. PROVISIONAL. ingredientStatus, all types
SELECT status, count(*) AS items, round(100.0 * count(*) / sum(count(*)) OVER (), 1) AS pct, sum(products) AS product_links
FROM f2_item GROUP BY 1 ORDER BY 1

-- r7. PROVISIONAL. Product level (products with a usable F1 identifier)
SELECT category, count(*) AS products, round(100.0 * count(*) / sum(count(*)) OVER (), 1) AS pct,
       count(*) FILTER (WHERE ok_false) AS also_ok_false_value, count(*) FILTER (WHERE has_unqueried) AS also_unqueried_value
FROM f2_prod GROUP BY 1 ORDER BY 1

-- r8. PROVISIONAL. HAS_DATA products vs F1 replay match (24,677)
SELECT count(*) AS products,
       count(*) FILTER (WHERE p.has_data AND m.product_id IS NOT NULL) AS both,
       count(*) FILTER (WHERE p.has_data AND m.product_id IS NULL) AS lookup_only,
       count(*) FILTER (WHERE NOT coalesce(p.has_data, false) AND m.product_id IS NOT NULL) AS replay_only,
       count(*) FILTER (WHERE NOT coalesce(p.has_data, false) AND m.product_id IS NULL) AS neither,
       (SELECT count(*) FROM f2_f1_match) AS f1_replay_match
FROM f2_prod p LEFT JOIN f2_f1_match m USING (product_id)

-- r8b. PROVISIONAL. Replay-only products: their best lookup status (category), for review
SELECT p.category, count(*) AS products
FROM f2_prod p JOIN f2_f1_match m USING (product_id) WHERE NOT p.has_data GROUP BY 1 ORDER BY 1

-- r8c. PROVISIONAL. Lookup-only products: identifier types carrying HAS_DATA
SELECT has_data_types, count(*) AS products
FROM (SELECT p.product_id, string_agg(DISTINCT v.id_type, '+' ORDER BY v.id_type) AS has_data_types
      FROM f2_prod p JOIN f2_prod_val v USING (product_id)
      WHERE p.has_data AND v.status = 'HAS_DATA' AND p.product_id NOT IN (SELECT product_id FROM f2_f1_match)
      GROUP BY p.product_id) x
GROUP BY 1 ORDER BY 2 DESC

-- r9. PROVISIONAL. Items whose total exceeds the constraints returned (limit 100)
SELECT seq, id_type, value, total, returned, n_constraints, scan_capped, item_truncated, products, status
FROM f2_item WHERE total > coalesce(n_constraints, 0) OR total > returned OR scan_capped ORDER BY total DESC, value

-- r10. PROVISIONAL. Status disagreement within products: at least two identifier types whose statuses differ (ok=false counted as a status); per combination of status sets
WITH t AS (
    SELECT product_id, id_type, string_agg(DISTINCT status, '/' ORDER BY status) AS statuses
    FROM f2_prod_val WHERE status IS NOT NULL GROUP BY 1, 2),
p AS (
    SELECT product_id, count(*) AS n_types, count(DISTINCT statuses) AS n_distinct,
           string_agg(id_type || ':' || statuses, ' | ' ORDER BY id_type) AS combination,
           (SELECT string_agg(DISTINCT s, ' + ' ORDER BY s) FROM unnest(array_agg(statuses)) u(x), regexp_split_to_table(u.x, '/') s) AS status_set
    FROM t GROUP BY 1)
SELECT status_set, count(*) AS products FROM p WHERE n_types > 1 AND n_distinct > 1 GROUP BY 1 ORDER BY 2 DESC

-- r10b. PROVISIONAL. Status disagreement: per type-and-status combination (all combinations)
WITH t AS (
    SELECT product_id, id_type, string_agg(DISTINCT status, '/' ORDER BY status) AS statuses
    FROM f2_prod_val WHERE status IS NOT NULL GROUP BY 1, 2),
p AS (
    SELECT product_id, count(*) AS n_types, count(DISTINCT statuses) AS n_distinct,
           string_agg(id_type || ':' || statuses, ' | ' ORDER BY id_type) AS combination
    FROM t GROUP BY 1)
SELECT combination, count(*) AS products FROM p WHERE n_types > 1 AND n_distinct > 1 GROUP BY 1 ORDER BY 2 DESC, 1

-- r10c. PROVISIONAL. Status disagreement: totals (products with two or more queried types; with differing statuses)
WITH t AS (
    SELECT product_id, id_type, string_agg(DISTINCT status, '/' ORDER BY status) AS statuses
    FROM f2_prod_val WHERE status IS NOT NULL GROUP BY 1, 2),
p AS (SELECT product_id, count(*) AS n_types, count(DISTINCT statuses) AS n_distinct FROM t GROUP BY 1)
SELECT count(*) FILTER (WHERE n_types > 1) AS products_two_or_more_types,
       count(*) FILTER (WHERE n_types > 1 AND n_distinct > 1) AS products_statuses_differ
FROM p

-- r11. PROVISIONAL. Returned logicalEntryIds vs the replay
SELECT block, count(*) AS rows_, count(DISTINCT logical_entry_id) AS distinct_ids,
       count(DISTINCT logical_entry_id) FILTER (WHERE logical_entry_id IN (SELECT logical_entry_id FROM f2_replay_id)) AS in_replay,
       count(DISTINCT logical_entry_id) FILTER (WHERE logical_entry_id NOT IN (SELECT logical_entry_id FROM f2_replay_id)) AS not_in_replay
FROM f2_entry GROUP BY 1 ORDER BY 1

-- r11b. PROVISIONAL. Returned logicalEntryIds not in the replay (all)
SELECT e.logical_entry_id, e.block, count(*) AS items_returning_it,
       string_agg(DISTINCT i.id_type || '=' || i.value, ' | ') AS example_items
FROM f2_entry e JOIN f2_item i USING (call_no, idx)
WHERE e.logical_entry_id NOT IN (SELECT logical_entry_id FROM f2_replay_id)
GROUP BY 1, 2 ORDER BY 3 DESC, 1;

-- r11c. PROVISIONAL. Entries not in the replay: knownSince, annex, entry (replay latest knownSince for comparison)
SELECT DISTINCT c ->> 'logicalEntryId' AS logical_entry_id, c ->> 'knownSince' AS known_since, c ->> 'annexRef' AS annex_ref,
       c ->> 'entryRef' AS entry_ref, c ->> 'annexType' AS annex_type,
       (SELECT max(known_since) FROM relayx_raw.entry_version WHERE run_id = '20261019T143522Z_eu') AS replay_latest_known_since
FROM f2_call a, jsonb_array_elements(a.body -> 'results') r, jsonb_array_elements(r -> 'constraints') c
WHERE c ->> 'logicalEntryId' NOT IN (SELECT logical_entry_id FROM f2_replay_id)

-- r2c. PROVISIONAL. Quota windows where RateLimit-Remaining and our count disagree
WITH c AS (
    SELECT call_no, jsonb_array_length(request_body -> 'items') AS n,
           (rate_headers ->> 'RateLimit-Limit')::int - (rate_headers ->> 'RateLimit-Remaining')::int AS server_used,
           rate_headers ->> 'RateLimit-Reset' AS reset
    FROM f2_call),
w AS (SELECT c.*, sum(n) OVER (PARTITION BY reset ORDER BY call_no) AS ours FROM c)
SELECT reset, to_timestamp(reset::bigint) AS window_ends, min(call_no) AS first_call, max(call_no) AS last_call, count(*) AS calls,
       min(server_used - ours) AS min_diff, max(server_used - ours) AS max_diff,
       (SELECT to_timestamp(c2.reset::bigint) FROM c c2 WHERE c2.call_no = min(w.call_no) - 1) AS previous_window_ends
FROM w GROUP BY reset HAVING bool_or(server_used <> ours) ORDER BY 3

-- r12. PROVISIONAL. NOT_SEARCHED items: item sent, total, identifierResolution (why not searched)
SELECT f.call_no, f.idx, f.seq, f.id_type, f.value, f.products, f.total,
       r -> 'identifierResolution' AS identifier_resolution
FROM f2_item f JOIN f2_call c USING (call_no)
CROSS JOIN LATERAL jsonb_array_elements(c.body -> 'results') r
WHERE f.status = 'NOT_SEARCHED' AND (r ->> 'index')::int = f.idx

-- r13. PROVISIONAL. Count of identifier-less current constraints stated in searchMeans
SELECT substring(r ->> 'searchMeans' from 'reach the ([0-9]+) current constraints') AS stated_count, count(*) AS items
FROM f2_call a, jsonb_array_elements(a.body -> 'results') r GROUP BY 1 ORDER BY 1;

-- b1. PROVISIONAL. B1 UNKNOWN_IDENTIFIER CAS, 30 most frequent: products, most frequent Covalo INCI on the same products, in the replay
SELECT f.value AS cas, f.products,
       (SELECT i.value || ' (' || count(*) || ')' FROM cov_id c JOIN cov_id i ON i.product_id = c.product_id AND i.id_type = 'INCI'
         WHERE c.id_type = 'CAS' AND c.value = f.value GROUP BY i.value ORDER BY count(*) DESC, i.value LIMIT 1) AS top_covalo_inci,
       coalesce((SELECT CASE WHEN has_literal THEN 'printed' ELSE 'enriched only' END FROM rx_val r WHERE r.id_type = 'CAS' AND r.value = f.value), 'no') AS in_replay
FROM f2_item f WHERE f.id_type = 'CAS' AND f.status = 'UNKNOWN_IDENTIFIER' ORDER BY f.products DESC, f.value LIMIT 30

-- b1b. PROVISIONAL. B1 UNKNOWN_IDENTIFIER CAS found in the replay (all, printed or enriched)
SELECT count(*) AS unknown_cas, count(*) FILTER (WHERE r.value IS NOT NULL) AS in_replay,
       count(*) FILTER (WHERE r.has_literal) AS printed, string_agg(f.value, ', ' ORDER BY f.products DESC) FILTER (WHERE r.value IS NOT NULL) AS values_in_replay
FROM f2_item f LEFT JOIN rx_val r ON r.id_type = 'CAS' AND r.value = f.value
WHERE f.id_type = 'CAS' AND f.status = 'UNKNOWN_IDENTIFIER'

-- b2. PROVISIONAL. B2 UNKNOWN_IDENTIFIER INCI, 30 most frequent: products, most frequent Covalo CAS on the same products and its lookup status
SELECT f.value AS inci, f.products, t.cas || ' (' || t.n || ')' AS top_covalo_cas,
       (SELECT g.status FROM f2_item g WHERE g.id_type = 'CAS' AND g.value = t.cas) AS cas_status
FROM f2_item f
LEFT JOIN LATERAL (SELECT c.value AS cas, count(*) AS n FROM cov_id i JOIN cov_id c ON c.product_id = i.product_id AND c.id_type = 'CAS'
                   WHERE i.id_type = 'INCI' AND i.value = f.value GROUP BY c.value ORDER BY count(*) DESC, c.value LIMIT 1) t ON true
WHERE f.id_type = 'INCI' AND f.status = 'UNKNOWN_IDENTIFIER' ORDER BY f.products DESC, f.value LIMIT 30

-- b3. PROVISIONAL. B3 KNOWN_WITHOUT_DATA CAS, 15 most frequent: products, most frequent Covalo INCI, in the replay
SELECT f.value AS cas, f.products,
       (SELECT i.value || ' (' || count(*) || ')' FROM cov_id c JOIN cov_id i ON i.product_id = c.product_id AND i.id_type = 'INCI'
         WHERE c.id_type = 'CAS' AND c.value = f.value GROUP BY i.value ORDER BY count(*) DESC, i.value LIMIT 1) AS top_covalo_inci,
       coalesce((SELECT CASE WHEN has_literal THEN 'printed' ELSE 'enriched only' END FROM rx_val r WHERE r.id_type = 'CAS' AND r.value = f.value), 'no') AS in_replay
FROM f2_item f WHERE f.id_type = 'CAS' AND f.status = 'KNOWN_WITHOUT_DATA' ORDER BY f.products DESC, f.value LIMIT 15

-- b4. PROVISIONAL. B4 replay-only products by class: groups (product, entry, value), distinct (entry, value), products (a product can sit in several classes), products by first class in precedence order
SELECT b4_class, count(*) AS groups_, count(DISTINCT (logical_entry_id, id_type, value)) AS entry_value_pairs,
       count(DISTINCT product_id) AS products,
       (SELECT count(*) FROM (SELECT DISTINCT ON (product_id) product_id, b4_class AS c FROM f2_b4 ORDER BY product_id, prec, b4_class) x
         WHERE x.c = b.b4_class) AS products_first_class
FROM f2_b4 b GROUP BY 1 ORDER BY 1

-- b4r. PROVISIONAL. B4 groups per class and F1 match route (route = own printed field, else linked substance printedByText, else enriched)
SELECT b4_class, f1_route, count(*) AS groups_, count(DISTINCT product_id) AS products,
       count(*) FILTER (WHERE own_field) AS also_own_field, count(*) FILTER (WHERE linked_printed) AS also_linked_printed,
       count(*) FILTER (WHERE enriched) AS also_enriched
FROM f2_b4 GROUP BY 1, 2 ORDER BY 1, 2

-- b4m. PROVISIONAL. B4 groups meeting more than one class definition (GROUP, guard, exemption/inventory), with the combinations
SELECT concat_ws(' + ', CASE WHEN c_setaside THEN 'guard' END, CASE WHEN c_group THEN 'GROUP' END,
                 CASE WHEN c_exempt THEN 'exemption/inventory' END) AS definitions_met,
       count(*) AS groups_, count(DISTINCT product_id) AS products
FROM f2_b4 WHERE (c_setaside::int + c_group::int + c_exempt::int) > 1 GROUP BY 1 ORDER BY 2 DESC

-- b4e. PROVISIONAL. B4 up to 10 examples per class (distinct entry and value, most products first)
SELECT b4_class, logical_entry_id, annex_ref, entry_ref, annex_type, entry_scope, scope_class, id_type, value, f1_route,
       left(entry_own_field, 160) AS entry_own_field, status, products
FROM (SELECT b4_class, logical_entry_id, annex_ref, entry_ref, annex_type, entry_scope, scope_class, id_type, value, f1_route,
             entry_own_field, status, count(DISTINCT product_id) AS products,
             row_number() OVER (PARTITION BY b4_class ORDER BY count(DISTINCT product_id) DESC, value, logical_entry_id) AS rn
      FROM f2_b4 GROUP BY 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12) x
WHERE rn <= 10 ORDER BY b4_class, products DESC, value

-- b4c. PROVISIONAL. B4 class 2 examples: set-aside caveat notes as served, with the numbers taken from them
SELECT DISTINCT b.b4_class, b.id_type, b.value, b.logical_entry_id, b.entry_ref, s.cas_in_note::text AS cas_in_note,
       s.ec_in_note::text AS ec_in_note, s.note AS caveat_as_served
FROM f2_b4 b JOIN f2_setaside s ON s.id_type = b.id_type AND s.value = b.value
WHERE b.b4_class LIKE '2%' ORDER BY 1, 2, 3, 4

-- b5. PROVISIONAL. B5 lookup-only products by route (a product can have several routes; first route by order)
SELECT route, count(DISTINCT product_id) AS products, count(DISTINCT logical_entry_id) AS entries,
       (SELECT count(*) FROM (SELECT product_id, min(route) AS r FROM f2_b5 GROUP BY 1) x WHERE x.r = b.route) AS products_first_route
FROM f2_b5 b GROUP BY 1 ORDER BY 1

-- b5b. PROVISIONAL. B5 the 10 most frequent entries (by lookup-only products), with route and the values that reached them
SELECT logical_entry_id, annex_ref, entry_ref, annex_type, string_agg(DISTINCT route, ', ') AS routes,
       string_agg(DISTINCT matched_by, ', ') AS matched_by, count(DISTINCT product_id) AS products,
       left(string_agg(DISTINCT id_type || '=' || value, ' | '), 200) AS values_
FROM f2_b5 GROUP BY 1, 2, 3, 4 ORDER BY products DESC, 1 LIMIT 10

-- b5c. PROVISIONAL. B5 lookup-only products: matched value types and whether the returned entry is in the replay
SELECT id_type, route, count(DISTINCT product_id) AS products,
       count(DISTINCT logical_entry_id) FILTER (WHERE logical_entry_id IN (SELECT logical_entry_id FROM f2_replay_id)) AS entries_in_replay,
       count(DISTINCT logical_entry_id) AS entries
FROM f2_b5 GROUP BY 1, 2 ORDER BY 1, 2

-- b6. PROVISIONAL. B6 replay 20261019T143522Z_eu: versions and entries with no CAS, EC or INCI printed (identifiers cas, ec, inci, casList, ecList, inciList)
WITH v AS (
    SELECT logical_entry_id, known_since, change_kind,
           coalesce(nullif(btrim(payload -> 'identifiers' ->> 'cas'), ''), nullif(btrim(payload -> 'identifiers' ->> 'ec'), ''),
                    nullif(btrim(payload -> 'identifiers' ->> 'inci'), '')) IS NULL
           AND coalesce(jsonb_array_length(CASE WHEN jsonb_typeof(payload -> 'identifiers' -> 'casList') = 'array' THEN payload -> 'identifiers' -> 'casList' END), 0) = 0
           AND coalesce(jsonb_array_length(CASE WHEN jsonb_typeof(payload -> 'identifiers' -> 'ecList') = 'array' THEN payload -> 'identifiers' -> 'ecList' END), 0) = 0
           AND coalesce(jsonb_array_length(CASE WHEN jsonb_typeof(payload -> 'identifiers' -> 'inciList') = 'array' THEN payload -> 'identifiers' -> 'inciList' END), 0) = 0 AS no_id,
           logical_entry_id IN (SELECT logical_entry_id FROM relayx_raw.entry_version WHERE run_id = '20261019T143522Z_eu' AND change_kind = 'RETRACTED') AS retracted_entry,
           row_number() OVER (PARTITION BY logical_entry_id ORDER BY known_since DESC, page_no DESC, row_no DESC) AS rn
    FROM relayx_raw.entry_version WHERE run_id = '20261019T143522Z_eu')
SELECT count(*) FILTER (WHERE no_id) AS versions_no_id_all,
       count(*) FILTER (WHERE no_id AND NOT retracted_entry) AS versions_no_id_not_retracted,
       count(DISTINCT logical_entry_id) FILTER (WHERE no_id AND NOT retracted_entry) AS entries_any_version_no_id,
       count(*) FILTER (WHERE no_id AND NOT retracted_entry AND rn = 1) AS entries_latest_version_no_id,
       count(*) FILTER (WHERE NOT retracted_entry) AS versions_not_retracted,
       count(DISTINCT logical_entry_id) FILTER (WHERE NOT retracted_entry) AS entries_not_retracted,
       2292 AS stated_by_relayx,
       2292 - count(*) FILTER (WHERE no_id AND NOT retracted_entry) AS diff_vs_versions,
       2292 - count(*) FILTER (WHERE no_id AND NOT retracted_entry AND rn = 1) AS diff_vs_entries
FROM v

-- b6b. PROVISIONAL. B6 no-identifier versions (not retracted) by annexRef
SELECT e.payload ->> 'annexRef' AS annex_ref, count(*) AS versions, count(DISTINCT e.logical_entry_id) AS entries
FROM relayx_raw.entry_version e
WHERE e.run_id = '20261019T143522Z_eu'
  AND e.logical_entry_id NOT IN (SELECT logical_entry_id FROM relayx_raw.entry_version WHERE run_id = '20261019T143522Z_eu' AND change_kind = 'RETRACTED')
  AND coalesce(nullif(btrim(e.payload -> 'identifiers' ->> 'cas'), ''), nullif(btrim(e.payload -> 'identifiers' ->> 'ec'), ''),
               nullif(btrim(e.payload -> 'identifiers' ->> 'inci'), '')) IS NULL
  AND coalesce(jsonb_array_length(CASE WHEN jsonb_typeof(e.payload -> 'identifiers' -> 'casList') = 'array' THEN e.payload -> 'identifiers' -> 'casList' END), 0) = 0
  AND coalesce(jsonb_array_length(CASE WHEN jsonb_typeof(e.payload -> 'identifiers' -> 'ecList') = 'array' THEN e.payload -> 'identifiers' -> 'ecList' END), 0) = 0
  AND coalesce(jsonb_array_length(CASE WHEN jsonb_typeof(e.payload -> 'identifiers' -> 'inciList') = 'array' THEN e.payload -> 'identifiers' -> 'inciList' END), 0) = 0
GROUP BY 1 ORDER BY 2 DESC
