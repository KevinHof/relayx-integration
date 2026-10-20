-- PROVISIONAL. Fast-track F step 1: pre-signing matching assessment (docs/roadmap.md).
-- Not the phase 8 matching model. Creates TEMP objects only (pg_temp); nothing persists.
-- Run as relayx_app: python -m relayx.provisional_report sql/provisional/f1_matching_assessment.sql
-- Sections after the "-- REPORT" marker are run one by one and printed.
--
-- Provisional rules:
--   Covalo products: not trashed, enabled, company not trashed (as kevin.product_identifiers).
--   Covalo identifiers: product.identifiers arrays cas, ec, inci, iupac (iupac = NAME).
--   CAS / EC: every CAS- or EC-shaped token in a value is extracted (multi-value strings,
--     en dashes, spaces around hyphens, positional markers [n]); check digits are verified and
--     reported, but format-valid tokens with a failing check digit are kept for matching.
--   INCI: trimmed, upper case, whitespace collapsed. NAME: same, lower case.
--   Relay X entries: every version of every entry that has no RETRACTED row (15,058 entries);
--     the current-version rule is open (Q10), identifiers rarely differ between versions.
--   Relay X provenance: literal = entry `identifiers` + linkedSubstances values with
--     printedByText true; enriched = linkedSubstances values with printedByText false +
--     `nomenclature` (inciEu, inciUs, inciIecic, chemicalName, synonyms, colourIndex).

-- Helpers ------------------------------------------------------------------------------

CREATE FUNCTION pg_temp.prep(t text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT regexp_replace(translate(t, E'–—‐‑−', '-----'), '\s*-\s*', '-', 'g')
$$;

CREATE FUNCTION pg_temp.cas_ok(t text) RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
    SELECT t ~ '^\d{2,7}-\d{2}-\d$' AND
           (SELECT sum(d::int * w) FROM regexp_split_to_table(reverse(left(replace(t, '-', ''), -1)), '')
                    WITH ORDINALITY AS x(d, w)) % 10 = right(t, 1)::int
$$;

CREATE FUNCTION pg_temp.ec_ok(t text) RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
    SELECT t ~ '^\d{3}-\d{3}-\d$' AND
           (SELECT sum(d::int * w) FROM regexp_split_to_table(left(replace(t, '-', ''), 6), '')
                    WITH ORDINALITY AS x(d, w)) % 11 = right(t, 1)::int
$$;

CREATE FUNCTION pg_temp.tokens(t text, kind text) RETURNS SETOF text LANGUAGE sql IMMUTABLE AS $$
    SELECT m[1] FROM regexp_matches(pg_temp.prep(t),
        CASE kind WHEN 'CAS' THEN '(?<!\d)(\d{2,7}-\d{2}-\d)(?!\d)'
                  ELSE '(?<!\d)(\d{3}-\d{3}-\d)(?!\d)' END, 'g') AS m
$$;

-- What is left of a CAS/EC string after removing tokens, [n] markers, separators and
-- connecting words. Empty = fully parsed.
CREATE FUNCTION pg_temp.residual(t text, kind text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT regexp_replace(regexp_replace(regexp_replace(pg_temp.prep(t),
        CASE kind WHEN 'CAS' THEN '(?<!\d)\d{2,7}-\d{2}-\d(?!\d)' ELSE '(?<!\d)\d{3}-\d{3}-\d(?!\d)' END, '', 'g'),
        '\[\d+\]', '', 'g'),
        '[\s;,/|&+.()\-]|\m(and|or|oder|und|et)\M', '', 'gi')
$$;

CREATE FUNCTION pg_temp.norm_inci(t text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT nullif(upper(regexp_replace(btrim(t), '\s+', ' ', 'g')), '')
$$;

CREATE FUNCTION pg_temp.norm_name(t text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT nullif(lower(regexp_replace(btrim(t), '\s+', ' ', 'g')), '')
$$;

-- Covalo side -------------------------------------------------------------------------

CREATE TEMP TABLE cov_product AS
SELECT p.id AS product_id, p.type AS product_type, p.segment
FROM covalo.product p JOIN covalo.company c ON c.id = p.company
WHERE NOT p.trashed AND p.enabled AND NOT c.trashed;

-- One row per raw array element.
CREATE TEMP TABLE cov_raw AS
SELECT cp.product_id, k.id_type, e #>> '{}' AS raw_value
FROM cov_product cp
JOIN covalo.product p ON p.id = cp.product_id
CROSS JOIN (VALUES ('cas', 'CAS'), ('ec', 'EC'), ('inci', 'INCI'), ('iupac', 'NAME')) AS k(key, id_type)
CROSS JOIN LATERAL jsonb_array_elements(
    CASE WHEN jsonb_typeof(p.identifiers -> k.key) = 'array' THEN p.identifiers -> k.key ELSE '[]' END) AS e
WHERE jsonb_typeof(e) = 'string';
CREATE INDEX ON cov_raw (product_id);

CREATE TEMP TABLE cov_id AS
SELECT DISTINCT r.product_id, r.id_type, t.value,
       CASE r.id_type WHEN 'CAS' THEN pg_temp.cas_ok(t.value) WHEN 'EC' THEN pg_temp.ec_ok(t.value) END AS check_ok
FROM cov_raw r
CROSS JOIN LATERAL pg_temp.tokens(r.raw_value, r.id_type) AS t(value)
WHERE r.id_type IN ('CAS', 'EC')
UNION
SELECT DISTINCT r.product_id, r.id_type,
       CASE r.id_type WHEN 'INCI' THEN pg_temp.norm_inci(r.raw_value) ELSE pg_temp.norm_name(r.raw_value) END, NULL::boolean
FROM cov_raw r
WHERE r.id_type IN ('INCI', 'NAME')
  AND CASE r.id_type WHEN 'INCI' THEN pg_temp.norm_inci(r.raw_value) ELSE pg_temp.norm_name(r.raw_value) END IS NOT NULL;
CREATE INDEX ON cov_id (id_type, value);
CREATE INDEX ON cov_id (product_id);
ANALYZE cov_product;
ANALYZE cov_raw;
ANALYZE cov_id;

-- Relay X replay side -----------------------------------------------------------------

CREATE TEMP TABLE rx_entry AS
SELECT ev.logical_entry_id,
       ev.payload ->> 'annexType' AS annex_type,
       ev.payload ->> 'entryScope' AS entry_scope,
       jsonb_build_object('identifiers', ev.payload -> 'identifiers',
                          'linkedSubstances', ev.payload -> 'linkedSubstances',
                          'nomenclature', ev.payload -> 'nomenclature') AS payload
FROM relayx_raw.entry_version ev
WHERE ev.logical_entry_id NOT IN (SELECT logical_entry_id FROM relayx_raw.entry_version WHERE change_kind = 'RETRACTED');

-- Printed strings in `identifiers`, for parse statistics and literal values.
CREATE TEMP TABLE rx_printed AS
SELECT DISTINCT e.logical_entry_id, f.id_type, f.raw_value
FROM rx_entry e
CROSS JOIN LATERAL (VALUES
    ('CAS', e.payload -> 'identifiers' ->> 'cas'),
    ('EC', e.payload -> 'identifiers' ->> 'ec'),
    ('INCI', e.payload -> 'identifiers' ->> 'inci'),
    ('NAME', e.payload -> 'identifiers' ->> 'name'),
    ('NAME', e.payload -> 'identifiers' ->> 'nameEn'),
    ('CLP_INDEX', e.payload -> 'identifiers' ->> 'clpIndex'),
    ('COLOUR_INDEX', e.payload -> 'identifiers' ->> 'colourIndex')) AS f(id_type, raw_value)
WHERE f.raw_value IS NOT NULL;

CREATE TEMP TABLE rx_id AS
-- literal: CAS / EC tokens from printed strings
SELECT p.logical_entry_id, p.id_type, t.value, 'literal' AS provenance
FROM rx_printed p CROSS JOIN LATERAL pg_temp.tokens(p.raw_value, p.id_type) AS t(value)
WHERE p.id_type IN ('CAS', 'EC')
UNION
-- literal: list fields
SELECT e.logical_entry_id, l.id_type, CASE WHEN l.id_type = 'INCI' THEN pg_temp.norm_inci(v #>> '{}') ELSE v #>> '{}' END, 'literal'
FROM rx_entry e
CROSS JOIN (VALUES ('casList', 'CAS'), ('ecList', 'EC'), ('inciList', 'INCI')) AS l(key, id_type)
CROSS JOIN LATERAL jsonb_array_elements(
    CASE WHEN jsonb_typeof(e.payload -> 'identifiers' -> l.key) = 'array' THEN e.payload -> 'identifiers' -> l.key ELSE '[]' END) AS v
UNION
-- literal: INCI and NAME strings split on [n] markers and semicolons
SELECT p.logical_entry_id, p.id_type,
       CASE p.id_type WHEN 'INCI' THEN pg_temp.norm_inci(s) ELSE pg_temp.norm_name(s) END, 'literal'
FROM rx_printed p CROSS JOIN LATERAL regexp_split_to_table(p.raw_value, '\s*\[\d+\]\s*|;') AS s
WHERE p.id_type IN ('INCI', 'NAME')
UNION
SELECT p.logical_entry_id, p.id_type, pg_temp.norm_inci(p.raw_value), 'literal'
FROM rx_printed p WHERE p.id_type IN ('CLP_INDEX', 'COLOUR_INDEX')
UNION
-- linkedSubstances
SELECT e.logical_entry_id,
       CASE WHEN i ->> 'type' IN ('LOCAL_NAME', 'SYNONYM') THEN 'NAME' ELSE i ->> 'type' END,
       CASE WHEN i ->> 'type' IN ('LOCAL_NAME', 'SYNONYM') THEN pg_temp.norm_name(i ->> 'value')
            WHEN i ->> 'type' IN ('CAS', 'EC') THEN pg_temp.prep(btrim(i ->> 'value'))
            ELSE pg_temp.norm_inci(i ->> 'value') END,
       CASE WHEN (i ->> 'printedByText')::boolean THEN 'literal' ELSE 'enriched' END
FROM rx_entry e
CROSS JOIN LATERAL jsonb_array_elements(
    CASE WHEN jsonb_typeof(e.payload -> 'linkedSubstances') = 'array' THEN e.payload -> 'linkedSubstances' ELSE '[]' END) AS ls
CROSS JOIN LATERAL jsonb_array_elements(
    CASE WHEN jsonb_typeof(ls -> 'identifiers') = 'array' THEN ls -> 'identifiers' ELSE '[]' END) AS i
UNION
-- nomenclature (enriched)
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
DELETE FROM rx_id WHERE value IS NULL;
CREATE INDEX ON rx_id (id_type, value);
ANALYZE rx_id;

-- Distinct values per type with best provenance (literal wins).
CREATE TEMP TABLE rx_val AS
SELECT id_type, value, bool_or(provenance = 'literal') AS has_literal, count(DISTINCT logical_entry_id) AS entries
FROM rx_id GROUP BY id_type, value;
CREATE UNIQUE INDEX ON rx_val (id_type, value);

-- Relay X identifier catalogue --------------------------------------------------------

CREATE TEMP TABLE cat_val AS
SELECT DISTINCT 'CAS' AS id_type, t.value FROM kevin.relayx_eu_identifiers_v2 c
    CROSS JOIN LATERAL pg_temp.tokens(c.cas_number, 'CAS') AS t(value)
UNION
SELECT DISTINCT 'EC', t.value FROM kevin.relayx_eu_identifiers_v2 c
    CROSS JOIN LATERAL pg_temp.tokens(c.ec_number, 'EC') AS t(value)
UNION
SELECT DISTINCT 'INCI', pg_temp.norm_inci(s) FROM kevin.relayx_eu_identifiers_v2 c
    CROSS JOIN LATERAL regexp_split_to_table(c.inci_name, '\s*\|\s*') AS s
UNION
SELECT DISTINCT 'INCI', pg_temp.norm_inci(s) FROM kevin.relayx_eu_identifiers_v2 c
    CROSS JOIN LATERAL regexp_split_to_table(c.inci_name_us, '\s*\|\s*') AS s
UNION
SELECT DISTINCT 'NAME', pg_temp.norm_name(c.substance_name) FROM kevin.relayx_eu_identifiers_v2 c;
DELETE FROM cat_val WHERE value IS NULL;
CREATE UNIQUE INDEX ON cat_val (id_type, value);
ANALYZE cat_val;

-- Covalo distinct values with overlap flags.
CREATE TEMP TABLE cov_val AS
SELECT v.id_type, v.value, v.check_ok, v.products,
       r.value IS NOT NULL AS in_replay,
       coalesce(r.has_literal, false) AS in_replay_literal,
       c.value IS NOT NULL AS in_catalogue
FROM (SELECT id_type, value, bool_and(check_ok) AS check_ok, count(DISTINCT product_id) AS products
      FROM cov_id GROUP BY id_type, value) v
LEFT JOIN rx_val r USING (id_type, value)
LEFT JOIN cat_val c USING (id_type, value);
ANALYZE cov_val;
ANALYZE rx_val;

-- One row per product: usable-identifier flag (for a1).
CREATE TEMP TABLE cov_product_flags AS
SELECT cp.product_id, cp.product_type,
       EXISTS (SELECT 1 FROM cov_id i WHERE i.product_id = cp.product_id) AS has_usable,
       EXISTS (SELECT 1 FROM cov_raw r WHERE r.product_id = cp.product_id) AS has_raw
FROM cov_product cp;

-- REPORT

-- a1. Active Covalo products by type, with and without a usable identifier
SELECT product_type, count(*) AS products,
       count(*) FILTER (WHERE has_usable) AS with_usable_id,
       count(*) FILTER (WHERE NOT has_usable) AS without_usable_id,
       count(*) FILTER (WHERE NOT has_raw) AS without_any_raw_id
FROM cov_product_flags GROUP BY ROLLUP (product_type) ORDER BY 1 NULLS LAST;

-- a2. Covalo distinct usable identifiers by type, products carrying them, check digits
SELECT id_type, count(*) AS distinct_values, sum(products) AS product_links,
       count(*) FILTER (WHERE check_ok IS FALSE) AS check_digit_fail
FROM cov_val GROUP BY id_type ORDER BY 1;

-- a3. Covalo raw CAS / EC elements: parse outcome
SELECT id_type,
       count(*) AS raw_elements,
       count(*) FILTER (WHERE n_tok = 1 AND res = '') AS single_clean,
       count(*) FILTER (WHERE n_tok > 1 AND res = '') AS multi_clean,
       count(*) FILTER (WHERE n_tok > 0 AND res <> '') AS tokens_plus_residue,
       count(*) FILTER (WHERE n_tok = 0) AS unparsed
FROM (SELECT r.id_type, (SELECT count(*) FROM pg_temp.tokens(r.raw_value, r.id_type)) AS n_tok,
             pg_temp.residual(r.raw_value, r.id_type) AS res
      FROM cov_raw r WHERE r.id_type IN ('CAS', 'EC')) x
GROUP BY id_type ORDER BY 1;

-- a4. Most frequent unparsed Covalo CAS / EC values
SELECT id_type, raw_value, count(*) AS n FROM cov_raw r
WHERE r.id_type IN ('CAS', 'EC') AND NOT EXISTS (SELECT 1 FROM pg_temp.tokens(r.raw_value, r.id_type))
GROUP BY 1, 2 ORDER BY 3 DESC LIMIT 15;

-- a5. Cross-check against kevin.covalo_identifiers_long (origin script not in the repo)
SELECT identifier_type, count(DISTINCT identifier_value_normalized) AS distinct_values,
       count(DISTINCT product_id) AS products
FROM kevin.covalo_identifiers_long GROUP BY 1 ORDER BY 1;

-- b1. Relay X printed identifier strings (current entries): parse outcome
SELECT id_type, count(*) AS strings,
       count(*) FILTER (WHERE n_tok = 1 AND res = '') AS single_clean,
       count(*) FILTER (WHERE n_tok > 1 AND res = '') AS multi_clean,
       count(*) FILTER (WHERE n_tok > 0 AND res <> '') AS tokens_plus_residue,
       count(*) FILTER (WHERE n_tok = 0) AS unparsed,
       count(*) FILTER (WHERE raw_value ~ '\[\d+\]') AS positional
FROM (SELECT p.id_type, p.raw_value, (SELECT count(*) FROM pg_temp.tokens(p.raw_value, p.id_type)) AS n_tok,
             pg_temp.residual(p.raw_value, p.id_type) AS res
      FROM (SELECT DISTINCT id_type, raw_value FROM rx_printed WHERE id_type IN ('CAS', 'EC')) p) x
GROUP BY id_type ORDER BY 1;

-- b2. Examples of Relay X CAS / EC strings not fully parsed
SELECT id_type, raw_value, pg_temp.residual(raw_value, id_type) AS residue
FROM (SELECT DISTINCT id_type, raw_value FROM rx_printed WHERE id_type IN ('CAS', 'EC')) p
WHERE pg_temp.residual(raw_value, id_type) <> '' ORDER BY random() LIMIT 12;

-- b3. Relay X distinct values by type (replay, current entries)
SELECT id_type, count(*) AS distinct_values, count(*) FILTER (WHERE has_literal) AS literal,
       count(*) FILTER (WHERE NOT has_literal) AS enriched_only,
       count(*) FILTER (WHERE id_type = 'CAS' AND NOT pg_temp.cas_ok(value)) AS cas_check_fail,
       count(*) FILTER (WHERE id_type = 'EC' AND NOT pg_temp.ec_ok(value)) AS ec_check_fail
FROM rx_val GROUP BY id_type ORDER BY 1;

-- b4. Overlap of Covalo distinct identifiers with the replay and the catalogue
SELECT id_type, count(*) AS covalo_distinct,
       count(*) FILTER (WHERE in_replay_literal) AS in_replay_literal,
       count(*) FILTER (WHERE in_replay) AS in_replay_any,
       count(*) FILTER (WHERE in_catalogue) AS in_catalogue,
       count(*) FILTER (WHERE in_replay OR in_catalogue) AS in_either,
       count(*) FILTER (WHERE in_catalogue AND NOT in_replay) AS catalogue_only,
       count(*) FILTER (WHERE in_replay AND NOT in_catalogue) AS replay_only,
       count(*) FILTER (WHERE NOT in_replay AND NOT in_catalogue) AS in_neither
FROM cov_val GROUP BY id_type ORDER BY 1;

-- b5. Covalo INCI values of the form "CI nnnnn" that match a Relay X Colour Index but no INCI
SELECT count(*) AS covalo_ci_inci,
       count(*) FILTER (WHERE r.value IS NOT NULL) AS matches_colour_index,
       count(*) FILTER (WHERE r.value IS NOT NULL AND NOT v.in_replay) AS colour_index_only
FROM cov_val v LEFT JOIN rx_val r ON r.id_type = 'COLOUR_INDEX' AND r.value = v.value
WHERE v.id_type = 'INCI' AND v.value ~ '^CI \d{5}$';

-- c1. Provisional coverage: products with at least one identifier of the type found in the replay
WITH hit AS (
    SELECT i.product_id, i.id_type, bool_or(v.in_replay) AS hit, bool_or(v.in_replay_literal) AS hit_literal
    FROM cov_id i JOIN cov_val v USING (id_type, value) GROUP BY 1, 2)
SELECT scope, id_type,
       count(DISTINCT h.product_id) AS products_with_type,
       count(DISTINCT h.product_id) FILTER (WHERE h.hit) AS found_in_replay,
       count(DISTINCT h.product_id) FILTER (WHERE h.hit_literal) AS found_literal,
       max(n_scope) AS products_in_scope
FROM (SELECT 'all active' AS scope, product_id FROM cov_product
      UNION ALL SELECT 'INGREDIENTS', product_id FROM cov_product WHERE product_type = 'INGREDIENTS'
      UNION ALL SELECT 'INGREDIENTS PERSONALCARE', product_id FROM cov_product
                WHERE product_type = 'INGREDIENTS' AND segment = 'PERSONALCARE') s
JOIN (SELECT scope, count(*) AS n_scope FROM (
          SELECT 'all active' AS scope FROM cov_product
          UNION ALL SELECT 'INGREDIENTS' FROM cov_product WHERE product_type = 'INGREDIENTS'
          UNION ALL SELECT 'INGREDIENTS PERSONALCARE' FROM cov_product
                    WHERE product_type = 'INGREDIENTS' AND segment = 'PERSONALCARE') z GROUP BY scope) n USING (scope)
JOIN (SELECT product_id, id_type, hit, hit_literal FROM hit
      UNION ALL SELECT product_id, 'ANY', bool_or(hit), bool_or(hit_literal) FROM hit GROUP BY product_id) h USING (product_id)
GROUP BY scope, id_type ORDER BY scope, id_type;

-- c2. Matched products by annexType and entryScope of the matched entries (a product counts once per row)
WITH m AS (SELECT DISTINCT i.product_id, e.annex_type, e.entry_scope
           FROM cov_id i JOIN rx_id r USING (id_type, value)
           JOIN (SELECT DISTINCT logical_entry_id, annex_type, entry_scope FROM rx_entry) e USING (logical_entry_id))
SELECT annex_type, count(DISTINCT product_id) AS products,
       count(DISTINCT product_id) FILTER (WHERE entry_scope = 'GROUP') AS via_group_entry
FROM m GROUP BY ROLLUP (annex_type) ORDER BY 2 DESC;

-- c3. Matched products whose matches are ONLY exemption or inventory entries
WITH m AS (SELECT i.product_id, bool_and(e.annex_type IN ('EXEMPTION', 'INVENTORY_LISTED')) AS only_exempt_inv
           FROM cov_id i JOIN rx_id r USING (id_type, value)
           JOIN (SELECT DISTINCT logical_entry_id, annex_type FROM rx_entry) e USING (logical_entry_id)
           GROUP BY i.product_id)
SELECT count(*) AS matched_products, count(*) FILTER (WHERE only_exempt_inv) AS only_exemption_or_inventory
FROM m;

-- c4. Fan-out: matched products by number of distinct matched entries
WITH pe AS (SELECT i.product_id, count(DISTINCT r.logical_entry_id) AS entries
            FROM cov_id i JOIN rx_id r USING (id_type, value) GROUP BY 1)
SELECT CASE WHEN entries = 1 THEN '1' WHEN entries <= 3 THEN '2-3' WHEN entries <= 10 THEN '4-10' ELSE '>10' END AS entries,
       count(*) AS products FROM pe GROUP BY 1 ORDER BY 1;

-- c5. Conflict indicator: CAS matches an entry, both sides carry INCI, but no INCI match on the same entry
WITH c AS (SELECT DISTINCT i.product_id, r.logical_entry_id FROM cov_id i JOIN rx_id r USING (id_type, value) WHERE i.id_type = 'CAS'),
     n AS (SELECT DISTINCT i.product_id, r.logical_entry_id FROM cov_id i JOIN rx_id r USING (id_type, value) WHERE i.id_type = 'INCI'),
     both_sides AS (
        SELECT DISTINCT c.product_id FROM c
        WHERE EXISTS (SELECT 1 FROM cov_id i WHERE i.product_id = c.product_id AND i.id_type = 'INCI')
          AND EXISTS (SELECT 1 FROM rx_id r WHERE r.logical_entry_id = c.logical_entry_id AND r.id_type = 'INCI'))
SELECT count(*) AS cas_hit_inci_on_both_sides,
       count(*) FILTER (WHERE NOT EXISTS (SELECT 1 FROM c JOIN n USING (product_id, logical_entry_id)
                                          WHERE c.product_id = b.product_id)) AS no_inci_agreement
FROM both_sides b;

-- c6. Coverage excluding the 20 most frequent matched values (concentration check)
WITH top AS (SELECT id_type, value FROM cov_val WHERE in_replay ORDER BY products DESC LIMIT 20)
SELECT count(DISTINCT i.product_id) AS products_hit_excl_top20
FROM cov_id i JOIN cov_val v USING (id_type, value)
WHERE v.in_replay AND (i.id_type, i.value) NOT IN (SELECT id_type, value FROM top);

-- d1. Source-list sizing: Covalo distinct identifiers not reachable via the current list
--     (current list = replay identifiers + catalogue, as proposed in coverage-inventory s.4)
SELECT id_type, count(*) AS covalo_distinct,
       count(*) FILTER (WHERE NOT in_replay AND NOT in_catalogue) AS new_items,
       count(*) FILTER (WHERE NOT in_replay AND NOT in_catalogue AND products >= 2) AS new_items_on_2plus_products
FROM cov_val GROUP BY ROLLUP (id_type) ORDER BY 1 NULLS LAST;

-- d2. Covalo products whose usable identifiers are ALL new (no value in replay or catalogue)
SELECT count(*) AS products_all_new
FROM (SELECT i.product_id FROM cov_id i JOIN cov_val v USING (id_type, value)
      GROUP BY i.product_id HAVING NOT bool_or(v.in_replay OR v.in_catalogue)) x
