-- PROVISIONAL. Relay X identifier catalogue as an INCI to CAS/EC bridge, 2026-10-21.
-- Read-only; TEMP objects only. Needs the TEMP objects of f1_matching_assessment.sql:
--   python -m relayx.provisional_report sql/provisional/catalogue_bridge.sql --setup sql/provisional/f1_matching_assessment.sql
--
-- Rules:
--   Population: the 1,791 distinct Covalo INCI found in the catalogue (F1: cov_val, id_type INCI,
--     in_catalogue), normalised as in F1.
--   Catalogue rows of an INCI: rows of kevin.relayx_eu_identifiers_v2 whose inci_name or
--     inci_name_us, split on '|' and normalised as in F1, equals the Covalo INCI.
--   Bridge identifiers: CAS and EC tokens of those rows (F1 token rules).
--   Current replay entries and their identifiers: F1 rx_id (literal and enriched), entries
--     without a RETRACTED row.
--   By name = the INCI itself is an identifier of a current entry (F1 in_replay).
--   Classes, exclusive: by name > only through catalogue CAS or EC > none.
--   Annex groups as in results/2026-10-20-atlas-datapack.md section 2.

CREATE TEMP TABLE cat_row AS
SELECT id AS row_id, cas_number, ec_number, regulatory_layer FROM kevin.relayx_eu_identifiers_v2;

CREATE TEMP TABLE cat_row_inci AS
SELECT DISTINCT c.row_id, pg_temp.norm_inci(s) AS inci
FROM cat_row c JOIN kevin.relayx_eu_identifiers_v2 k ON k.id = c.row_id
CROSS JOIN LATERAL regexp_split_to_table(coalesce(k.inci_name, '') || '|' || coalesce(k.inci_name_us, ''), '\s*\|\s*') AS s
WHERE pg_temp.norm_inci(s) IS NOT NULL;
CREATE INDEX ON cat_row_inci (inci);

CREATE TEMP TABLE cat_row_id AS
SELECT c.row_id, 'CAS' AS id_type, t.value FROM cat_row c, pg_temp.tokens(c.cas_number, 'CAS') AS t(value)
UNION
SELECT c.row_id, 'EC', t.value FROM cat_row c, pg_temp.tokens(c.ec_number, 'EC') AS t(value);
CREATE INDEX ON cat_row_id (row_id);

CREATE TEMP TABLE pop AS
SELECT value AS inci, in_replay AS by_name, products FROM cov_val WHERE id_type = 'INCI' AND in_catalogue;

-- Bridge identifiers per Covalo INCI, and the current entries they reach.
CREATE TEMP TABLE bridge_id AS
SELECT DISTINCT p.inci, i.id_type, i.value
FROM pop p JOIN cat_row_inci r ON r.inci = p.inci JOIN cat_row_id i ON i.row_id = r.row_id;

CREATE TEMP TABLE bridge_hit AS
SELECT DISTINCT b.inci, b.id_type, b.value, x.logical_entry_id, x.provenance
FROM bridge_id b JOIN rx_id x ON x.id_type = b.id_type AND x.value = b.value;

CREATE TEMP TABLE entry_grp AS
SELECT DISTINCT ON (logical_entry_id) logical_entry_id,
       CASE WHEN payload -> 'text' ->> 'officialRef' = '32026R1383' THEN 'CITES 32026R1383, 11 annexes'
            WHEN payload -> 'text' ->> 'officialRef' = '32025R0006' THEN 'CITES 32025R0006, Annex (1) and (2)'
            ELSE payload ->> 'annexRef' END AS annex_group
FROM relayx_raw.entry_version WHERE run_id = '20261019T143522Z_eu'
ORDER BY logical_entry_id, page_no DESC, row_no DESC;

CREATE TEMP TABLE cls AS
SELECT p.inci, p.products,
       CASE WHEN p.by_name THEN '1 by name'
            WHEN EXISTS (SELECT 1 FROM bridge_hit h WHERE h.inci = p.inci) THEN '2 only through catalogue CAS or EC'
            ELSE '3 none' END AS cls,
       EXISTS (SELECT 1 FROM bridge_id b WHERE b.inci = p.inci) AS has_bridge_id,
       EXISTS (SELECT 1 FROM bridge_hit h WHERE h.inci = p.inci) AS bridge_reaches
FROM pop p;

-- REPORT

-- b1. PROVISIONAL. The 1,791 Covalo INCI found in the catalogue, by class
SELECT cls, count(*) AS distinct_inci, sum(products) AS product_links,
       count(*) FILTER (WHERE has_bridge_id) AS with_catalogue_cas_or_ec,
       count(*) FILTER (WHERE bridge_reaches) AS bridge_reaches_an_entry
FROM cls GROUP BY ROLLUP (cls) ORDER BY 1 NULLS LAST;

-- b2. PROVISIONAL. Class 2: bridge identifier types used and provenance of the reached entry identifiers
SELECT count(DISTINCT inci) AS inci,
       count(DISTINCT inci) FILTER (WHERE id_type = 'CAS') AS via_cas,
       count(DISTINCT inci) FILTER (WHERE id_type = 'EC') AS via_ec,
       count(DISTINCT inci) FILTER (WHERE provenance = 'literal') AS via_printed_identifier
FROM bridge_hit WHERE inci IN (SELECT inci FROM cls WHERE cls LIKE '2%');

-- b2b. PROVISIONAL. Class 2 per INCI: bridging catalogue rows and how many INCI names those rows carry
--      (a row carrying many INCI hands all its CAS and EC to each of them: risk of false bridges)
SELECT h.inci, count(DISTINCT r.row_id) AS bridging_rows,
       max((SELECT count(*) FROM cat_row_inci r2 WHERE r2.row_id = r.row_id)) AS max_inci_per_row,
       min((SELECT count(*) FROM cat_row_inci r2 WHERE r2.row_id = r.row_id)) AS min_inci_per_row,
       count(DISTINCT h.logical_entry_id) AS entries_reached,
       string_agg(DISTINCT h.id_type || ' ' || h.value, ', ') AS bridge_values
FROM bridge_hit h
JOIN cat_row_inci r ON r.inci = h.inci
JOIN cat_row_id i ON i.row_id = r.row_id AND i.id_type = h.id_type AND i.value = h.value
WHERE h.inci IN (SELECT inci FROM cls WHERE cls LIKE '2%')
GROUP BY h.inci ORDER BY 3, 1;

-- b2c. PROVISIONAL. Catalogue rows carrying several INCI names (all 14,207 rows and the rows of the 1,791)
SELECT scope, count(*) AS rows_, count(*) FILTER (WHERE n_inci > 1) AS multi_inci_rows,
       max(n_inci) AS max_inci_per_row
FROM (SELECT r.row_id, count(*) AS n_inci, bool_or(r.inci IN (SELECT inci FROM pop)) AS in_pop
      FROM cat_row_inci r GROUP BY 1) x
CROSS JOIN LATERAL (VALUES ('all rows with INCI', true), ('rows of the 1,791', x.in_pop)) AS s(scope, keep)
WHERE s.keep GROUP BY 1 ORDER BY 1;

-- b3. PROVISIONAL. Class 2 by annex or list of the reached entries (an INCI can reach several)
SELECT g.annex_group, count(DISTINCT h.inci) AS distinct_inci,
       count(DISTINCT h.logical_entry_id) AS entries
FROM bridge_hit h JOIN entry_grp g USING (logical_entry_id)
WHERE h.inci IN (SELECT inci FROM cls WHERE cls LIKE '2%')
GROUP BY 1 ORDER BY 2 DESC;

-- b4. PROVISIONAL. Class 2 fan-out: current entries reached per INCI
SELECT CASE WHEN n = 1 THEN '1' WHEN n <= 3 THEN '2-3' WHEN n <= 10 THEN '4-10' ELSE '>10' END AS entries_reached,
       count(*) AS distinct_inci
FROM (SELECT inci, count(DISTINCT logical_entry_id) AS n FROM bridge_hit
      WHERE inci IN (SELECT inci FROM cls WHERE cls LIKE '2%') GROUP BY 1) x
GROUP BY 1 ORDER BY 1;

-- b5. PROVISIONAL. Class 3 by catalogue regulatory layer (layer values as served; an INCI with rows in several layers counts in each)
SELECT coalesce(nullif(btrim(c.regulatory_layer), ''), '(blank)') AS regulatory_layer,
       count(DISTINCT p.inci) AS distinct_inci,
       count(DISTINCT p.inci) FILTER (WHERE p.has_bridge_id) AS with_catalogue_cas_or_ec
FROM cls p JOIN cat_row_inci r ON r.inci = p.inci JOIN cat_row c ON c.row_id = r.row_id
WHERE p.cls LIKE '3%' GROUP BY 1 ORDER BY 2 DESC;

-- b6. PROVISIONAL. Class 3 by number of distinct regulatory layers per INCI
SELECT n_layers, count(*) AS distinct_inci FROM (
    SELECT p.inci, count(DISTINCT c.regulatory_layer) AS n_layers
    FROM cls p JOIN cat_row_inci r ON r.inci = p.inci JOIN cat_row c ON c.row_id = r.row_id
    WHERE p.cls LIKE '3%' GROUP BY 1) x GROUP BY 1 ORDER BY 1;

-- b7. PROVISIONAL. Share of all 13,912 distinct Covalo INCI reaching a current entry by name or via the catalogue bridge
SELECT count(*) AS covalo_distinct_inci,
       count(*) FILTER (WHERE v.in_replay) AS by_name,
       count(*) FILTER (WHERE NOT v.in_replay AND c.cls LIKE '2%') AS via_catalogue_bridge_only,
       count(*) FILTER (WHERE v.in_replay OR c.cls LIKE '2%') AS by_name_or_bridge,
       round(100.0 * count(*) FILTER (WHERE v.in_replay) / count(*), 1) AS pct_by_name,
       round(100.0 * count(*) FILTER (WHERE v.in_replay OR c.cls LIKE '2%') / count(*), 1) AS pct_by_name_or_bridge
FROM cov_val v LEFT JOIN cls c ON c.inci = v.value
WHERE v.id_type = 'INCI';

-- b8. PROVISIONAL. Product level: products with INCI where at least one INCI reaches a current entry by name or via the bridge
WITH p AS (
    SELECT i.product_id, bool_or(v.in_replay) AS by_name, bool_or(v.in_replay OR c.cls LIKE '2%') AS by_name_or_bridge
    FROM cov_id i JOIN cov_val v USING (id_type, value) LEFT JOIN cls c ON c.inci = v.value
    WHERE i.id_type = 'INCI' GROUP BY 1)
SELECT count(*) AS products_with_inci,
       count(*) FILTER (WHERE by_name) AS by_name,
       count(*) FILTER (WHERE by_name_or_bridge AND NOT by_name) AS added_by_bridge,
       count(*) FILTER (WHERE by_name_or_bridge) AS by_name_or_bridge,
       round(100.0 * count(*) FILTER (WHERE by_name) / count(*), 1) AS pct_by_name,
       round(100.0 * count(*) FILTER (WHERE by_name_or_bridge) / count(*), 1) AS pct_by_name_or_bridge
FROM p;

-- b9. PROVISIONAL. Products added by the bridge that reach an entry through no other Covalo identifier (CAS, EC, name) either
WITH p AS (
    SELECT i.product_id, bool_or(v.in_replay) AS by_name, bool_or(c.cls LIKE '2%') AS bridge
    FROM cov_id i JOIN cov_val v USING (id_type, value) LEFT JOIN cls c ON c.inci = v.value
    WHERE i.id_type = 'INCI' GROUP BY 1),
     other AS (SELECT DISTINCT i.product_id FROM cov_id i JOIN cov_val v USING (id_type, value)
               WHERE i.id_type <> 'INCI' AND v.in_replay)
SELECT count(*) AS added_by_bridge,
       count(*) FILTER (WHERE product_id NOT IN (SELECT product_id FROM other)) AS not_reached_by_own_cas_ec_name
FROM p WHERE bridge AND NOT by_name;

-- b9b. PROVISIONAL. Products added by the bridge, by the class-2 INCI they carry (a product can carry several)
WITH added AS (
    SELECT i.product_id FROM cov_id i JOIN cov_val v USING (id_type, value) LEFT JOIN cls c ON c.inci = v.value
    WHERE i.id_type = 'INCI' GROUP BY 1 HAVING bool_or(c.cls LIKE '2%') AND NOT bool_or(v.in_replay))
SELECT c.inci, count(DISTINCT a.product_id) AS products_added
FROM added a JOIN cov_id i ON i.product_id = a.product_id AND i.id_type = 'INCI'
JOIN cls c ON c.inci = i.value AND c.cls LIKE '2%'
GROUP BY 1 ORDER BY 2 DESC;

-- b10. PROVISIONAL. Ten examples of class 2: Covalo INCI, bridge CAS or EC, annex of a reached entry
SELECT DISTINCT ON (h.inci) h.inci, h.id_type, h.value, g.annex_group
FROM bridge_hit h JOIN entry_grp g USING (logical_entry_id)
WHERE h.inci IN (SELECT inci FROM cls WHERE cls LIKE '2%')
ORDER BY h.inci, g.annex_group LIMIT 10
