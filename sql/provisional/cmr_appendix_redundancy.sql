-- PROVISIONAL. Redundancy of the REACH CMR appendix entries (EU_REACH: CMR category 1A,
-- CMR category 1B, Mutagens, Toxic category 1, Toxic category 2) against current Cosmetics
-- Article 15(1)/15(2) entries and CLP Annex VI Table 3 entries. 2026-10-20.
-- Read-only on relayx_raw; TEMP objects only; nothing persists.
-- Run: python -m relayx.provisional_report sql/provisional/cmr_appendix_redundancy.sql
--
-- Rules:
--   Current entries: entries of replay 20261019T143522Z_eu without a RETRACTED row.
--   Substance key: each CAS printed by the entry (`identifiers.cas` tokens and `casList`);
--     for an entry without any CAS, each printed EC (`identifiers.ec` tokens and `ecList`).
--     Printed identifiers only (no linkedSubstances, no enrichment).
--   A CMR substance is "covered" by Article 15 or CLP when the same key (CAS for CAS, EC for
--     EC) is printed by a current entry of that group (CAS: any printed CAS; EC: any printed EC).
--   Classes, exclusive: Article 15 (15(1) or 15(2)) > CLP Annex VI Table 3 only > neither.

CREATE FUNCTION pg_temp.prep(t text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT regexp_replace(translate(t, E'–—‐‑−', '-----'), '\s*-\s*', '-', 'g')
$$;

CREATE FUNCTION pg_temp.tokens(t text, kind text) RETURNS SETOF text LANGUAGE sql IMMUTABLE AS $$
    SELECT m[1] FROM regexp_matches(pg_temp.prep(t),
        CASE kind WHEN 'CAS' THEN '(?<!\d)(\d{2,7}-\d{2}-\d)(?!\d)'
                  ELSE '(?<!\d)(\d{3}-\d{3}-\d)(?!\d)' END, 'g') AS m
$$;

CREATE TEMP TABLE cur AS
SELECT DISTINCT ON (logical_entry_id) logical_entry_id, payload ->> 'annexRef' AS annex_ref,
       payload -> 'text' ->> 'officialRef' AS text_ref, payload -> 'identifiers' AS ids
FROM relayx_raw.entry_version
WHERE run_id = '20261019T143522Z_eu'
  AND logical_entry_id NOT IN (SELECT logical_entry_id FROM relayx_raw.entry_version
                               WHERE run_id = '20261019T143522Z_eu' AND change_kind = 'RETRACTED')
ORDER BY logical_entry_id, page_no DESC, row_no DESC;

-- Printed CAS and EC per current entry.
CREATE TEMP TABLE printed AS
SELECT c.logical_entry_id, 'CAS' AS id_type, t.value FROM cur c, pg_temp.tokens(c.ids ->> 'cas', 'CAS') AS t(value)
UNION
SELECT c.logical_entry_id, 'CAS', v #>> '{}' FROM cur c,
    jsonb_array_elements(CASE WHEN jsonb_typeof(c.ids -> 'casList') = 'array' THEN c.ids -> 'casList' ELSE '[]' END) v
UNION
SELECT c.logical_entry_id, 'EC', t.value FROM cur c, pg_temp.tokens(c.ids ->> 'ec', 'EC') AS t(value)
UNION
SELECT c.logical_entry_id, 'EC', v #>> '{}' FROM cur c,
    jsonb_array_elements(CASE WHEN jsonb_typeof(c.ids -> 'ecList') = 'array' THEN c.ids -> 'ecList' ELSE '[]' END) v;
CREATE INDEX ON printed (id_type, value);

CREATE TEMP TABLE grp AS
SELECT logical_entry_id, annex_ref,
       CASE WHEN text_ref = 'EU_REACH' AND annex_ref IN ('CMR category 1A', 'CMR category 1B', 'Mutagens',
                                                         'Toxic category 1', 'Toxic category 2') THEN 'CMR'
            WHEN annex_ref IN ('Article 15(1)', 'Article 15(2)') THEN 'ART15'
            WHEN annex_ref = 'Annex VI Table 3' THEN 'CLP'
       END AS g
FROM cur;

-- CMR substances: CAS keys, or EC keys for CMR entries printing no CAS.
CREATE TEMP TABLE cmr_sub AS
SELECT p.id_type, p.value, string_agg(DISTINCT g.annex_ref, ', ') AS appendices,
       min(c.ids ->> 'name') AS name, min(c.ids ->> 'cas') AS printed_cas, min(c.ids ->> 'ec') AS printed_ec,
       count(DISTINCT p.logical_entry_id) AS cmr_entries
FROM grp g JOIN printed p USING (logical_entry_id) JOIN cur c USING (logical_entry_id)
WHERE g.g = 'CMR'
  AND (p.id_type = 'CAS' OR NOT EXISTS (SELECT 1 FROM printed x WHERE x.logical_entry_id = g.logical_entry_id AND x.id_type = 'CAS'))
GROUP BY p.id_type, p.value;

CREATE TEMP TABLE cmr_cls AS
SELECT s.*,
       CASE WHEN EXISTS (SELECT 1 FROM printed p JOIN grp g USING (logical_entry_id)
                         WHERE g.g = 'ART15' AND p.id_type = s.id_type AND p.value = s.value) THEN '1 Article 15'
            WHEN EXISTS (SELECT 1 FROM printed p JOIN grp g USING (logical_entry_id)
                         WHERE g.g = 'CLP' AND p.id_type = s.id_type AND p.value = s.value) THEN '2 CLP Annex VI Table 3 only'
            ELSE '3 neither' END AS cls
FROM cmr_sub s;

-- REPORT

-- r1. PROVISIONAL. CMR appendix entries and substances
SELECT (SELECT count(*) FROM grp WHERE g = 'CMR') AS cmr_entries,
       (SELECT count(*) FROM grp g WHERE g.g = 'CMR'
          AND NOT EXISTS (SELECT 1 FROM printed p WHERE p.logical_entry_id = g.logical_entry_id)) AS cmr_entries_without_cas_or_ec,
       (SELECT count(*) FROM cmr_sub) AS distinct_substances,
       (SELECT count(*) FROM cmr_sub WHERE id_type = 'CAS') AS by_cas,
       (SELECT count(*) FROM cmr_sub WHERE id_type = 'EC') AS by_ec_only;

-- r2. PROVISIONAL. Distinct CMR substances by coverage class
SELECT cls, count(*) AS substances, count(*) FILTER (WHERE id_type = 'CAS') AS by_cas,
       count(*) FILTER (WHERE id_type = 'EC') AS by_ec
FROM cmr_cls GROUP BY ROLLUP (cls) ORDER BY 1 NULLS LAST;

-- r3. PROVISIONAL. Coverage class by appendix (a substance listed in several appendices counts in each)
SELECT a.appendix, c.cls, count(*) AS substances
FROM cmr_cls c, regexp_split_to_table(c.appendices, ', ') AS a(appendix)
GROUP BY 1, 2 ORDER BY 1, 2;

-- r4. PROVISIONAL. Up to 20 substances covered by neither: CAS, EC, name, appendix
SELECT id_type AS key_type, value AS key, printed_cas AS cas, printed_ec AS ec, left(name, 90) AS name, appendices
FROM cmr_cls WHERE cls = '3 neither' ORDER BY appendices, value LIMIT 20
