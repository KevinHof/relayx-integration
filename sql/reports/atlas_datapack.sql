-- Data pack for the "Relay X EU content atlas" (leadership and onboarding document).
-- Local only, read-only on relayx_raw; TEMP objects only, nothing persists.
-- Run: python -m relayx.provisional_report sql/reports/atlas_datapack.sql
--
-- Sources (runs loaded 2026-10-19):
--   /changes replay  20261019T143522Z_eu              (relayx_raw.entry_version)
--   /texts           20261019T174201Z_texts_eu        (relayx_raw.api_response)
--   /coverage        20261019T174201Z_coverage_eu
--   /allergens       20261019T174201Z_allergens_eu
--   pilot            20261019T174653Z_substance_pilot_eu (screening and opinions, 100 substances)
-- Current entry: entries without a RETRACTED row; attributes from the entry's last row in
-- feed order. Provisional: the current-version rule is open (Q10) and affects at most the
-- 35 entries named there; annex, type and scope do not differ between versions in practice.
-- "No identifier" = none of CAS, EC, INCI, CLP index, Colour Index (as in VE-11).

CREATE TEMP TABLE cur_entry AS
SELECT DISTINCT ON (ev.logical_entry_id)
       ev.logical_entry_id,
       ev.payload ->> 'annexRef' AS annex_ref,
       ev.payload ->> 'annexType' AS annex_type,
       ev.payload ->> 'nature' AS nature,
       ev.payload ->> 'entryScope' AS entry_scope,
       ev.payload ->> 'entryRef' AS entry_ref,
       ev.payload -> 'text' ->> 'officialRef' AS text_ref,
       (ev.payload -> 'identifiers' ->> 'cas' IS NOT NULL OR jsonb_typeof(ev.payload -> 'identifiers' -> 'casList') = 'array') AS has_cas,
       (ev.payload -> 'identifiers' ->> 'ec' IS NOT NULL OR jsonb_typeof(ev.payload -> 'identifiers' -> 'ecList') = 'array') AS has_ec,
       (ev.payload -> 'identifiers' ->> 'inci' IS NOT NULL OR jsonb_typeof(ev.payload -> 'identifiers' -> 'inciList') = 'array') AS has_inci,
       ev.payload -> 'identifiers' ->> 'clpIndex' IS NOT NULL AS has_clp,
       ev.payload -> 'identifiers' ->> 'colourIndex' IS NOT NULL AS has_ci
FROM relayx_raw.entry_version ev
WHERE ev.run_id = '20261019T143522Z_eu'
  AND ev.logical_entry_id NOT IN (SELECT logical_entry_id FROM relayx_raw.entry_version
                                  WHERE run_id = '20261019T143522Z_eu' AND change_kind = 'RETRACTED')
ORDER BY ev.logical_entry_id, ev.page_no DESC, ev.row_no DESC;
ALTER TABLE cur_entry ADD COLUMN no_id boolean;
UPDATE cur_entry SET no_id = NOT (has_cas OR has_ec OR has_inci OR has_clp OR has_ci);

-- Every version row, for the per-text comparison with constraintCount (which counts versions).
CREATE TEMP TABLE all_rows AS
SELECT ev.payload -> 'text' ->> 'officialRef' AS text_ref, count(*) AS rows_all_versions
FROM relayx_raw.entry_version ev WHERE ev.run_id = '20261019T143522Z_eu' GROUP BY 1;

CREATE TEMP TABLE txt AS
SELECT t ->> 'officialRef' AS official_ref, t ->> 'celexNumber' AS celex, t ->> 'title' AS title,
       t ->> 'status' AS status, t ->> 'documentType' AS document_type,
       (t ->> 'constraintCount')::int AS constraint_count, t ->> 'validFrom' AS valid_from,
       t ->> 'validUntil' AS valid_until, t ->> 'amends' AS amends, t -> 'legislator' ->> 'code' AS legislator
FROM relayx_raw.api_response r, jsonb_array_elements(r.body -> 'texts') t
WHERE r.run_id = '20261019T174201Z_texts_eu' AND r.http_status = 200;

CREATE TEMP TABLE cov AS
SELECT c ->> 'annexRef' AS annex_ref, c -> 'text' ->> 'officialRef' AS text_ref, c ->> 'annexType' AS annex_type,
       c ->> 'listSemantics' AS list_semantics, c ->> 'completeness' AS completeness,
       left(c ->> 'completeAsOf', 10) AS complete_as_of, c ->> 'scopeIsOpenByItsOwnText' AS scope_open,
       c ->> 'absenceMeans' AS absence_means, c ->> 'scopeOpennessMeans' AS openness_means
FROM relayx_raw.api_response r, jsonb_array_elements(r.body -> 'coverage') c
WHERE r.run_id = '20261019T174201Z_coverage_eu' AND r.http_status = 200;

CREATE TEMP TABLE alg AS
SELECT a, r.body AS envelope
FROM relayx_raw.api_response r, jsonb_array_elements(r.body -> 'allergens') a
WHERE r.run_id = '20261019T174201Z_allergens_eu' AND r.http_status = 200;

-- REPORT

-- 1a. Per legal text: id, title, status, constraintCount, current entries and annexes (from entries and from /coverage)
SELECT t.official_ref, t.celex, t.document_type, coalesce(t.status, '(null)') AS status, t.constraint_count,
       coalesce(a.rows_all_versions, 0) AS replay_rows,
       (SELECT count(*) FROM cur_entry e WHERE e.text_ref = t.official_ref) AS current_entries,
       (SELECT string_agg(x.annex_ref || ' (' || x.n || ')', '; ' ORDER BY x.annex_ref)
          FROM (SELECT annex_ref, count(*) AS n FROM cur_entry e WHERE e.text_ref = t.official_ref GROUP BY 1) x) AS annexes_in_entries,
       (SELECT string_agg(c.annex_ref, '; ' ORDER BY c.annex_ref) FROM cov c WHERE c.text_ref = t.official_ref) AS coverage_scopes,
       left(t.title, 110) AS title
FROM txt t LEFT JOIN all_rows a ON a.text_ref = t.official_ref
ORDER BY t.constraint_count DESC, t.official_ref;

-- 1b. Texts: totals and consistency checks
SELECT count(*) AS texts, sum(constraint_count) AS sum_constraint_count,
       count(*) FILTER (WHERE status IS NULL) AS status_null,
       count(*) FILTER (WHERE constraint_count = 0) AS zero_constraints,
       count(*) FILTER (WHERE constraint_count <> coalesce((SELECT rows_all_versions FROM all_rows a WHERE a.text_ref = txt.official_ref), 0)) AS count_differs_from_replay,
       (SELECT count(*) FROM all_rows a WHERE a.text_ref NOT IN (SELECT official_ref FROM txt)) AS entry_text_refs_not_in_texts
FROM txt;

-- 1c. Texts by status and document type
SELECT coalesce(status, '(null)') AS status, document_type, count(*) AS texts, sum(constraint_count) AS constraints
FROM txt GROUP BY 1, 2 ORDER BY 3 DESC;

-- 1d. Texts without entries (constraintCount 0): amended act as served in `amends`, else from the title
SELECT coalesce(amends, '(null)') AS amends,
       CASE WHEN title ~ '1223/2009' THEN 'title: 1223/2009 (Cosmetics)'
            WHEN title ~ '1272/2008' THEN 'title: 1272/2008 (CLP)'
            WHEN title ~* '1907/2006|REACH' THEN 'title: 1907/2006 (REACH)'
            WHEN title ~ '2019/1021' THEN 'title: 2019/1021 (POPs)'
            WHEN title ~ '338/97' THEN 'title: 338/97 (CITES)'
            ELSE 'title names no base act' END AS from_title,
       count(*) AS texts, string_agg(official_ref, ', ' ORDER BY official_ref) AS official_refs
FROM txt WHERE constraint_count = 0 GROUP BY 1, 2 ORDER BY 3 DESC;

-- 2a. Raw category values on current entries: annexType, nature, entryScope
SELECT 'annexType' AS field, annex_type AS value, count(*) AS current_entries FROM cur_entry GROUP BY 2
UNION ALL SELECT 'nature', nature, count(*) FROM cur_entry GROUP BY 2
UNION ALL SELECT 'entryScope', entry_scope, count(*) FROM cur_entry GROUP BY 2
ORDER BY 1, 3 DESC;

-- 2b. annexTypeMeans as served (one per annexType)
SELECT DISTINCT ON (ev.payload ->> 'annexType') ev.payload ->> 'annexType' AS annex_type,
       left(ev.payload ->> 'annexTypeMeans', 200) AS annex_type_means
FROM relayx_raw.entry_version ev WHERE ev.run_id = '20261019T143522Z_eu'
ORDER BY ev.payload ->> 'annexType';

-- 2c. Per annex or list: current entries by type, nature, scope and identifier presence
SELECT annex_ref, string_agg(DISTINCT annex_type, ', ') AS annex_type, string_agg(DISTINCT text_ref, ', ') AS texts,
       count(*) AS current_entries,
       count(*) FILTER (WHERE nature = 'LITERAL_ENTRY') AS literal,
       count(*) FILTER (WHERE nature = 'DERIVED_BY_LAW') AS derived,
       count(*) FILTER (WHERE entry_scope = 'SINGLE') AS single,
       count(*) FILTER (WHERE entry_scope = 'GROUP') AS grp,
       count(*) FILTER (WHERE entry_scope = 'GENERIC_CLASS') AS generic_class,
       count(*) FILTER (WHERE has_cas) AS cas, count(*) FILTER (WHERE has_ec) AS ec,
       count(*) FILTER (WHERE has_inci) AS inci, count(*) FILTER (WHERE has_clp) AS clp_index,
       count(*) FILTER (WHERE has_ci) AS colour_index, count(*) FILTER (WHERE no_id) AS no_identifier
FROM cur_entry GROUP BY ROLLUP (annex_ref) ORDER BY annex_ref NULLS LAST;

-- 3a. Coverage scopes: list type, completeness, absence key, current entries in the same annex
SELECT c.annex_ref, c.text_ref, c.annex_type, c.list_semantics, c.completeness, c.complete_as_of, c.scope_open,
       split_part(c.absence_means, ' · ', 1) AS absence_key,
       (SELECT count(*) FROM cur_entry e WHERE e.annex_ref = c.annex_ref) AS entries_same_annex_ref
FROM cov c ORDER BY c.text_ref, c.annex_ref;

-- 3b. Distinct absence statements (first 260 characters) and how many scopes carry each
SELECT left(absence_means, 260) AS absence_means_start, count(*) AS scopes, string_agg(DISTINCT list_semantics, ', ') AS list_semantics
FROM cov GROUP BY 1 ORDER BY 2 DESC;

-- 3c. Annexes with entries but no coverage scope of the same annexRef
SELECT annex_ref, count(*) AS current_entries FROM cur_entry
WHERE annex_ref NOT IN (SELECT annex_ref FROM cov WHERE annex_ref IS NOT NULL) GROUP BY 1 ORDER BY 2 DESC;

-- 3d. Coverage scopes whose annexRef has no entries
SELECT annex_ref, text_ref, annex_type, list_semantics FROM cov
WHERE annex_ref NOT IN (SELECT annex_ref FROM cur_entry) ORDER BY 2, 1;

-- 4a. Allergens: counts and fields present
SELECT count(*) AS allergens,
       count(*) FILTER (WHERE a -> 'declarationThreshold' ->> 'en' IS NOT NULL OR a -> 'declarationThreshold' ->> 'original' IS NOT NULL) AS with_threshold_text,
       count(*) FILTER (WHERE a -> 'conditions' IS NOT NULL AND a -> 'conditions' <> 'null') AS with_conditions,
       count(*) FILTER (WHERE a ->> 'cas' IS NOT NULL) AS with_cas, count(*) FILTER (WHERE a ->> 'ec' IS NOT NULL) AS with_ec,
       count(DISTINCT a ->> 'entryRef') AS distinct_entry_refs,
       max(envelope ->> 'basisActs') AS basis_acts, max(envelope ->> 'basisRule') AS basis_rule,
       max(envelope ->> 'basisAnnexes') AS basis_annexes, max(envelope ->> 'scanCapped') AS scan_capped
FROM alg;

-- 4b. Allergen thresholds: how the threshold text states leave-on / rinse-off values
SELECT count(*) FILTER (WHERE t ~* 'leave-on') AS mentions_leave_on, count(*) FILTER (WHERE t ~* 'rinse-off') AS mentions_rinse_off,
       count(*) FILTER (WHERE t ~ '0,001 ?%') AS has_0_001pct, count(*) FILTER (WHERE t ~ '0,01 ?%') AS has_0_01pct
FROM (SELECT coalesce(a -> 'declarationThreshold' ->> 'en', a -> 'declarationThreshold' ->> 'original') AS t FROM alg) x
WHERE t IS NOT NULL;

-- 6a. Screening list codes observed in the pilot (100 catalogue substances)
SELECT l ->> 'list' AS list_code, max(l ->> 'name') AS name, max(l ->> 'publisher') AS publisher, count(*) AS memberships
FROM relayx_raw.api_response r,
     jsonb_array_elements(CASE WHEN jsonb_typeof(r.body -> 'listings') = 'array' THEN r.body -> 'listings' ELSE '[]' END) l
WHERE r.run_id = '20261019T174653Z_substance_pilot_eu' AND r.endpoint = '/substances/screening'
GROUP BY 1 ORDER BY 4 DESC;

-- 6b. Opinion bodies observed in the pilot
SELECT o ->> 'body' AS body, count(*) AS opinions, count(DISTINCT r.call_no) AS substances
FROM relayx_raw.api_response r,
     jsonb_array_elements(CASE WHEN jsonb_typeof(r.body -> 'opinions') = 'array' THEN r.body -> 'opinions' ELSE '[]' END) o
WHERE r.run_id = '20261019T174653Z_substance_pilot_eu' AND r.endpoint = '/substances/opinions'
GROUP BY 1;

-- 6c. Where SCCS and IFRA are mentioned in the replay (current-entry rows) and the pilot
SELECT 'replay: SCCS in conditions text' AS where_, count(*) AS n FROM relayx_raw.entry_version
    WHERE run_id = '20261019T143522Z_eu' AND payload -> 'literal' -> 'conditions' ->> 'en' ILIKE '%SCCS%'
UNION ALL SELECT 'replay: SCCS anywhere', count(*) FROM relayx_raw.entry_version WHERE run_id = '20261019T143522Z_eu' AND payload::text ILIKE '%SCCS%'
UNION ALL SELECT 'replay: IFRA anywhere', count(*) FROM relayx_raw.entry_version WHERE run_id = '20261019T143522Z_eu' AND payload::text ILIKE '%IFRA%'
UNION ALL SELECT 'pilot screening: IFRA list membership', count(*) FROM relayx_raw.api_response r,
    jsonb_array_elements(CASE WHEN jsonb_typeof(r.body -> 'listings') = 'array' THEN r.body -> 'listings' ELSE '[]' END) l
    WHERE r.run_id = '20261019T174653Z_substance_pilot_eu' AND l ->> 'list' ILIKE '%IFRA%'
UNION ALL SELECT 'pilot lookup context: SCCS opinions', count(*) FROM relayx_raw.api_response r,
    jsonb_array_elements(CASE WHEN jsonb_typeof(r.body -> 'results') = 'array' THEN r.body -> 'results' ELSE '[]' END) res,
    jsonb_array_elements(CASE WHEN jsonb_typeof(res #> '{substanceContext,scientificOpinions,items}') = 'array'
                              THEN res #> '{substanceContext,scientificOpinions,items}' ELSE '[]' END) o
    WHERE r.run_id = '20261019T174653Z_substance_pilot_eu' AND o ->> 'body' = 'SCCS'
