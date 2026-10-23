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
-- Rules, part 3 (options, sections o1 to o14; definitions decided by Kevin 2026-10-22):
--   Matching: the F1 replay matcher unchanged (product identifier value = rx_id value, same type,
--     printed or enriched). Option A = F1 "any" (cov_id against rx_id).
--   Derived numbers per product: for each of its F1 INCI values, the CosIng mappings of the part
--     2b tables (reference set 'all', fragrance-only rows included) whose INCI-level tier for that
--     number type is in the option's set: B T1; C T1+T2; reference C+T3. D = C plus catalogue
--     numbers, clean mappings only (D clean) or all (D all). Blends inherit each component's numbers.
--   Conflict rule (CAS only, as decided): if the product has a Covalo CAS and the derived CAS of a
--     source (CosIng, catalogue) do not overlap it, that source's derived CAS are not used for the
--     product. Derived EC are used as they are; EC conflicts are counted only.
--   Catalogue (kevin.relayx_eu_identifiers_v2): cas_number, ec_number, inci_name and inci_name_us
--     split on "|"; CAS and EC parsed with the F1 tokens, check-digit failures excluded and counted;
--     all INCI names on a row are synonyms sharing its numbers. Covalo raw INCI matched against the
--     split names at L0 to L1 (part 2 keys k0, k1), per F1 value at its best level. A mapping is
--     clean if its row has exactly one valid CAS and that CAS is on no other catalogue row.
--   Entry attributes: annex group and scope class as in sql/provisional/f1b_additions.sql
--     (docs/data-model/cosmetics-scope.md; REACH CMR appendices as their own group); an entry
--     prints INCI if identifiers.inci is non-blank or identifiers.inciList is non-empty.
--   Found excluding exemption: at least one hit entry with annexType other than EXEMPTION and
--     INVENTORY_LISTED. Gain = found in the option and not in A.

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

-- Part 3: options ----------------------------------------------------------------------------

-- Replay entries: annex group, scope class, annexType, entryScope, prints INCI.
CREATE TEMP TABLE p3_entry AS
SELECT DISTINCT ON (ev.logical_entry_id) ev.logical_entry_id, ev.payload ->> 'annexType' AS annex_type,
       ev.payload ->> 'entryScope' AS entry_scope, ev.payload ->> 'annexRef' AS annex_ref, ev.payload ->> 'entryRef' AS entry_ref,
       CASE WHEN ev.payload -> 'text' ->> 'officialRef' = '32026R1383' THEN 'CITES 32026R1383, 11 annexes'
            WHEN ev.payload -> 'text' ->> 'officialRef' = '32025R0006' THEN 'CITES 32025R0006, Annex (1) and (2)'
            ELSE ev.payload ->> 'annexRef' END AS annex_group,
       CASE WHEN ev.payload ->> 'annexRef' IN ('Annex II', 'Annex III', 'Annex IV', 'Annex V', 'Annex VI', 'Article 15(1)', 'Article 15(2)')
                 THEN '1 core cosmetics'
            WHEN ev.payload ->> 'annexRef' IN ('Annex VI Table 3', 'REACH Annex XVII', 'REACH Annex XIV', 'REACH Candidate List',
                               'POPs Regulation', 'Annex I, part A') THEN '2 indirectly relevant'
            WHEN ev.payload ->> 'annexRef' IN ('CMR category 1A', 'CMR category 1B', 'Mutagens', 'Toxic category 1', 'Toxic category 2')
                 THEN '3 REACH CMR appendices (own group)'
            WHEN ev.payload -> 'text' ->> 'officialRef' IN ('32026R1383', '32025R0006') THEN '4 marginal'
            WHEN ev.payload ->> 'annexRef' IN ('Exemptions', 'REACH Annex V') THEN '5 not relevant'
            ELSE '9 unclassified' END AS scope_class,
       EXISTS (SELECT 1 FROM relayx_raw.entry_version v2 WHERE v2.run_id = ev.run_id AND v2.logical_entry_id = ev.logical_entry_id
               AND (coalesce(btrim(v2.payload -> 'identifiers' ->> 'inci'), '') <> ''
                    OR (jsonb_typeof(v2.payload -> 'identifiers' -> 'inciList') = 'array'
                        AND jsonb_array_length(v2.payload -> 'identifiers' -> 'inciList') > 0))) AS prints_inci
FROM relayx_raw.entry_version ev
WHERE ev.run_id = '20261019T143522Z_eu' AND ev.logical_entry_id IN (SELECT logical_entry_id FROM rx_entry)
ORDER BY ev.logical_entry_id, ev.page_no DESC, ev.row_no DESC;
CREATE UNIQUE INDEX ON p3_entry (logical_entry_id);
ANALYZE p3_entry;

CREATE TEMP TABLE p3_rx AS SELECT DISTINCT logical_entry_id, id_type, value FROM rx_id;
CREATE INDEX ON p3_rx (id_type, value);
ANALYZE p3_rx;

-- Active ingredient products with their number of F1 INCI values.
CREATE TEMP TABLE p3_prod AS
SELECT cp.product_id, (SELECT count(*) FROM cov_id i WHERE i.product_id = cp.product_id AND i.id_type = 'INCI') AS n_inci,
       EXISTS (SELECT 1 FROM cov_id i WHERE i.product_id = cp.product_id AND i.id_type = 'CAS') AS has_cas
FROM cov_product cp WHERE cp.product_type = 'INGREDIENTS';
CREATE UNIQUE INDEX ON p3_prod (product_id);
ANALYZE p3_prod;

-- Catalogue: split values, valid numbers per row, names with match keys, clean rows.
CREATE TEMP TABLE p3_cat_num AS
SELECT DISTINCT k.id AS row_id, 'CAS' AS id_type, t.value, pg_temp.cas_ok(t.value) AS check_ok
FROM kevin.relayx_eu_identifiers_v2 k CROSS JOIN LATERAL regexp_split_to_table(coalesce(k.cas_number, ''), '\|') s
CROSS JOIN LATERAL pg_temp.tokens(s, 'CAS') AS t(value)
UNION
SELECT DISTINCT k.id, 'EC', t.value, pg_temp.ec_ok(t.value)
FROM kevin.relayx_eu_identifiers_v2 k CROSS JOIN LATERAL regexp_split_to_table(coalesce(k.ec_number, ''), '\|') s
CROSS JOIN LATERAL pg_temp.tokens(s, 'EC') AS t(value);
CREATE INDEX ON p3_cat_num (row_id);
CREATE TEMP TABLE p3_cat_name AS
SELECT DISTINCT k.id AS row_id, pg_temp.k0(s) AS k0, pg_temp.k1(s) AS k1
FROM kevin.relayx_eu_identifiers_v2 k
CROSS JOIN LATERAL regexp_split_to_table(coalesce(k.inci_name, '') || '|' || coalesce(k.inci_name_us, ''), '\|') s
WHERE pg_temp.k0(s) IS NOT NULL;
CREATE INDEX ON p3_cat_name (k0); CREATE INDEX ON p3_cat_name (k1);
ANALYZE p3_cat_name;
CREATE TEMP TABLE p3_cat_clean AS
SELECT r.row_id FROM p3_cat_num r WHERE r.id_type = 'CAS' AND r.check_ok GROUP BY r.row_id
HAVING count(DISTINCT r.value) = 1
   AND NOT EXISTS (SELECT 1 FROM p3_cat_num o WHERE o.id_type = 'CAS' AND o.check_ok AND o.value = min(r.value) AND o.row_id <> r.row_id);
CREATE UNIQUE INDEX ON p3_cat_clean (row_id);

-- Covalo INCI (F1 value) against catalogue names, L0 then L1 per raw string, best level per value.
CREATE TEMP TABLE p3_cat_m AS
WITH l0 AS (SELECT c.raw_value, 0 AS lvl, n.row_id FROM craw c JOIN p3_cat_name n ON n.k0 = c.k0),
     l1 AS (SELECT c.raw_value, 1 AS lvl, n.row_id FROM craw c JOIN p3_cat_name n ON n.k1 = c.k1
            WHERE NOT EXISTS (SELECT 1 FROM l0 WHERE l0.raw_value = c.raw_value))
SELECT * FROM l0 UNION ALL SELECT * FROM l1;
CREATE TEMP TABLE p3_cat_inci_row AS
WITH v AS (SELECT c.f1_value, m.lvl, m.row_id FROM craw c JOIN p3_cat_m m USING (raw_value))
SELECT DISTINCT v.f1_value, v.lvl, v.row_id FROM v
WHERE v.lvl = (SELECT min(v2.lvl) FROM v v2 WHERE v2.f1_value = v.f1_value);
CREATE TEMP TABLE p3_cat_map AS
SELECT DISTINCT r.f1_value, n.id_type, n.value, r.row_id IN (SELECT row_id FROM p3_cat_clean) AS clean
FROM p3_cat_inci_row r JOIN p3_cat_num n ON n.row_id = r.row_id AND n.check_ok;
CREATE INDEX ON p3_cat_map (f1_value);
ANALYZE p3_cat_map;

-- CosIng mappings (reference set 'all') with the INCI-level tier of their type, and whether all
-- supporting CosIng rows are fragrance-only.
CREATE TEMP TABLE p3_cs_map AS
SELECT m.f1_value, m.id_type, m.value, t.tier AS inci_tier, m.tier AS map_tier,
       NOT EXISTS (SELECT 1 FROM t_inci_row r JOIN cs_id i ON i.cosing_ref_no = r.cosing_ref_no AND i.id_type = m.id_type
                          AND i.value = m.value AND i.check_ok
                   JOIN cs ON cs.cosing_ref_no = r.cosing_ref_no
                   WHERE r.refset = 'all' AND r.f1_value = m.f1_value AND cs.in_excl_fragrance) AS fragrance_only
FROM t_map m JOIN t_inci t ON t.refset = m.refset AND t.id_type = m.id_type AND t.f1_value = m.f1_value
WHERE m.refset = 'all';
CREATE INDEX ON p3_cs_map (f1_value);
ANALYZE p3_cs_map;

-- Options and the candidate derived numbers per product (before the conflict rule).
CREATE TEMP TABLE p3_opt AS
SELECT * FROM (VALUES ('A', 1, ARRAY[]::text[], 'none'), ('B', 2, ARRAY['T1'], 'none'), ('C', 3, ARRAY['T1', 'T2'], 'none'),
                      ('D clean', 4, ARRAY['T1', 'T2'], 'clean'), ('D all', 5, ARRAY['T1', 'T2'], 'all'),
                      ('Ref C+T3', 6, ARRAY['T1', 'T2', 'T3'], 'none')) AS o(opt, ord, tiers, cat);
CREATE TEMP TABLE p3_cand AS
SELECT o.opt, i.product_id, i.value AS inci, m.id_type, m.value, 'CosIng' AS src, m.inci_tier AS tier, m.fragrance_only
FROM p3_opt o JOIN cov_id i ON i.id_type = 'INCI' JOIN p3_cs_map m ON m.f1_value = i.value AND m.inci_tier = ANY (o.tiers)
UNION ALL
SELECT o.opt, i.product_id, i.value, c.id_type, c.value, 'catalogue', CASE WHEN c.clean THEN 'clean' ELSE 'not clean' END, false
FROM p3_opt o JOIN cov_id i ON i.id_type = 'INCI' JOIN p3_cat_map c ON c.f1_value = i.value
WHERE o.cat = 'all' OR (o.cat = 'clean' AND c.clean);
CREATE INDEX ON p3_cand (opt, product_id, src);
ANALYZE p3_cand;

-- Conflict rule (CAS): product has Covalo CAS and the source's derived CAS do not overlap it.
CREATE TEMP TABLE p3_conflict AS
SELECT c.opt, c.product_id, c.src
FROM p3_cand c JOIN p3_prod p USING (product_id)
WHERE c.id_type = 'CAS' AND p.has_cas
GROUP BY 1, 2, 3
HAVING NOT bool_or(EXISTS (SELECT 1 FROM cov_id v WHERE v.product_id = c.product_id AND v.id_type = 'CAS' AND v.value = c.value));
CREATE INDEX ON p3_conflict (opt, product_id, src);

CREATE TEMP TABLE p3_deriv AS
SELECT c.*, NOT (c.id_type = 'CAS' AND EXISTS (SELECT 1 FROM p3_conflict x WHERE x.opt = c.opt AND x.product_id = c.product_id AND x.src = c.src)) AS used,
       EXISTS (SELECT 1 FROM cov_id v WHERE v.product_id = c.product_id AND v.id_type = c.id_type AND v.value = c.value) AS already_covalo
FROM p3_cand c;
CREATE INDEX ON p3_deriv (opt, product_id);
ANALYZE p3_deriv;

-- Hits: base (Covalo identifiers, every option) and derived (used, not already a Covalo value).
CREATE TEMP TABLE p3_hit AS
SELECT o.opt, i.product_id, x.logical_entry_id, i.id_type, i.value, 'Covalo' AS src, NULL::text AS tier, NULL::text AS inci,
       false AS fragrance_only
FROM p3_opt o JOIN cov_id i ON true JOIN p3_rx x ON x.id_type = i.id_type AND x.value = i.value
WHERE i.product_id IN (SELECT product_id FROM p3_prod)
UNION ALL
SELECT d.opt, d.product_id, x.logical_entry_id, d.id_type, d.value, d.src, d.tier, d.inci, d.fragrance_only
FROM p3_deriv d JOIN p3_rx x ON x.id_type = d.id_type AND x.value = d.value
WHERE d.used AND NOT d.already_covalo;
CREATE INDEX ON p3_hit (opt, product_id);
CREATE INDEX ON p3_hit (opt, logical_entry_id);
ANALYZE p3_hit;

CREATE TEMP TABLE p3_found AS
SELECT h.opt, h.product_id,
       bool_or(e.annex_type NOT IN ('EXEMPTION', 'INVENTORY_LISTED')) AS found_excl,
       count(DISTINCT h.logical_entry_id) AS entries,
       bool_and(h.src = 'Covalo') AS base_only
FROM p3_hit h JOIN p3_entry e USING (logical_entry_id) GROUP BY 1, 2;
CREATE INDEX ON p3_found (opt, product_id);
ANALYZE p3_found;

-- Gained products per option (found, not found in A) and the hits that make the gain.
CREATE TEMP TABLE p3_gain AS
SELECT h.* FROM p3_hit h
WHERE h.opt <> 'A' AND h.src <> 'Covalo'
  AND NOT EXISTS (SELECT 1 FROM p3_found a WHERE a.opt = 'A' AND a.product_id = h.product_id);
CREATE INDEX ON p3_gain (opt, product_id);
ANALYZE p3_gain;

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
FROM pick p ORDER BY 1;

-- o1. PROVISIONAL. Part 3 item 1: per option, products and distinct Covalo INCI found (any; excluding products / INCI that hit only EXEMPTION or INVENTORY_LISTED); shares of 112,649 active ingredient products and of the distinct Covalo INCI
SELECT o.opt,
       (SELECT count(*) FROM p3_found f WHERE f.opt = o.opt) AS products,
       round(100.0 * (SELECT count(*) FROM p3_found f WHERE f.opt = o.opt) / (SELECT count(*) FROM p3_prod), 1) AS pct_products,
       (SELECT count(*) FROM p3_found f WHERE f.opt = o.opt AND f.found_excl) AS products_excl,
       round(100.0 * (SELECT count(*) FROM p3_found f WHERE f.opt = o.opt AND f.found_excl) / (SELECT count(*) FROM p3_prod), 1) AS pct_products_excl,
       (SELECT count(*) FROM p3_found f WHERE f.opt = o.opt) - (SELECT count(*) FROM p3_found f WHERE f.opt = 'A') AS gain_products,
       (SELECT count(DISTINCT v) FROM (SELECT h.value AS v FROM p3_hit h WHERE h.opt = o.opt AND h.src = 'Covalo' AND h.id_type = 'INCI'
                                       UNION SELECT h.inci FROM p3_hit h WHERE h.opt = o.opt AND h.src <> 'Covalo') x) AS inci_found,
       (SELECT count(DISTINCT v) FROM (SELECT h.value AS v FROM p3_hit h JOIN p3_entry e USING (logical_entry_id)
                                        WHERE h.opt = o.opt AND h.src = 'Covalo' AND h.id_type = 'INCI' AND e.annex_type NOT IN ('EXEMPTION', 'INVENTORY_LISTED')
                                       UNION SELECT h.inci FROM p3_hit h JOIN p3_entry e USING (logical_entry_id)
                                        WHERE h.opt = o.opt AND h.src <> 'Covalo' AND e.annex_type NOT IN ('EXEMPTION', 'INVENTORY_LISTED')) x) AS inci_found_excl,
       (SELECT count(DISTINCT value) FROM cov_id WHERE id_type = 'INCI') AS covalo_inci_total,
       (SELECT count(*) FROM p3_prod) AS active_ingredient_products
FROM p3_opt o ORDER BY o.ord

-- o2. PROVISIONAL. Part 3 item 1: products found per annex or list (a product counts in every group it hits), per option
SELECT e.annex_group,
       count(DISTINCT h.product_id) FILTER (WHERE h.opt = 'A') AS a,
       count(DISTINCT h.product_id) FILTER (WHERE h.opt = 'B') AS b,
       count(DISTINCT h.product_id) FILTER (WHERE h.opt = 'C') AS c,
       count(DISTINCT h.product_id) FILTER (WHERE h.opt = 'D clean') AS d_clean,
       count(DISTINCT h.product_id) FILTER (WHERE h.opt = 'D all') AS d_all,
       count(DISTINCT h.product_id) FILTER (WHERE h.opt = 'Ref C+T3') AS ref_c_t3,
       bool_or(e.prints_inci) AS some_entries_print_inci
FROM p3_hit h JOIN p3_entry e USING (logical_entry_id) GROUP BY 1 ORDER BY 2 DESC, 1

-- o3. PROVISIONAL. Part 3 item 1: products found per scope class (docs/data-model/cosmetics-scope.md; REACH CMR appendices own group), per option
SELECT e.scope_class,
       count(DISTINCT h.product_id) FILTER (WHERE h.opt = 'A') AS a,
       count(DISTINCT h.product_id) FILTER (WHERE h.opt = 'B') AS b,
       count(DISTINCT h.product_id) FILTER (WHERE h.opt = 'C') AS c,
       count(DISTINCT h.product_id) FILTER (WHERE h.opt = 'D clean') AS d_clean,
       count(DISTINCT h.product_id) FILTER (WHERE h.opt = 'D all') AS d_all,
       count(DISTINCT h.product_id) FILTER (WHERE h.opt = 'Ref C+T3') AS ref_c_t3
FROM p3_hit h JOIN p3_entry e USING (logical_entry_id) GROUP BY 1 ORDER BY 1

-- o4. PROVISIONAL. Part 3 item 1: gained products (not found in A) by whether the entries reached print INCI; Annex II, Article 15 and CLP Annex VI Table 3 shown for entries printing no INCI
SELECT g.opt, count(DISTINCT g.product_id) AS gained,
       count(DISTINCT g.product_id) FILTER (WHERE NOT e.prints_inci) AS via_entry_printing_no_inci,
       count(DISTINCT g.product_id) FILTER (WHERE e.prints_inci) AS via_entry_printing_inci,
       count(DISTINCT g.product_id) FILTER (WHERE NOT e.prints_inci AND e.annex_ref = 'Annex II') AS no_inci_annex_ii,
       count(DISTINCT g.product_id) FILTER (WHERE NOT e.prints_inci AND e.annex_ref IN ('Article 15(1)', 'Article 15(2)')) AS no_inci_article_15,
       count(DISTINCT g.product_id) FILTER (WHERE NOT e.prints_inci AND e.annex_ref = 'Annex VI Table 3') AS no_inci_clp_vi,
       count(DISTINCT g.product_id) FILTER (WHERE e.annex_type NOT IN ('EXEMPTION', 'INVENTORY_LISTED')) AS gained_excl
FROM p3_gain g JOIN p3_entry e USING (logical_entry_id) JOIN p3_opt o USING (opt)
GROUP BY g.opt, o.ord ORDER BY o.ord

-- o5. PROVISIONAL. Part 3 item 1: products found and gained by single-INCI, blend (several INCI), no INCI
WITH k AS (SELECT product_id, CASE WHEN n_inci = 0 THEN 'no INCI' WHEN n_inci = 1 THEN 'single INCI' ELSE 'blend' END AS kind FROM p3_prod)
SELECT o.opt, k.kind,
       count(*) AS found, count(*) FILTER (WHERE f.found_excl) AS found_excl,
       count(*) FILTER (WHERE NOT EXISTS (SELECT 1 FROM p3_found a WHERE a.opt = 'A' AND a.product_id = f.product_id)) AS gained,
       (SELECT count(*) FROM k k2 WHERE k2.kind = k.kind) AS all_products_of_kind
FROM p3_found f JOIN k USING (product_id) JOIN p3_opt o USING (opt)
GROUP BY o.opt, o.ord, k.kind ORDER BY o.ord, k.kind

-- o6. PROVISIONAL. Part 3 item 1: gained products whose gain rests only on CosIng numbers from fragrance-only rows (one line per option)
SELECT g.opt, count(DISTINCT g.product_id) AS gained,
       count(DISTINCT g.product_id) FILTER (WHERE NOT EXISTS (
           SELECT 1 FROM p3_gain g2 WHERE g2.opt = g.opt AND g2.product_id = g.product_id
             AND NOT (g2.src = 'CosIng' AND g2.fragrance_only))) AS gain_only_via_fragrance_only_rows
FROM p3_gain g JOIN p3_opt o USING (opt) GROUP BY g.opt, o.ord ORDER BY o.ord

-- o7. PROVISIONAL. Part 3 item 2: fan-out per option: products hitting more than 10 entries (all found; gained)
SELECT f.opt, count(*) FILTER (WHERE f.entries > 10) AS products_over_10_entries,
       count(*) FILTER (WHERE f.entries > 10 AND NOT EXISTS (SELECT 1 FROM p3_found a WHERE a.opt = 'A' AND a.product_id = f.product_id)) AS gained_over_10_entries,
       max(f.entries) AS max_entries
FROM p3_found f JOIN p3_opt o USING (opt) GROUP BY f.opt, o.ord ORDER BY o.ord

-- o8. PROVISIONAL. Part 3 item 2: the 20 entries with the most gained products per option (entry scope, annex, most frequent number used, its source and tier)
SELECT x.opt, x.logical_entry_id, e.entry_scope, e.annex_ref, e.entry_ref, e.annex_type, x.products,
       (SELECT g.id_type || ' ' || g.value || ' (' || g.src || ' ' || g.tier || ', ' || count(DISTINCT g.product_id) || ')'
          FROM p3_gain g WHERE g.opt = x.opt AND g.logical_entry_id = x.logical_entry_id
         GROUP BY g.id_type, g.value, g.src, g.tier ORDER BY count(DISTINCT g.product_id) DESC, g.value LIMIT 1) AS top_number_used
FROM (SELECT g.opt, g.logical_entry_id, count(DISTINCT g.product_id) AS products,
             row_number() OVER (PARTITION BY g.opt ORDER BY count(DISTINCT g.product_id) DESC, g.logical_entry_id) AS rn
      FROM p3_gain g GROUP BY 1, 2) x
JOIN p3_entry e USING (logical_entry_id) JOIN p3_opt o ON o.opt = x.opt
WHERE x.rn <= 20 ORDER BY o.ord, x.products DESC

-- o8b. PROVISIONAL. Part 3 item 2: for C and D all, the 10 derived numbers with the most gained products, the Covalo INCI they come from, entries reached and how the entries carry the number
SELECT x.opt, x.id_type, x.value, x.src, x.tier, x.products, x.entries,
       (SELECT string_agg(i || ' (' || n || ')', ' | ') FROM (SELECT g.inci AS i, count(DISTINCT g.product_id) AS n FROM p3_gain g
          WHERE g.opt = x.opt AND g.id_type = x.id_type AND g.value = x.value GROUP BY 1 ORDER BY 2 DESC, 1 LIMIT 3) y) AS covalo_inci,
       (SELECT string_agg(DISTINCT r.provenance, ', ') FROM rx_id r WHERE r.id_type = x.id_type AND r.value = x.value) AS replay_provenance
FROM (SELECT g.opt, g.id_type, g.value, g.src, g.tier, count(DISTINCT g.product_id) AS products, count(DISTINCT g.logical_entry_id) AS entries,
             row_number() OVER (PARTITION BY g.opt ORDER BY count(DISTINCT g.product_id) DESC, g.value) AS rn
      FROM p3_gain g WHERE g.opt IN ('C', 'D all') GROUP BY 1, 2, 3, 4, 5) x
WHERE x.rn <= 10 ORDER BY x.opt, x.products DESC

-- o9. PROVISIONAL. Part 3 item 3: the 1,209 CosIng CAS conflicts by group, with replay hit status of Covalo CAS vs CosIng CAS
WITH c AS (
    SELECT b.product_id,
           EXISTS (SELECT 1 FROM cov_id v WHERE v.product_id = b.product_id AND v.id_type = 'CAS' AND NOT v.check_ok) AS cov_check_fail,
           EXISTS (SELECT 1 FROM cov_id v JOIN cs_id s ON s.id_type = 'CAS' AND s.value = v.value AND s.check_ok
                   WHERE v.product_id = b.product_id AND v.id_type = 'CAS') AS cov_on_other_cosing_inci,
           EXISTS (SELECT 1 FROM cov_id v JOIN p3_rx x ON x.id_type = 'CAS' AND x.value = v.value
                   WHERE v.product_id = b.product_id AND v.id_type = 'CAS') AS cov_hits,
           EXISTS (SELECT 1 FROM prod_cs_id s JOIN p3_rx x ON x.id_type = 'CAS' AND x.value = s.value
                   WHERE s.refset = 'all' AND s.product_id = b.product_id AND s.id_type = 'CAS' AND s.check_ok) AS cs_hits,
           ARRAY(SELECT DISTINCT x.logical_entry_id FROM cov_id v JOIN p3_rx x ON x.id_type = 'CAS' AND x.value = v.value
                  WHERE v.product_id = b.product_id AND v.id_type = 'CAS' ORDER BY 1) AS cov_entries,
           ARRAY(SELECT DISTINCT x.logical_entry_id FROM prod_cs_id s JOIN p3_rx x ON x.id_type = 'CAS' AND x.value = s.value
                  WHERE s.refset = 'all' AND s.product_id = b.product_id AND s.id_type = 'CAS' AND s.check_ok ORDER BY 1) AS cs_entries
    FROM bridge b WHERE b.refset = 'all' AND b.id_type = 'CAS' AND b.cls = 'conflict')
SELECT CASE WHEN cov_check_fail THEN 'a Covalo CAS fails the check digit'
            WHEN cov_on_other_cosing_inci THEN 'b Covalo CAS sits on a different CosIng INCI' ELSE 'c other' END AS grp,
       count(*) AS products,
       count(*) FILTER (WHERE cov_hits <> cs_hits) AS hit_status_differs,
       count(*) FILTER (WHERE cov_hits AND NOT cs_hits) AS only_covalo_cas_hits,
       count(*) FILTER (WHERE cs_hits AND NOT cov_hits) AS only_cosing_cas_hits,
       count(*) FILTER (WHERE cov_hits AND cs_hits AND cov_entries <> cs_entries) AS both_hit_different_entries,
       count(*) FILTER (WHERE NOT cov_hits AND NOT cs_hits) AS neither_hits
FROM c GROUP BY 1 ORDER BY 1

-- o9b. PROVISIONAL. Part 3 item 3: 10 examples per group where the hit status differs (Covalo CAS, CosIng CAS, entries hit)
WITH c AS (
    SELECT b.product_id,
           EXISTS (SELECT 1 FROM cov_id v WHERE v.product_id = b.product_id AND v.id_type = 'CAS' AND NOT v.check_ok) AS cov_check_fail,
           EXISTS (SELECT 1 FROM cov_id v JOIN cs_id s ON s.id_type = 'CAS' AND s.value = v.value AND s.check_ok
                   WHERE v.product_id = b.product_id AND v.id_type = 'CAS') AS cov_on_other_cosing_inci,
           (SELECT string_agg(DISTINCT v.value, ' | ') FROM cov_id v WHERE v.product_id = b.product_id AND v.id_type = 'CAS') AS covalo_cas,
           (SELECT string_agg(DISTINCT s.value, ' | ') FROM prod_cs_id s WHERE s.refset = 'all' AND s.product_id = b.product_id
              AND s.id_type = 'CAS' AND s.check_ok) AS cosing_cas,
           (SELECT string_agg(DISTINCT e.annex_ref || ' ' || e.entry_ref, ' | ') FROM cov_id v JOIN p3_rx x ON x.id_type = 'CAS' AND x.value = v.value
              JOIN p3_entry e USING (logical_entry_id) WHERE v.product_id = b.product_id AND v.id_type = 'CAS') AS covalo_cas_entries,
           (SELECT string_agg(DISTINCT e.annex_ref || ' ' || e.entry_ref, ' | ') FROM prod_cs_id s JOIN p3_rx x ON x.id_type = 'CAS' AND x.value = s.value
              JOIN p3_entry e USING (logical_entry_id) WHERE s.refset = 'all' AND s.product_id = b.product_id AND s.id_type = 'CAS' AND s.check_ok) AS cosing_cas_entries,
           (SELECT string_agg(DISTINCT v.value, ' | ') FROM cov_id v WHERE v.product_id = b.product_id AND v.id_type = 'INCI') AS covalo_inci
    FROM bridge b WHERE b.refset = 'all' AND b.id_type = 'CAS' AND b.cls = 'conflict'),
g AS (SELECT c.*, CASE WHEN cov_check_fail THEN 'a' WHEN cov_on_other_cosing_inci THEN 'b' ELSE 'c' END AS grp,
             row_number() OVER (PARTITION BY CASE WHEN cov_check_fail THEN 'a' WHEN cov_on_other_cosing_inci THEN 'b' ELSE 'c' END
                                ORDER BY md5('20261023' || product_id)) AS rn
      FROM c WHERE (covalo_cas_entries IS NULL) <> (cosing_cas_entries IS NULL))
SELECT grp, product_id, left(covalo_inci, 80) AS covalo_inci, covalo_cas, cosing_cas, left(covalo_cas_entries, 160) AS covalo_cas_entries,
       left(cosing_cas_entries, 160) AS cosing_cas_entries
FROM g WHERE rn <= 10 ORDER BY grp, rn

-- o9c. PROVISIONAL. Part 3 item 3: derived-number conflicts with Covalo per source (products; CAS rule applied, EC only counted)
SELECT x.opt, x.src, count(DISTINCT x.product_id) AS cas_conflict_products,
       (SELECT count(DISTINCT c.product_id) FROM p3_cand c JOIN cov_id v ON v.product_id = c.product_id AND v.id_type = 'EC'
         WHERE c.opt = x.opt AND c.src = x.src AND c.id_type = 'EC'
           AND NOT EXISTS (SELECT 1 FROM p3_cand c2 JOIN cov_id v2 ON v2.product_id = c2.product_id AND v2.id_type = 'EC' AND v2.value = c2.value
                           WHERE c2.opt = c.opt AND c2.src = c.src AND c2.product_id = c.product_id AND c2.id_type = 'EC')) AS ec_conflict_products
FROM p3_conflict x JOIN p3_opt o USING (opt) GROUP BY x.opt, o.ord, x.src ORDER BY o.ord, x.src

-- o10. PROVISIONAL. Part 3 item 4: catalogue rows, check-digit failures excluded, clean rows
SELECT (SELECT count(*) FROM kevin.relayx_eu_identifiers_v2) AS catalogue_rows,
       (SELECT count(DISTINCT value) FROM p3_cat_num WHERE id_type = 'CAS' AND NOT check_ok) AS cas_values_failing,
       (SELECT count(DISTINCT value) FROM p3_cat_num WHERE id_type = 'EC' AND NOT check_ok) AS ec_values_failing,
       (SELECT count(DISTINCT row_id) FROM p3_cat_num WHERE id_type = 'CAS' AND check_ok) AS rows_with_valid_cas,
       (SELECT count(*) FROM p3_cat_clean) AS clean_rows,
       (SELECT count(DISTINCT f1_value) FROM p3_cat_inci_row) AS covalo_inci_matched_l0_l1,
       (SELECT count(DISTINCT f1_value) FROM p3_cat_inci_row WHERE lvl = 0) AS at_l0

-- o10b. PROVISIONAL. Part 3 item 4: Covalo INCI and products gaining a CAS through the catalogue (Covalo has none), clean and all, and overlap with CosIng T1 / T2
WITH ci AS (SELECT DISTINCT f1_value, bool_or(clean) OVER (PARTITION BY f1_value) AS any_clean FROM p3_cat_map WHERE id_type = 'CAS'),
cs12 AS (SELECT DISTINCT f1_value FROM p3_cs_map WHERE id_type = 'CAS' AND inci_tier IN ('T1', 'T2')),
gp AS (SELECT DISTINCT i.product_id, i.value AS inci, ci.any_clean FROM cov_id i JOIN ci ON ci.f1_value = i.value
       JOIN p3_prod p USING (product_id) WHERE i.id_type = 'INCI' AND NOT p.has_cas)
SELECT m.mode,
       (SELECT count(DISTINCT f1_value) FROM ci WHERE m.mode = 'all' OR any_clean) AS inci_with_catalogue_cas,
       (SELECT count(DISTINCT f1_value) FROM ci WHERE (m.mode = 'all' OR any_clean) AND f1_value IN (SELECT f1_value FROM cs12)) AS inci_also_cosing_t1_t2,
       (SELECT count(DISTINCT f1_value) FROM ci WHERE (m.mode = 'all' OR any_clean) AND f1_value NOT IN (SELECT f1_value FROM cs12)) AS inci_catalogue_only,
       (SELECT count(DISTINCT product_id) FROM gp WHERE m.mode = 'all' OR any_clean) AS products_gaining_cas,
       (SELECT count(DISTINCT product_id) FROM gp WHERE (m.mode = 'all' OR any_clean) AND inci IN (SELECT f1_value FROM cs12)) AS products_also_cosing_t1_t2,
       (SELECT count(DISTINCT product_id) FROM gp g WHERE (m.mode = 'all' OR any_clean)
          AND NOT EXISTS (SELECT 1 FROM gp g2 WHERE g2.product_id = g.product_id AND g2.inci IN (SELECT f1_value FROM cs12))) AS products_catalogue_only
FROM (VALUES ('clean'), ('all')) AS m(mode)

-- o10c. PROVISIONAL. Part 3 item 4: CAS agreement where CosIng (T1, T2) and the catalogue both give a CAS for the same Covalo INCI
WITH x AS (
    SELECT c.f1_value,
           bool_or(EXISTS (SELECT 1 FROM p3_cs_map s WHERE s.f1_value = c.f1_value AND s.id_type = 'CAS' AND s.inci_tier IN ('T1', 'T2') AND s.value = c.value)) AS overlap_all,
           bool_or(c.clean AND EXISTS (SELECT 1 FROM p3_cs_map s WHERE s.f1_value = c.f1_value AND s.id_type = 'CAS' AND s.inci_tier IN ('T1', 'T2') AND s.value = c.value)) AS overlap_clean,
           bool_or(c.clean) AS any_clean
    FROM p3_cat_map c WHERE c.id_type = 'CAS'
      AND c.f1_value IN (SELECT f1_value FROM p3_cs_map WHERE id_type = 'CAS' AND inci_tier IN ('T1', 'T2'))
    GROUP BY 1)
SELECT count(*) AS inci_both_all, count(*) FILTER (WHERE overlap_all) AS agree_all, count(*) FILTER (WHERE NOT overlap_all) AS conflict_all,
       count(*) FILTER (WHERE any_clean) AS inci_both_clean, count(*) FILTER (WHERE any_clean AND overlap_clean) AS agree_clean,
       count(*) FILTER (WHERE any_clean AND NOT overlap_clean) AS conflict_clean
FROM x

-- o10d. PROVISIONAL. Part 3 item 4: 10 CAS conflicts between CosIng (T1, T2) and the catalogue (most products first)
SELECT c.f1_value AS covalo_inci, (SELECT products FROM cov_val v WHERE v.id_type = 'INCI' AND v.value = c.f1_value) AS products,
       (SELECT string_agg(DISTINCT s.value || ' ' || s.inci_tier, ' | ') FROM p3_cs_map s WHERE s.f1_value = c.f1_value AND s.id_type = 'CAS'
          AND s.inci_tier IN ('T1', 'T2')) AS cosing_cas,
       string_agg(DISTINCT c.value || CASE WHEN c.clean THEN ' clean' ELSE '' END, ' | ') AS catalogue_cas
FROM p3_cat_map c
WHERE c.id_type = 'CAS' AND c.f1_value IN (SELECT f1_value FROM p3_cs_map WHERE id_type = 'CAS' AND inci_tier IN ('T1', 'T2'))
GROUP BY c.f1_value
HAVING NOT bool_or(EXISTS (SELECT 1 FROM p3_cs_map s WHERE s.f1_value = c.f1_value AND s.id_type = 'CAS' AND s.inci_tier IN ('T1', 'T2') AND s.value = c.value))
ORDER BY 2 DESC, 1 LIMIT 10

-- o10e. PROVISIONAL. Part 3 item 4: Covalo INCI not found in CosIng at all (any level, all rows) but found among the catalogue names (L0 to L1)
SELECT count(DISTINCT r.f1_value) AS inci,
       (SELECT count(DISTINCT r2.f1_value) FROM p3_cat_inci_row r2 JOIN val_lvl v2 ON v2.refset = 'all' AND v2.f1_value = r2.f1_value AND v2.lvl IS NULL
          WHERE EXISTS (SELECT 1 FROM p3_cat_map m WHERE m.f1_value = r2.f1_value AND m.id_type = 'CAS')) AS with_catalogue_cas,
       (SELECT sum(c.products) FROM cov_val c WHERE c.id_type = 'INCI' AND c.value IN
          (SELECT r3.f1_value FROM p3_cat_inci_row r3 JOIN val_lvl v3 ON v3.refset = 'all' AND v3.f1_value = r3.f1_value AND v3.lvl IS NULL)) AS product_links
FROM p3_cat_inci_row r JOIN val_lvl v ON v.refset = 'all' AND v.f1_value = r.f1_value AND v.lvl IS NULL

-- o10f. PROVISIONAL. Part 3 item 4: 10 examples (most products first) of Covalo INCI not in CosIng but in the catalogue, with level and catalogue CAS
SELECT r.f1_value AS covalo_inci, min(r.lvl) AS level, (SELECT products FROM cov_val c WHERE c.id_type = 'INCI' AND c.value = r.f1_value) AS products,
       (SELECT string_agg(DISTINCT m.value || CASE WHEN m.clean THEN ' clean' ELSE '' END, ' | ') FROM p3_cat_map m
         WHERE m.f1_value = r.f1_value AND m.id_type = 'CAS') AS catalogue_cas
FROM p3_cat_inci_row r JOIN val_lvl v ON v.refset = 'all' AND v.f1_value = r.f1_value AND v.lvl IS NULL
GROUP BY r.f1_value ORDER BY 3 DESC NULLS LAST, 1 LIMIT 10

-- o11. PROVISIONAL. Part 3 item 5: lookup sizing per option: derived numbers used that are not F1 Covalo values, replay identifiers or catalogue values
SELECT o.opt, count(DISTINCT (d.id_type, d.value)) FILTER (WHERE d.value IS NOT NULL) AS new_values,
       count(DISTINCT (d.id_type, d.value)) FILTER (WHERE d.id_type = 'CAS') AS new_cas,
       count(DISTINCT (d.id_type, d.value)) FILTER (WHERE d.id_type = 'EC') AS new_ec,
       round(count(DISTINCT (d.id_type, d.value)) FILTER (WHERE d.value IS NOT NULL) / 3600.0, 2) AS hours_at_60_per_minute
FROM p3_opt o LEFT JOIN p3_deriv d ON d.opt = o.opt AND d.used AND NOT d.already_covalo
  AND NOT EXISTS (SELECT 1 FROM cov_val v WHERE v.id_type = d.id_type AND v.value = d.value)
  AND NOT EXISTS (SELECT 1 FROM rx_val r WHERE r.id_type = d.id_type AND r.value = d.value)
  AND NOT EXISTS (SELECT 1 FROM cat_val c WHERE c.id_type = d.id_type AND c.value = d.value)
GROUP BY o.opt, o.ord ORDER BY o.ord

-- o12. PROVISIONAL. Part 3 item 6: dictionary rows (distinct Covalo INCI to number pairs) per source and tier
SELECT 'CosIng' AS src, inci_tier AS tier, count(*) FILTER (WHERE id_type = 'CAS') AS cas_pairs, count(*) FILTER (WHERE id_type = 'EC') AS ec_pairs,
       count(DISTINCT f1_value) AS inci
FROM (SELECT DISTINCT f1_value, id_type, value, inci_tier FROM p3_cs_map) x GROUP BY 1, 2
UNION ALL
SELECT 'catalogue', CASE WHEN clean THEN 'clean' ELSE 'not clean' END, count(*) FILTER (WHERE id_type = 'CAS'), count(*) FILTER (WHERE id_type = 'EC'),
       count(DISTINCT f1_value)
FROM (SELECT DISTINCT f1_value, id_type, value, clean FROM p3_cat_map) x GROUP BY 1, 2
ORDER BY 1, 2

-- o13. PROVISIONAL. Part 3 check: option A equals the F1 replay match (24,677)
SELECT (SELECT count(*) FROM p3_found WHERE opt = 'A') AS option_a_products,
       (SELECT count(DISTINCT i.product_id) FROM cov_id i JOIN cov_val v USING (id_type, value) WHERE v.in_replay) AS f1_replay_match
