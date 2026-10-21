-- PROVISIONAL. F3 CosIng bridge (docs/plans/2026-10-20-f3-cosing-bridge.md).
-- Part 1: profile (Q1, sections p*). Part 2: Q2 INCI matching, Q3 bridge, Q5 referee flag
-- (sections q0 to q12). Part 2b: tier sizing and validation sample (q13 to q16). Q4 and Q6 not
-- included.
-- Read-only; TEMP objects only. Needs the TEMP objects and the CAS/EC parser of F1
-- (pg_temp.prep, tokens, cas_ok, ec_ok; one parser for Covalo and CosIng). The CosIng table is
-- a parameter, so a current export can replace the Wayback snapshot:
--   python -m relayx.provisional_report sql/provisional/f3_cosing_bridge.sql
--       --setup sql/provisional/f1_matching_assessment.sql --param cosing_table=kevin.cosing_ingredients
--
-- Rules, part 1:
--   Blank = NULL, empty or whitespace only. Placeholder = non-blank value with no digit (e.g. "-").
--   CAS / EC tokens: F1 parser (pg_temp.tokens); check digits: F1 pg_temp.cas_ok / ec_ok.
--   Residue = what is left of a CAS or EC value after removing its tokens and whitespace.
--   INCI duplicate after normalisation: lower(btrim(inci_name)).
-- Rules, part 2:
--   Covalo side: F1 objects unchanged (cov_product = active products; cov_raw = raw identifier
--     strings; cov_id = parsed values). Raw INCI strings are matched; the distinct unit is the
--     F1 INCI value (13,912), whose level is the best level among its raw strings.
--   Levels, each Covalo raw INCI counted at the first level it matches a CosIng inci_name:
--     L0 btrim equal; L1 U+00A0 to space, U+00D7 to "x", trim, whitespace collapsed, lower case;
--     L2 L1 then every character outside A-Z and 0-9 removed (F1b strong normalisation, on
--     upper case); L3 only for raw strings unmatched at L0 to L2: split on ";" and on "," not
--     between two digits (never on "/"), each component matched at L0 to L2; "all" components
--     matched counts as matched at L3, "some" is reported separately and is not a match.
--   Product level: best level over the product's INCI (at least one INCI matched).
--   Two CosIng reference sets: 'all' rows; 'excl_fragrance' = rows except those whose only
--     functions are PERFUMING or FRAGRANCE. All duplicate CosIng INCI rows are kept.
--   Bridge: CosIng CAS = CAS-pattern tokens from cas_no and ec_no, EC = EC-pattern tokens from
--     both columns (classified by pattern, not column); placeholders yield no token; tokens
--     failing the check digit are excluded and counted; "(generic)" directly after a CAS is a flag.
--     CosIng identifiers of an INCI = those of the CosIng rows it matched at its level.
--   Product classes per identifier type: agree (Covalo and CosIng sets overlap), conflict (both
--     present, no overlap), gain (Covalo none, CosIng some), covalo_only (Covalo some, CosIng
--     none), neither. Covalo CAS/EC = F1 cov_id values (all format-valid tokens, as in F1).
-- Rules, part 2b (tiers, sections q13 to q16):
--   Mapping = (Covalo INCI F1 value, valid CosIng CAS or EC) per reference set, from the CosIng
--     rows the INCI matched at its best level. Sharing = distinct CosIng INCI (L1 key) in the
--     reference set carrying the number. Generic = "(generic)" after the number on any row.
--   Mapping tier: T3 sharing > 10 or generic; T1 INCI level L0 or L1, exactly one valid number of
--     that type for the INCI, sharing = 1, not generic; T2 otherwise.
--   INCI tier: T1 if its single mapping is T1; T3 if all its mappings are T3; otherwise T2.
--   Product (gain class only): contributing INCI = its F1 INCI values with a mapping of that type;
--     best tier over them; all_t1 = every contributing INCI is T1. Blend = more than one F1 INCI.

CREATE TEMP VIEW src AS SELECT * FROM {{cosing_table}};

CREATE FUNCTION pg_temp.residue(t text, kind text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT btrim(regexp_replace(regexp_replace(pg_temp.prep(t),
        coalesce((SELECT string_agg(v, '|') FROM pg_temp.tokens(t, kind) AS v), '$^'), ' ', 'g'),
        '\s+', ' ', 'g'))
$$;

CREATE TEMP TABLE idv AS
SELECT s.cosing_ref_no, s.inci_name, k.kind, k.v AS raw_value,
       coalesce(btrim(k.v), '') = '' AS blank,
       coalesce(btrim(k.v), '') <> '' AND k.v !~ '\d' AS placeholder,
       (SELECT count(*) FROM pg_temp.tokens(k.v, k.kind)) AS n_tokens,
       pg_temp.residue(k.v, k.kind) AS residue
FROM src s CROSS JOIN LATERAL (VALUES ('CAS', s.cas_no), ('EC', s.ec_no)) AS k(kind, v);

CREATE TEMP TABLE idtok AS
SELECT i.cosing_ref_no, i.inci_name, i.kind, t.value,
       CASE i.kind WHEN 'CAS' THEN pg_temp.cas_ok(t.value) ELSE pg_temp.ec_ok(t.value) END AS check_ok
FROM idv i CROSS JOIN LATERAL pg_temp.tokens(i.raw_value, i.kind) AS t(value);

CREATE TEMP TABLE func AS
SELECT s.cosing_ref_no, btrim(f) AS fn FROM src s, regexp_split_to_table(coalesce(s.function, ''), ',') f
WHERE btrim(f) <> '';
CREATE INDEX ON func (cosing_ref_no);
ANALYZE func;

-- Part 2 -----------------------------------------------------------------------------------

CREATE FUNCTION pg_temp.k0(t text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT nullif(btrim(t), '')
$$;
CREATE FUNCTION pg_temp.k1(t text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT nullif(lower(regexp_replace(btrim(translate(t, E' ×', ' x')), '\s+', ' ', 'g')), '')
$$;
CREATE FUNCTION pg_temp.k2(t text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT nullif(regexp_replace(upper(pg_temp.k1(t)), '[^A-Z0-9]', '', 'g'), '')
$$;

-- CosIng rows with match keys and reference-set membership.
CREATE TEMP TABLE cs AS
SELECT s.cosing_ref_no, s.inci_name, s.cas_no, s.ec_no,
       pg_temp.k0(s.inci_name) AS k0, pg_temp.k1(s.inci_name) AS k1, pg_temp.k2(s.inci_name) AS k2,
       NOT (EXISTS (SELECT 1 FROM func f WHERE f.cosing_ref_no = s.cosing_ref_no)
            AND NOT EXISTS (SELECT 1 FROM func f WHERE f.cosing_ref_no = s.cosing_ref_no
                                                   AND f.fn NOT IN ('PERFUMING', 'FRAGRANCE'))) AS in_excl_fragrance
FROM src s;
CREATE INDEX ON cs (k0); CREATE INDEX ON cs (k1); CREATE INDEX ON cs (k2);
ANALYZE cs;

CREATE TEMP TABLE refset AS
SELECT 'all' AS refset, cosing_ref_no, k0, k1, k2 FROM cs
UNION ALL
SELECT 'excl_fragrance', cosing_ref_no, k0, k1, k2 FROM cs WHERE in_excl_fragrance;
CREATE INDEX ON refset (refset, k0); CREATE INDEX ON refset (refset, k1); CREATE INDEX ON refset (refset, k2);
ANALYZE refset;

-- Covalo raw INCI strings (F1 cov_raw) with their F1 value; one row per distinct raw string.
CREATE TEMP TABLE craw AS
SELECT DISTINCT r.raw_value, pg_temp.norm_inci(r.raw_value) AS f1_value,
       pg_temp.k0(r.raw_value) AS k0, pg_temp.k1(r.raw_value) AS k1, pg_temp.k2(r.raw_value) AS k2
FROM cov_raw r WHERE r.id_type = 'INCI' AND pg_temp.norm_inci(r.raw_value) IS NOT NULL;
ANALYZE craw;

-- Level 0 to 2 matches per raw string and reference set (first level only).
CREATE TEMP TABLE m012 AS
WITH l0 AS (SELECT s.refset, c.raw_value, 0 AS lvl, s.cosing_ref_no FROM craw c JOIN refset s ON s.k0 = c.k0),
     l1 AS (SELECT s.refset, c.raw_value, 1, s.cosing_ref_no FROM craw c JOIN refset s ON s.k1 = c.k1
            WHERE NOT EXISTS (SELECT 1 FROM l0 WHERE l0.refset = s.refset AND l0.raw_value = c.raw_value)),
     l2 AS (SELECT s.refset, c.raw_value, 2, s.cosing_ref_no FROM craw c JOIN refset s ON s.k2 = c.k2
            WHERE NOT EXISTS (SELECT 1 FROM l0 WHERE l0.refset = s.refset AND l0.raw_value = c.raw_value)
              AND NOT EXISTS (SELECT 1 FROM l1 WHERE l1.refset = s.refset AND l1.raw_value = c.raw_value))
SELECT * FROM l0 UNION ALL SELECT * FROM l1 UNION ALL SELECT * FROM l2;
CREATE INDEX ON m012 (refset, raw_value);
ANALYZE m012;

-- Level 3: components of raw strings unmatched at L0 to L2 (per reference set).
CREATE TEMP TABLE l3comp AS
SELECT x.refset, c.raw_value, comp.ord, btrim(comp.part) AS part,
       pg_temp.k0(comp.part) AS k0, pg_temp.k1(comp.part) AS k1, pg_temp.k2(comp.part) AS k2
FROM craw c CROSS JOIN (VALUES ('all'), ('excl_fragrance')) AS x(refset)
CROSS JOIN LATERAL regexp_split_to_table(c.raw_value, ';|(?<![0-9]),|,(?![0-9])') WITH ORDINALITY AS comp(part, ord)
WHERE NOT EXISTS (SELECT 1 FROM m012 m WHERE m.refset = x.refset AND m.raw_value = c.raw_value)
  AND btrim(comp.part) <> '';

-- Component matches at L0 to L2 (first level per component).
CREATE TEMP TABLE l3hit AS
WITH h AS (
    SELECT c.refset, c.raw_value, c.ord, 0 AS lvl, s.cosing_ref_no FROM l3comp c JOIN refset s ON s.refset = c.refset AND s.k0 = c.k0
    UNION ALL
    SELECT c.refset, c.raw_value, c.ord, 1, s.cosing_ref_no FROM l3comp c JOIN refset s ON s.refset = c.refset AND s.k1 = c.k1
    UNION ALL
    SELECT c.refset, c.raw_value, c.ord, 2, s.cosing_ref_no FROM l3comp c JOIN refset s ON s.refset = c.refset AND s.k2 = c.k2)
SELECT refset, raw_value, ord, lvl, cosing_ref_no
FROM (SELECT h.*, min(lvl) OVER (PARTITION BY refset, raw_value, ord) AS first_lvl FROM h) x
WHERE lvl = first_lvl;
CREATE INDEX ON l3hit (refset, raw_value, ord);

CREATE TEMP TABLE l3sum AS
SELECT c.refset, c.raw_value, count(*) AS components,
       count(*) FILTER (WHERE EXISTS (SELECT 1 FROM l3hit h WHERE h.refset = c.refset AND h.raw_value = c.raw_value AND h.ord = c.ord)) AS components_matched
FROM l3comp c GROUP BY 1, 2;

-- CosIng rows matched by L3 components (only for strings split into several components that all match).
CREATE TEMP TABLE m3 AS
SELECT DISTINCT h.refset, h.raw_value, 3 AS lvl, h.cosing_ref_no
FROM l3hit h JOIN l3sum u USING (refset, raw_value)
WHERE u.components > 1 AND u.components_matched = u.components;

CREATE TEMP TABLE m_all AS SELECT * FROM m012 UNION ALL SELECT * FROM m3;
CREATE INDEX ON m_all (refset, raw_value);
ANALYZE m_all;

-- Level per raw string, per F1 value and per product (per reference set).
CREATE TEMP TABLE raw_lvl AS
SELECT x.refset, c.raw_value, c.f1_value,
       (SELECT min(lvl) FROM m_all m WHERE m.refset = x.refset AND m.raw_value = c.raw_value) AS lvl,
       (SELECT components > 1 AND components_matched BETWEEN 1 AND components - 1
        FROM l3sum u WHERE u.refset = x.refset AND u.raw_value = c.raw_value) AS l3_partial
FROM craw c CROSS JOIN (VALUES ('all'), ('excl_fragrance')) AS x(refset);

CREATE TEMP TABLE val_lvl AS
SELECT refset, f1_value, min(lvl) AS lvl, bool_or(coalesce(l3_partial, false)) AS l3_partial
FROM raw_lvl GROUP BY 1, 2;

CREATE TEMP TABLE prod_inci AS
SELECT DISTINCT r.product_id, r.raw_value FROM cov_raw r
WHERE r.id_type = 'INCI' AND pg_temp.norm_inci(r.raw_value) IS NOT NULL;
CREATE INDEX ON prod_inci (raw_value);

CREATE TEMP TABLE prod_lvl AS
SELECT x.refset, p.product_id, min(l.lvl) AS lvl, bool_and(l.lvl IS NOT NULL) AS all_inci_matched
FROM prod_inci p CROSS JOIN (VALUES ('all'), ('excl_fragrance')) AS x(refset)
JOIN raw_lvl l ON l.refset = x.refset AND l.raw_value = p.raw_value
GROUP BY 1, 2;

-- Target population (item 0): active ingredients with a usable INCI and no usable CAS.
CREATE TEMP TABLE target AS
SELECT DISTINCT i.product_id FROM cov_id i JOIN cov_product cp USING (product_id)
WHERE cp.product_type = 'INGREDIENTS' AND i.id_type = 'INCI'
  AND NOT EXISTS (SELECT 1 FROM cov_id c WHERE c.product_id = i.product_id AND c.id_type = 'CAS');

-- CosIng identifiers per row, classified by pattern (F1 parser), with check digit and generic flag.
CREATE TEMP TABLE cs_id AS
SELECT DISTINCT s.cosing_ref_no, k.kind AS id_type, t.value,
       CASE k.kind WHEN 'CAS' THEN pg_temp.cas_ok(t.value) ELSE pg_temp.ec_ok(t.value) END AS check_ok,
       k.kind = 'CAS' AND pg_temp.prep(coalesce(s.cas_no, '') || ' ' || coalesce(s.ec_no, ''))
                          ~* (t.value || '\s*\(generic\)') AS generic
FROM cs s CROSS JOIN (VALUES ('CAS'), ('EC')) AS k(kind)
CROSS JOIN LATERAL pg_temp.tokens(coalesce(s.cas_no, '') || ' ' || coalesce(s.ec_no, ''), k.kind) AS t(value);
CREATE INDEX ON cs_id (cosing_ref_no);
ANALYZE cs_id;

-- Number of distinct CosIng INCI (lower, trimmed) carrying each valid CosIng identifier.
CREATE TEMP TABLE cs_id_spread AS
SELECT i.id_type, i.value, count(DISTINCT lower(btrim(s.inci_name))) AS n_inci, bool_or(i.generic) AS generic
FROM cs_id i JOIN cs s USING (cosing_ref_no) WHERE i.check_ok GROUP BY 1, 2;
CREATE UNIQUE INDEX ON cs_id_spread (id_type, value);
ANALYZE cs_id_spread;

-- CosIng identifiers reached per product (via its matched INCI, at their level), per set.
CREATE TEMP TABLE prod_cs_id AS
SELECT DISTINCT m.refset, p.product_id, i.id_type, i.value, i.check_ok, i.generic
FROM prod_inci p
JOIN raw_lvl l ON l.raw_value = p.raw_value AND l.lvl IS NOT NULL
JOIN m_all m ON m.refset = l.refset AND m.raw_value = l.raw_value AND m.lvl = l.lvl
JOIN cs_id i ON i.cosing_ref_no = m.cosing_ref_no;
CREATE INDEX ON prod_cs_id (refset, product_id, id_type);
ANALYZE prod_cs_id;

-- Per gain product: ambiguity flags of its gained identifiers (for q8).
CREATE TEMP TABLE gain_amb AS
SELECT x.refset, x.product_id, x.id_type,
       bool_or(s.n_inci > 1) AS on_gt1, bool_or(s.n_inci > 10) AS on_gt10, bool_or(x.generic) AS generic,
       count(*) AS n_values
FROM prod_cs_id x JOIN cs_id_spread s USING (id_type, value)
WHERE x.check_ok GROUP BY 1, 2, 3;
CREATE INDEX ON gain_amb (refset, product_id, id_type);

-- Bridge class per matched product, set and identifier type.
CREATE TEMP TABLE bridge AS
SELECT pl.refset, pl.product_id, pl.lvl, t.id_type,
       EXISTS (SELECT 1 FROM cov_id c WHERE c.product_id = pl.product_id AND c.id_type = t.id_type) AS cov_has,
       EXISTS (SELECT 1 FROM prod_cs_id x WHERE x.refset = pl.refset AND x.product_id = pl.product_id
                                            AND x.id_type = t.id_type AND x.check_ok) AS cs_has,
       EXISTS (SELECT 1 FROM prod_cs_id x JOIN cov_id c ON c.product_id = x.product_id AND c.id_type = x.id_type
                                                        AND c.value = x.value
               WHERE x.refset = pl.refset AND x.product_id = pl.product_id AND x.id_type = t.id_type AND x.check_ok) AS overlap,
       EXISTS (SELECT 1 FROM prod_cs_id x WHERE x.refset = pl.refset AND x.product_id = pl.product_id
                                            AND x.id_type = t.id_type AND NOT x.check_ok) AS cs_check_fail
FROM prod_lvl pl CROSS JOIN (VALUES ('CAS'), ('EC')) AS t(id_type)
WHERE pl.lvl IS NOT NULL;
ALTER TABLE bridge ADD COLUMN cls text;
UPDATE bridge SET cls = CASE WHEN cov_has AND cs_has AND overlap THEN 'agree'
                             WHEN cov_has AND cs_has THEN 'conflict'
                             WHEN cs_has THEN 'gain'
                             WHEN cov_has THEN 'covalo_only'
                             ELSE 'neither' END;
ANALYZE bridge;

-- Q5 referee flag, as a query (not stored): one row per Covalo INCI value (F1), per reference set.
CREATE TEMP VIEW f3_referee_flag AS
SELECT refset, f1_value AS covalo_inci,
       CASE WHEN lvl IS NULL THEN 'not found in CosIng snapshot' ELSE 'found in CosIng snapshot' END AS flag,
       CASE WHEN lvl IS NULL THEN NULL ELSE 'L' || lvl END AS match_level
FROM val_lvl;

-- Part 2b: tiers ----------------------------------------------------------------------------

-- Sharing per valid CosIng identifier and reference set: distinct CosIng INCI (L1 key).
CREATE TEMP TABLE t_spread AS
SELECT r.refset, i.id_type, i.value, count(DISTINCT r.k1) AS n_inci, bool_or(i.generic) AS generic
FROM cs_id i JOIN refset r USING (cosing_ref_no) WHERE i.check_ok GROUP BY 1, 2, 3;
CREATE UNIQUE INDEX ON t_spread (refset, id_type, value);
ANALYZE t_spread;

-- CosIng rows per Covalo INCI (F1 value) at its best level.
CREATE TEMP TABLE t_inci_row AS
SELECT DISTINCT v.refset, v.f1_value, v.lvl, m.cosing_ref_no
FROM val_lvl v
JOIN raw_lvl l ON l.refset = v.refset AND l.f1_value = v.f1_value AND l.lvl = v.lvl
JOIN m_all m ON m.refset = l.refset AND m.raw_value = l.raw_value AND m.lvl = l.lvl
WHERE v.lvl IS NOT NULL;
CREATE INDEX ON t_inci_row (refset, f1_value);
ANALYZE t_inci_row;

-- Mappings with their tier.
CREATE TEMP TABLE t_map AS
WITH m AS (
    SELECT r.refset, r.f1_value, r.lvl, i.id_type, i.value
    FROM t_inci_row r JOIN cs_id i ON i.cosing_ref_no = r.cosing_ref_no AND i.check_ok
    GROUP BY 1, 2, 3, 4, 5)
SELECT m.*, s.n_inci, s.generic,
       count(*) OVER (PARTITION BY m.refset, m.f1_value, m.id_type) AS n_numbers,
       CASE WHEN s.n_inci > 10 OR s.generic THEN 'T3'
            WHEN m.lvl <= 1 AND count(*) OVER (PARTITION BY m.refset, m.f1_value, m.id_type) = 1
                 AND s.n_inci = 1 THEN 'T1'
            ELSE 'T2' END AS tier
FROM m JOIN t_spread s USING (refset, id_type, value);
CREATE INDEX ON t_map (refset, id_type, f1_value);
ANALYZE t_map;

-- INCI-level tier.
CREATE TEMP TABLE t_inci AS
SELECT refset, id_type, f1_value, count(*) AS n_map,
       CASE WHEN count(*) = 1 AND bool_and(tier = 'T1') THEN 'T1'
            WHEN bool_and(tier = 'T3') THEN 'T3' ELSE 'T2' END AS tier
FROM t_map GROUP BY 1, 2, 3;
CREATE INDEX ON t_inci (refset, id_type, f1_value);
ANALYZE t_inci;

-- Gain products: best tier over contributing INCI, all contributing INCI T1, blend or not.
CREATE TEMP TABLE t_gain AS
SELECT b.refset, b.id_type, b.product_id,
       (SELECT count(*) FROM cov_id i WHERE i.product_id = b.product_id AND i.id_type = 'INCI') > 1 AS blend,
       min(t.tier) AS best_tier, bool_and(t.tier = 'T1') AS all_t1, count(t.tier) AS n_contrib
FROM bridge b
LEFT JOIN cov_id c ON c.product_id = b.product_id AND c.id_type = 'INCI'
LEFT JOIN t_inci t ON t.refset = b.refset AND t.id_type = b.id_type AND t.f1_value = c.value
WHERE b.cls = 'gain'
GROUP BY 1, 2, 3;

-- REPORT

-- p1. PROVISIONAL. Columns and data types
SELECT ordinal_position, column_name, data_type FROM information_schema.columns
WHERE table_schema = split_part('{{cosing_table}}', '.', 1) AND table_name = split_part('{{cosing_table}}', '.', 2)
ORDER BY 1;

-- p2. PROVISIONAL. CosIng reference number (cosing_ref_no): uniqueness and range
SELECT count(*) AS rows_, count(DISTINCT cosing_ref_no) AS distinct_ref_no,
       count(*) FILTER (WHERE cosing_ref_no IS NULL) AS null_ref_no, min(cosing_ref_no), max(cosing_ref_no)
FROM src;

-- p3. PROVISIONAL. Blank (NULL, empty or whitespace) and NULL per column
SELECT c AS column_name, count(*) FILTER (WHERE v IS NULL) AS null_, count(*) FILTER (WHERE v = '') AS empty_string,
       count(*) FILTER (WHERE v <> '' AND btrim(v) = '') AS whitespace_only,
       count(*) FILTER (WHERE coalesce(btrim(v), '') <> '') AS with_value
FROM src CROSS JOIN LATERAL (VALUES ('inci_name', inci_name), ('inn_name', inn_name), ('ph_eur_name', ph_eur_name),
    ('cas_no', cas_no), ('ec_no', ec_no), ('chem_iupac_name', chem_iupac_name), ('restriction', restriction),
    ('function', function), ('update_date', update_date)) AS x(c, v)
GROUP BY 1 ORDER BY 1;

-- p4. PROVISIONAL. Cosmetic ingredient vs Fragrance Inventory: no column marks it; function values PERFUMING / FRAGRANCE as the only indicator
SELECT count(*) AS rows_,
       count(*) FILTER (WHERE EXISTS (SELECT 1 FROM func f WHERE f.cosing_ref_no = s.cosing_ref_no AND f.fn = 'PERFUMING')) AS with_perfuming,
       count(*) FILTER (WHERE EXISTS (SELECT 1 FROM func f WHERE f.cosing_ref_no = s.cosing_ref_no AND f.fn = 'FRAGRANCE')) AS with_fragrance,
       count(*) FILTER (WHERE EXISTS (SELECT 1 FROM func f WHERE f.cosing_ref_no = s.cosing_ref_no)
                          AND NOT EXISTS (SELECT 1 FROM func f WHERE f.cosing_ref_no = s.cosing_ref_no AND f.fn NOT IN ('PERFUMING', 'FRAGRANCE'))) AS only_perfuming_or_fragrance,
       count(*) FILTER (WHERE NOT EXISTS (SELECT 1 FROM func f WHERE f.cosing_ref_no = s.cosing_ref_no)) AS no_function
FROM src s;

-- p5. PROVISIONAL. Function values (top 25)
SELECT fn AS function_value, count(*) AS rows_ FROM func GROUP BY 1 ORDER BY 2 DESC LIMIT 25;

-- p6. PROVISIONAL. INCI: distinct values, duplicates, irregular patterns
SELECT count(*) AS rows_, count(DISTINCT inci_name) AS distinct_exact,
       count(DISTINCT lower(btrim(inci_name))) AS distinct_lower_trim,
       (SELECT count(*) FROM (SELECT inci_name FROM src GROUP BY 1 HAVING count(*) > 1) d) AS values_duplicated_exact,
       (SELECT count(*) FROM (SELECT lower(btrim(inci_name)) FROM src GROUP BY 1 HAVING count(*) > 1) d) AS values_duplicated_lower_trim,
       (SELECT coalesce(sum(n), 0) FROM (SELECT count(*) AS n FROM src GROUP BY lower(btrim(inci_name)) HAVING count(*) > 1) d) AS rows_in_lower_trim_duplicates,
       count(*) FILTER (WHERE inci_name <> btrim(inci_name)) AS leading_or_trailing_space,
       count(*) FILTER (WHERE inci_name ~ '\s{2,}') AS double_space,
       count(*) FILTER (WHERE inci_name ~ '[^\x01-\x7F]') AS non_ascii,
       count(*) FILTER (WHERE inci_name LIKE '%/%') AS contains_slash,
       count(*) FILTER (WHERE inci_name LIKE '%;%') AS contains_semicolon,
       count(*) FILTER (WHERE inci_name ~* ' and ') AS contains_and,
       count(*) FILTER (WHERE inci_name <> upper(inci_name)) AS not_upper_case
FROM src;

-- p6b. PROVISIONAL. Non-ASCII characters in INCI, CAS and EC (code point, occurrences)
SELECT c AS column_name, 'U+' || upper(lpad(to_hex(ascii(m[1])), 4, '0')) AS code_point, count(*) AS occurrences
FROM src CROSS JOIN LATERAL (VALUES ('inci_name', inci_name), ('cas_no', cas_no), ('ec_no', ec_no)) AS x(c, v),
     regexp_matches(coalesce(v, ''), '([^\x01-\x7F])', 'g') AS m
GROUP BY 1, 2 ORDER BY 1, 3 DESC;

-- p7. PROVISIONAL. INCI examples (up to 10 per irregular pattern)
SELECT pattern, cosing_ref_no, '[' || inci_name || ']' AS inci_bracketed
FROM (SELECT p.pattern, s.cosing_ref_no, s.inci_name,
             row_number() OVER (PARTITION BY p.pattern ORDER BY s.cosing_ref_no) AS rn
      FROM src s CROSS JOIN LATERAL (VALUES
          ('leading_or_trailing_space', s.inci_name <> btrim(s.inci_name)),
          ('double_space', s.inci_name ~ '\s{2,}'),
          ('non_ascii', s.inci_name ~ '[^\x01-\x7F]'),
          ('contains_semicolon', s.inci_name LIKE '%;%'),
          ('contains_and', s.inci_name ~* ' and '),
          ('not_upper_case', s.inci_name <> upper(s.inci_name)),
          ('duplicate_lower_trim', lower(btrim(s.inci_name)) IN (SELECT lower(btrim(inci_name)) FROM src GROUP BY 1 HAVING count(*) > 1))
      ) AS p(pattern, hit) WHERE p.hit) x
WHERE rn <= 10 ORDER BY 1, 2;

-- p8. PROVISIONAL. INCI containing "/": examples (slash is part of many valid INCI names, e.g. copolymers)
SELECT cosing_ref_no, inci_name FROM src WHERE inci_name LIKE '%/%' ORDER BY cosing_ref_no LIMIT 10;

-- p9. PROVISIONAL. CAS and EC: value states and token counts
SELECT kind, count(*) AS rows_,
       count(*) FILTER (WHERE blank) AS blank,
       count(*) FILTER (WHERE placeholder) AS placeholder,
       count(*) FILTER (WHERE NOT blank AND NOT placeholder) AS with_value,
       count(*) FILTER (WHERE n_tokens = 1) AS one_token,
       count(*) FILTER (WHERE n_tokens > 1) AS multi_token,
       count(*) FILTER (WHERE NOT blank AND NOT placeholder AND n_tokens = 0) AS value_without_token,
       count(*) FILTER (WHERE n_tokens > 0 AND residue <> '' AND n_tokens = 1) AS single_token_with_residue
FROM idv GROUP BY 1 ORDER BY 1;

-- p10. PROVISIONAL. Placeholder values found
SELECT kind, raw_value, count(*) FROM idv WHERE placeholder GROUP BY 1, 2 ORDER BY 3 DESC;

-- p11. PROVISIONAL. Separators and qualifiers left after removing tokens (multi-token values and residue), top 20 per kind
SELECT kind, residue, rows_ FROM (
    SELECT kind, residue, count(*) AS rows_, row_number() OVER (PARTITION BY kind ORDER BY count(*) DESC, residue) AS rn
    FROM idv WHERE n_tokens > 0 AND residue <> '' GROUP BY kind, residue) x
WHERE rn <= 20 ORDER BY kind, rn;

-- p12. PROVISIONAL. Tokens: distinct, check-digit failures, tokens on more than one INCI (lower, trimmed)
SELECT kind, count(*) AS token_rows, count(DISTINCT value) AS distinct_tokens,
       count(DISTINCT value) FILTER (WHERE NOT check_ok) AS distinct_check_fail,
       (SELECT count(*) FROM (SELECT value FROM idtok t2 WHERE t2.kind = t.kind GROUP BY value
                              HAVING count(DISTINCT lower(btrim(inci_name))) > 1) d) AS tokens_on_several_inci
FROM idtok t GROUP BY kind ORDER BY 1;

-- p13. PROVISIONAL. Tokens on the most INCI names (top 10 per kind)
SELECT kind, value, n_inci FROM (
    SELECT kind, value, count(DISTINCT lower(btrim(inci_name))) AS n_inci,
           row_number() OVER (PARTITION BY kind ORDER BY count(DISTINCT lower(btrim(inci_name))) DESC, value) AS rn
    FROM idtok GROUP BY kind, value) x
WHERE rn <= 10 ORDER BY kind, rn;

-- p14. PROVISIONAL. CAS / EC examples (up to 10 per irregular pattern)
SELECT kind, pattern, cosing_ref_no, '[' || raw_value || ']' AS raw_bracketed FROM (
    SELECT i.kind, p.pattern, i.cosing_ref_no, i.raw_value,
           row_number() OVER (PARTITION BY i.kind, p.pattern ORDER BY i.cosing_ref_no) AS rn
    FROM idv i CROSS JOIN LATERAL (VALUES
        ('multi_token', i.n_tokens > 1),
        ('value_without_token', NOT i.blank AND NOT i.placeholder AND i.n_tokens = 0),
        ('single_token_with_residue', i.n_tokens = 1 AND i.residue <> ''),
        ('check_digit_fail', EXISTS (SELECT 1 FROM idtok t WHERE t.cosing_ref_no = i.cosing_ref_no AND t.kind = i.kind AND NOT t.check_ok)),
        ('leading_or_trailing_space', NOT i.blank AND i.raw_value <> btrim(i.raw_value))
    ) AS p(pattern, hit) WHERE p.hit) x
WHERE rn <= 10 ORDER BY 1, 2, 3;

-- p15. PROVISIONAL. CAS / EC: values with leading or trailing spaces
SELECT kind, count(*) FILTER (WHERE NOT blank AND raw_value <> btrim(raw_value)) AS with_outer_space FROM idv GROUP BY 1 ORDER BY 1;

-- p16. PROVISIONAL. Restriction column: value patterns (digits as #), top 25
SELECT regexp_replace(btrim(restriction), '\d+', '#', 'g') AS pattern, count(*) AS rows_
FROM src WHERE coalesce(btrim(restriction), '') <> '' GROUP BY 1 ORDER BY 2 DESC LIMIT 25;

-- p17. PROVISIONAL. Restriction column: rows by annex references found (II to VI), a row can cite several
SELECT m[1] AS annex, count(DISTINCT cosing_ref_no) AS rows_
FROM src, regexp_matches(coalesce(restriction, ''), '\m(VI|V|IV|III|II)/\d', 'g') AS m
GROUP BY 1 ORDER BY 1;

-- p18. PROVISIONAL. Update date: format, range, latest (lower bound for the snapshot date)
SELECT count(*) FILTER (WHERE update_date ~ '^\d{2}/\d{2}/\d{4}$') AS dd_mm_yyyy,
       count(*) FILTER (WHERE update_date !~ '^\d{2}/\d{2}/\d{4}$') AS other_format,
       min(to_date(update_date, 'DD/MM/YYYY')) FILTER (WHERE update_date ~ '^\d{2}/\d{2}/\d{4}$') AS earliest,
       max(to_date(update_date, 'DD/MM/YYYY')) FILTER (WHERE update_date ~ '^\d{2}/\d{2}/\d{4}$') AS latest
FROM src;

-- p19. PROVISIONAL. Rows per update year
SELECT right(update_date, 4) AS year, count(*) AS rows_ FROM src
WHERE update_date ~ '^\d{2}/\d{2}/\d{4}$' GROUP BY 1 ORDER BY 1;

-- p20. PROVISIONAL. Rows on the latest update dates (top 5 dates)
SELECT to_date(update_date, 'DD/MM/YYYY') AS update_date, count(*) AS rows_ FROM src
WHERE update_date ~ '^\d{2}/\d{2}/\d{4}$' GROUP BY 1 ORDER BY 1 DESC LIMIT 5;

-- q0. PROVISIONAL. Target population: active ingredients with a usable Covalo INCI and no usable Covalo CAS
SELECT count(*) AS target_products,
       (SELECT count(DISTINCT i.value) FROM cov_id i JOIN target t USING (product_id) WHERE i.id_type = 'INCI') AS distinct_inci_on_them,
       (SELECT count(*) FROM target t WHERE EXISTS (SELECT 1 FROM cov_id c WHERE c.product_id = t.product_id AND c.id_type = 'EC')) AS with_covalo_ec
FROM target;

-- q1. PROVISIONAL. Q2 cumulative match by level: distinct Covalo INCI (F1 values), products with INCI (at least one INCI matched), target products
SELECT x.refset, 'L' || k.lvl AS up_to_level,
       (SELECT count(*) FROM val_lvl v WHERE v.refset = x.refset AND v.lvl = k.lvl) AS distinct_inci_new_at_level,
       (SELECT count(*) FROM val_lvl v WHERE v.refset = x.refset AND v.lvl <= k.lvl) AS distinct_inci_cum,
       (SELECT count(*) FROM val_lvl v WHERE v.refset = x.refset) AS distinct_inci_total,
       (SELECT count(*) FROM prod_lvl p WHERE p.refset = x.refset AND p.lvl <= k.lvl) AS products_cum,
       (SELECT count(*) FROM prod_lvl p WHERE p.refset = x.refset) AS products_total,
       (SELECT count(*) FROM prod_lvl p JOIN target t USING (product_id) WHERE p.refset = x.refset AND p.lvl <= k.lvl) AS target_products_cum,
       (SELECT count(*) FROM target) AS target_total
FROM (VALUES ('all'), ('excl_fragrance')) AS x(refset) CROSS JOIN (VALUES (0), (1), (2), (3)) AS k(lvl)
ORDER BY 1, 2;

-- q2. PROVISIONAL. Unmatched after L3, L3 partial matches, products with every INCI matched
SELECT x.refset,
       (SELECT count(*) FROM val_lvl v WHERE v.refset = x.refset AND v.lvl IS NULL) AS distinct_inci_unmatched,
       (SELECT count(*) FROM val_lvl v WHERE v.refset = x.refset AND v.lvl IS NULL AND v.l3_partial) AS of_which_l3_some_components,
       (SELECT coalesce(sum(c.products), 0) FROM val_lvl v JOIN cov_val c ON c.id_type = 'INCI' AND c.value = v.f1_value
        WHERE v.refset = x.refset AND v.lvl IS NULL) AS product_links_unmatched,
       (SELECT count(*) FROM prod_lvl p WHERE p.refset = x.refset AND p.lvl IS NULL) AS products_no_inci_matched,
       (SELECT count(*) FROM prod_lvl p WHERE p.refset = x.refset AND p.all_inci_matched) AS products_all_inci_matched,
       (SELECT count(*) FROM prod_lvl p JOIN target t USING (product_id) WHERE p.refset = x.refset AND p.lvl IS NULL) AS target_products_no_inci_matched
FROM (VALUES ('all'), ('excl_fragrance')) AS x(refset);

-- q3. PROVISIONAL. L3 detail (raw strings unmatched at L0 to L2): split, components, all / some / none matched
SELECT refset,
       count(*) FILTER (WHERE components > 1) AS raw_strings_split,
       sum(components) FILTER (WHERE components > 1) AS components,
       count(*) FILTER (WHERE components > 1 AND components_matched = components) AS all_components_matched,
       count(*) FILTER (WHERE components > 1 AND components_matched BETWEEN 1 AND components - 1) AS some_components_matched,
       count(*) FILTER (WHERE components > 1 AND components_matched = 0) AS no_component_matched,
       count(*) FILTER (WHERE components = 1) AS raw_strings_not_split
FROM l3sum GROUP BY 1 ORDER BY 1;

-- q4. PROVISIONAL. Covalo INCI matched only through Fragrance-only CosIng rows (matched with all rows, not without them)
SELECT count(*) AS distinct_inci, coalesce(sum(c.products), 0) AS product_links
FROM val_lvl a JOIN val_lvl e ON e.f1_value = a.f1_value AND e.refset = 'excl_fragrance'
JOIN cov_val c ON c.id_type = 'INCI' AND c.value = a.f1_value
WHERE a.refset = 'all' AND a.lvl IS NOT NULL AND e.lvl IS NULL;

-- q5. PROVISIONAL. Sample of 50 unmatched Covalo INCI (all CosIng rows), seed 20261021 (order by md5('20261021' || value)); pg_trgm not installed, no nearest CosIng INCI
SELECT v.f1_value AS covalo_inci, c.products
FROM val_lvl v JOIN cov_val c ON c.id_type = 'INCI' AND c.value = v.f1_value
WHERE v.refset = 'all' AND v.lvl IS NULL
ORDER BY md5('20261021' || v.f1_value) LIMIT 50;

-- q6. PROVISIONAL. Q3 bridge class per matched product, by identifier type and match level; distinct Covalo INCI on those products
SELECT b.refset, b.id_type, b.cls, count(*) AS products,
       count(*) FILTER (WHERE b.lvl = 0) AS l0, count(*) FILTER (WHERE b.lvl = 1) AS l1,
       count(*) FILTER (WHERE b.lvl = 2) AS l2, count(*) FILTER (WHERE b.lvl = 3) AS l3,
       count(*) FILTER (WHERE b.product_id IN (SELECT product_id FROM target)) AS target_products,
       (SELECT count(DISTINCT i.value) FROM cov_id i
         WHERE i.id_type = 'INCI' AND i.product_id IN (SELECT b2.product_id FROM bridge b2
                                                       WHERE b2.refset = b.refset AND b2.id_type = b.id_type AND b2.cls = b.cls)) AS distinct_inci
FROM bridge b GROUP BY 1, 2, 3 ORDER BY 1, 2, 3;

-- q7. PROVISIONAL. CosIng identifiers failing the check digit, excluded from the bridge
SELECT x.refset, x.id_type, count(DISTINCT x.value) AS distinct_values, count(DISTINCT x.product_id) AS products_reaching_them,
       count(DISTINCT x.product_id) FILTER (WHERE NOT EXISTS (
           SELECT 1 FROM prod_cs_id y WHERE y.refset = x.refset AND y.product_id = x.product_id AND y.id_type = x.id_type AND y.check_ok))
           AS products_with_only_failing_values
FROM prod_cs_id x WHERE NOT x.check_ok GROUP BY 1, 2 ORDER BY 1, 2;

-- q8. PROVISIONAL. Ambiguity in the gain group: gained identifiers that sit on several CosIng INCI, or are flagged generic
SELECT b.refset, b.id_type, count(*) AS gain_products,
       count(*) FILTER (WHERE g.on_gt1) AS on_more_than_1_cosing_inci,
       count(*) FILTER (WHERE g.on_gt10) AS on_more_than_10_cosing_inci,
       count(*) FILTER (WHERE g.generic) AS flagged_generic,
       count(*) FILTER (WHERE g.n_values > 1) AS several_values_gained,
       count(*) FILTER (WHERE (SELECT count(*) FROM cov_id i WHERE i.product_id = b.product_id AND i.id_type = 'INCI') > 1) AS product_has_several_inci
FROM bridge b JOIN gain_amb g USING (refset, product_id, id_type)
WHERE b.cls = 'gain' GROUP BY 1, 2 ORDER BY 1, 2;

-- q9. PROVISIONAL. Ten examples of CAS conflict (all CosIng rows): Covalo INCI and CAS, CosIng CAS, match level
SELECT b.product_id, 'L' || b.lvl AS lvl,
       (SELECT string_agg(DISTINCT i.value, ' | ') FROM cov_id i WHERE i.product_id = b.product_id AND i.id_type = 'INCI') AS covalo_inci,
       (SELECT string_agg(DISTINCT i.value, ' | ') FROM cov_id i WHERE i.product_id = b.product_id AND i.id_type = 'CAS') AS covalo_cas,
       (SELECT string_agg(DISTINCT x.value, ' | ') FROM prod_cs_id x WHERE x.refset = 'all' AND x.product_id = b.product_id
                                                                         AND x.id_type = 'CAS' AND x.check_ok) AS cosing_cas
FROM bridge b WHERE b.refset = 'all' AND b.id_type = 'CAS' AND b.cls = 'conflict'
ORDER BY md5('20261021' || b.product_id) LIMIT 10;

-- q10. PROVISIONAL. Ten examples of ambiguous CAS gain (all CosIng rows; gained CAS on more than one CosIng INCI or generic)
SELECT b.product_id, 'L' || b.lvl AS lvl,
       (SELECT string_agg(DISTINCT i.value, ' | ') FROM cov_id i WHERE i.product_id = b.product_id AND i.id_type = 'INCI') AS covalo_inci,
       (SELECT string_agg(DISTINCT x.value || ' (' || s.n_inci || ' INCI' || CASE WHEN x.generic THEN ', generic' ELSE '' END || ')', ' | ')
          FROM prod_cs_id x JOIN cs_id_spread s USING (id_type, value)
         WHERE x.refset = 'all' AND x.product_id = b.product_id AND x.id_type = 'CAS' AND x.check_ok) AS cosing_cas
FROM bridge b
WHERE b.refset = 'all' AND b.id_type = 'CAS' AND b.cls = 'gain'
  AND EXISTS (SELECT 1 FROM prod_cs_id x JOIN cs_id_spread s USING (id_type, value)
              WHERE x.refset = 'all' AND x.product_id = b.product_id AND x.id_type = 'CAS' AND x.check_ok
                AND (s.n_inci > 1 OR x.generic))
ORDER BY md5('20261021' || b.product_id) LIMIT 10;

-- q11. PROVISIONAL. Q5 referee flag (view f3_referee_flag): distinct Covalo INCI per flag and level
SELECT refset, flag, coalesce(match_level, '') AS match_level, count(*) AS distinct_inci
FROM f3_referee_flag GROUP BY 1, 2, 3 ORDER BY 1, 2, 3;

-- q12. PROVISIONAL. Q5 referee flag: ten example rows (all CosIng rows)
SELECT covalo_inci, flag, match_level FROM f3_referee_flag WHERE refset = 'all'
ORDER BY md5('20261021' || covalo_inci) LIMIT 10;

-- q13. PROVISIONAL. Part 2b item 1: distinct Covalo INCI with at least one valid CosIng number, by INCI tier; mappings by mapping tier; product links of those INCI
SELECT x.refset, y.id_type, z.tier,
       (SELECT count(*) FROM t_inci i WHERE i.refset = x.refset AND i.id_type = y.id_type AND i.tier = z.tier) AS distinct_inci,
       (SELECT coalesce(sum(c.products), 0) FROM t_inci i JOIN cov_val c ON c.id_type = 'INCI' AND c.value = i.f1_value
         WHERE i.refset = x.refset AND i.id_type = y.id_type AND i.tier = z.tier) AS product_links,
       (SELECT count(*) FROM t_map m WHERE m.refset = x.refset AND m.id_type = y.id_type AND m.tier = z.tier) AS mappings
FROM (VALUES ('all'), ('excl_fragrance')) AS x(refset) CROSS JOIN (VALUES ('CAS'), ('EC')) AS y(id_type)
CROSS JOIN (VALUES ('T1'), ('T2'), ('T3')) AS z(tier)
ORDER BY 1, 2, 3;

-- q13b. PROVISIONAL. Part 2b item 1: matched Covalo INCI without a valid CosIng number; reasons for T2 mappings (not exclusive)
SELECT x.refset, y.id_type,
       (SELECT count(*) FROM val_lvl v WHERE v.refset = x.refset AND v.lvl IS NOT NULL) AS matched_inci,
       (SELECT count(*) FROM val_lvl v WHERE v.refset = x.refset AND v.lvl IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM t_inci i WHERE i.refset = v.refset AND i.id_type = y.id_type AND i.f1_value = v.f1_value)) AS matched_inci_no_valid_number,
       (SELECT count(*) FROM t_map m WHERE m.refset = x.refset AND m.id_type = y.id_type AND m.tier = 'T2') AS t2_mappings,
       (SELECT count(*) FROM t_map m WHERE m.refset = x.refset AND m.id_type = y.id_type AND m.tier = 'T2' AND m.lvl >= 2) AS t2_level_l2_l3,
       (SELECT count(*) FROM t_map m WHERE m.refset = x.refset AND m.id_type = y.id_type AND m.tier = 'T2' AND m.n_numbers > 1) AS t2_several_numbers,
       (SELECT count(*) FROM t_map m WHERE m.refset = x.refset AND m.id_type = y.id_type AND m.tier = 'T2' AND m.n_inci BETWEEN 2 AND 10) AS t2_sharing_2_to_10
FROM (VALUES ('all'), ('excl_fragrance')) AS x(refset) CROSS JOIN (VALUES ('CAS'), ('EC')) AS y(id_type)
ORDER BY 1, 2;

-- q14. PROVISIONAL. Part 2b item 1: mappings by number of CosIng INCI sharing the number
SELECT refset, id_type,
       CASE WHEN n_inci = 1 THEN '1' WHEN n_inci <= 3 THEN '2 to 3' WHEN n_inci <= 10 THEN '4 to 10'
            WHEN n_inci <= 50 THEN '11 to 50' ELSE 'more than 50' END AS sharing,
       count(*) AS mappings, count(DISTINCT f1_value) AS distinct_covalo_inci, count(DISTINCT value) AS distinct_numbers
FROM t_map GROUP BY 1, 2, 3 ORDER BY 1, 2, min(n_inci);

-- q15. PROVISIONAL. Part 2b item 2: gain products (Covalo has none of that type) by best tier of their contributing INCI; all gained numbers from T1 INCI; single-INCI vs blend
SELECT refset, id_type, CASE WHEN blend THEN 'blend' ELSE 'single_inci' END AS product_kind,
       count(*) AS gain_products,
       count(*) FILTER (WHERE best_tier = 'T1') AS best_t1, count(*) FILTER (WHERE best_tier = 'T2') AS best_t2,
       count(*) FILTER (WHERE best_tier = 'T3') AS best_t3, count(*) FILTER (WHERE best_tier IS NULL) AS no_tier,
       count(*) FILTER (WHERE all_t1) AS all_gained_from_t1_inci
FROM t_gain GROUP BY 1, 2, 3 ORDER BY 1, 2, 3;

-- q16. PROVISIONAL. Part 2b item 3: validation sample, CAS mappings (all CosIng rows), 60 T1 / 40 T2 / 20 T3, one weight per mapping, seed 20261022 (order by md5('20261022' || covalo_inci || '|' || cas)); written to data/validation/f3_tier_sample.csv
WITH s AS (
    SELECT m.*, row_number() OVER (PARTITION BY m.tier ORDER BY md5('20261022' || m.f1_value || '|' || m.value)) AS rn
    FROM t_map m WHERE m.refset = 'all' AND m.id_type = 'CAS'),
pick AS (
    SELECT * FROM s WHERE (tier = 'T1' AND rn <= 60) OR (tier = 'T2' AND rn <= 40) OR (tier = 'T3' AND rn <= 20)),
sup AS (
    SELECT p.f1_value, p.value, r.cosing_ref_no
    FROM pick p JOIN t_inci_row r ON r.refset = 'all' AND r.f1_value = p.f1_value
    JOIN cs_id i ON i.cosing_ref_no = r.cosing_ref_no AND i.id_type = 'CAS' AND i.value = p.value AND i.check_ok)
SELECT row_number() OVER (ORDER BY p.tier, p.rn) AS sample_id, p.tier, p.f1_value AS covalo_inci,
       (SELECT string_agg(DISTINCT regexp_replace(btrim(c.inci_name), '[\t\r\n]+', ' ', 'g'), ' | ')
          FROM sup JOIN src c USING (cosing_ref_no) WHERE sup.f1_value = p.f1_value AND sup.value = p.value) AS cosing_inci,
       'L' || p.lvl AS match_level,
       (SELECT string_agg(DISTINCT sup.cosing_ref_no::text, ' | ')
          FROM sup WHERE sup.f1_value = p.f1_value AND sup.value = p.value) AS cosing_ref_no,
       p.value AS cas,
       (SELECT string_agg(DISTINCT e.value, ' | ')
          FROM sup JOIN cs_id e ON e.cosing_ref_no = sup.cosing_ref_no AND e.id_type = 'EC' AND e.check_ok
         WHERE sup.f1_value = p.f1_value AND sup.value = p.value) AS ec,
       (SELECT string_agg(DISTINCT regexp_replace(btrim(c.chem_iupac_name), '[\t\r\n]+', ' ', 'g'), ' | ')
          FROM sup JOIN src c USING (cosing_ref_no) WHERE sup.f1_value = p.f1_value AND sup.value = p.value) AS cosing_chem_name,
       p.n_inci AS cosing_inci_sharing_cas,
       (SELECT c.products FROM cov_val c WHERE c.id_type = 'INCI' AND c.value = p.f1_value) AS covalo_products,
       '' AS verdict, '' AS note
FROM pick p ORDER BY 1
