-- PROVISIONAL. Covalo CAS quality (Part A). Read-only; TEMP objects only. No API calls.
-- Needs the F1 TEMP objects and parser:
--   python -m relayx.provisional_report sql/provisional/covalo_cas_quality.sql
--       --setup sql/provisional/f1_matching_assessment.sql --timeout 900
--
-- F1 parsing rules (unchanged, sql/provisional/f1_matching_assessment.sql):
--   Products: covalo.product not trashed, enabled, company not trashed (cov_product).
--   Raw CAS element = one string element of product.identifiers -> 'cas' (cov_raw).
--   pg_temp.prep: en dash, em dash, hyphen, non-breaking hyphen and minus to "-"; spaces around
--     hyphens removed. Token = every (?<!\d)\d{2,7}-\d{2}-\d(?!\d) in the prepared string.
--     Leading zeros are kept as printed (F1 does not strip them).
--   Residual = prepared string without tokens, [n] markers, separators (whitespace ; , / | & + . ( ) -)
--     and connecting words (and, or, oder, und, et); empty = fully parsed.
--   Element classes: single (1 token, no residual), multi-value (2+ tokens, no residual),
--     residue (1+ tokens with residual), unparsed (no token).
--   Check digit: pg_temp.cas_ok. Failing tokens are kept as parsed values (as in F1); in F2 they
--     were not queried.
--   INCI value = F1 norm_inci (trim, collapse whitespace, upper case).
-- A4 comparison rule: INCI normalised on both sides by pg_temp.ninci = upper case, whitespace
--   collapsed and trimmed, apostrophe variants (’ ‘ ` ´ ʼ) replaced by '. A Covalo CAS-INCI pair
--   (same product) agrees for a source if its INCI equals any INCI that source serves for that CAS
--   (inciEu, inciUs, inciIecic, inci, inciList); conflict if the source serves INCI for the CAS but
--   none equal; no reference if it serves none. Sources, never merged:
--   replay   = entries of replay 20261019T143522Z_eu (F1 rx_entry): CAS = F1 rx_id CAS values
--              (printed and enriched); INCI = identifiers.inci (split on [n] and ;), identifiers.inciList,
--              nomenclature.inciEu / inciUs / inciIecic of the same entry;
--   lookup   = F2 full run, CAS items: the queried CAS; INCI of each returned constraint (same five
--              fields). Covers only CAS with returned constraints (HAS_DATA);
--   caveat   = F2 full run, INCI items whose identifierCaveats note matches the template "Your
--              identifier designates, in our substance index, a substance with a single CAS
--              number (X)." and contains no other CAS-shaped number: pair (X, queried INCI).
--   Group rule: replay entries with entryScope GROUP or GENERIC_CLASS, and lookup constraints with
--     reachedViaGroupEntry true or entryScope GROUP / GENERIC_CLASS, are excluded from agree and
--     conflict and reported separately ("nature GROUP" does not exist: nature is LITERAL_ENTRY or
--     DERIVED_BY_LAW; the group marker is entryScope).
-- A5 source column: covalo.product.company -> covalo.company (id, name); active products only.

CREATE FUNCTION pg_temp.ninci(t text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT nullif(upper(regexp_replace(btrim(regexp_replace(t, '[’‘`´ʼ]', '''', 'g')), '\s+', ' ', 'g')), '')
$$;
CREATE FUNCTION pg_temp.jtext(j jsonb) RETURNS SETOF text LANGUAGE sql IMMUTABLE AS $$
    SELECT x FROM jsonb_array_elements_text(CASE jsonb_typeof(j) WHEN 'array' THEN j
                                                 WHEN 'string' THEN jsonb_build_array(j) ELSE '[]'::jsonb END) AS x
$$;

CREATE TEMP TABLE q_prod AS
SELECT cp.product_id, cp.product_type, cp.segment, p.company AS company_id, c.name AS company_name
FROM cov_product cp JOIN covalo.product p ON p.id = cp.product_id JOIN covalo.company c ON c.id = p.company;
CREATE UNIQUE INDEX ON q_prod (product_id);
ANALYZE q_prod;

-- Raw CAS elements with parse outcome.
CREATE TEMP TABLE q_raw AS
SELECT r.product_id, r.raw_value,
       (SELECT count(*) FROM pg_temp.tokens(r.raw_value, 'CAS')) AS n_tok,
       pg_temp.residual(r.raw_value, 'CAS') AS res,
       (SELECT bool_or(NOT pg_temp.cas_ok(t)) FROM pg_temp.tokens(r.raw_value, 'CAS') t) AS has_fail,
       -- separator = the non-digit text right after the first token (PostgreSQL regexes take their
       -- greediness from the first quantifier, so a lazy ".*?" between two tokens would not be lazy)
       lower(btrim((regexp_match(pg_temp.prep(r.raw_value), '(?<!\d)\d{2,7}-\d{2}-\d(?!\d)([^0-9]*)'))[1])) AS sep
FROM cov_raw r WHERE r.id_type = 'CAS';
ALTER TABLE q_raw ADD COLUMN cls text;
UPDATE q_raw SET cls = CASE WHEN n_tok = 0 THEN 'unparsed' WHEN n_tok = 1 AND res = '' THEN 'single'
                            WHEN n_tok > 1 AND res = '' THEN 'multi-value' ELSE 'residue' END;
CREATE INDEX ON q_raw (product_id);
ANALYZE q_raw;

CREATE TEMP TABLE q_cas AS SELECT product_id, value, check_ok FROM cov_id WHERE id_type = 'CAS';
CREATE INDEX ON q_cas (product_id); CREATE INDEX ON q_cas (value);
CREATE TEMP TABLE q_inci AS SELECT product_id, value, pg_temp.ninci(value) AS n FROM cov_id WHERE id_type = 'INCI';
CREATE INDEX ON q_inci (product_id); CREATE INDEX ON q_inci (n);
ANALYZE q_cas; ANALYZE q_inci;

-- Covalo CAS-INCI pairs on the same product.
CREATE TEMP TABLE q_pair AS
SELECT DISTINCT c.product_id, c.value AS cas, i.n AS inci
FROM q_cas c JOIN q_inci i USING (product_id) WHERE i.n IS NOT NULL;
CREATE INDEX ON q_pair (cas, inci); CREATE INDEX ON q_pair (product_id);
ANALYZE q_pair;

-- F2 items (full run): status per (type, value).
CREATE TEMP TABLE q_f2 AS
SELECT s.ref ->> 'type' AS id_type, s.ref ->> 'value' AS value, (s.ref ->> 'products')::int AS products,
       CASE WHEN (r ->> 'ok')::boolean THEN r -> 'ingredientStatus' ->> 'status' ELSE 'ok=false' END AS status, r
FROM relayx_raw.api_response a
CROSS JOIN LATERAL jsonb_array_elements(a.body -> 'results') r
CROSS JOIN LATERAL (SELECT a.source_ref -> ((r ->> 'index')::int) AS ref) s
WHERE a.run_id = '20261022T075923Z_covalo_lookup_eu';
CREATE INDEX ON q_f2 (id_type, value);
ANALYZE q_f2;

-- Reference: replay. INCI per entry from the five fields; CAS per entry from F1 rx_id.
CREATE TEMP TABLE q_rx_inci AS
SELECT DISTINCT e.logical_entry_id, pg_temp.ninci(x) AS n
FROM rx_entry e
CROSS JOIN LATERAL (
    SELECT s FROM regexp_split_to_table(coalesce(e.payload -> 'identifiers' ->> 'inci', ''), '\s*\[\d+\]\s*|;') s
    UNION ALL SELECT pg_temp.jtext(e.payload -> 'identifiers' -> 'inciList')
    UNION ALL SELECT pg_temp.jtext(e.payload -> 'nomenclature' -> 'inciEu')
    UNION ALL SELECT pg_temp.jtext(e.payload -> 'nomenclature' -> 'inciUs')
    UNION ALL SELECT pg_temp.jtext(e.payload -> 'nomenclature' -> 'inciIecic')) AS v(x)
WHERE pg_temp.ninci(x) IS NOT NULL;
CREATE TEMP TABLE q_ref_replay AS
SELECT DISTINCT c.value AS cas, i.n AS inci, e.entry_scope IN ('GROUP', 'GENERIC_CLASS') AS grp
FROM rx_id c JOIN q_rx_inci i USING (logical_entry_id)
JOIN (SELECT DISTINCT logical_entry_id, entry_scope FROM rx_entry) e USING (logical_entry_id)
WHERE c.id_type = 'CAS';
CREATE INDEX ON q_ref_replay (cas, inci);
ANALYZE q_ref_replay;

-- Reference: lookup nomenclature (CAS items, returned constraints).
CREATE TEMP TABLE q_ref_lookup AS
SELECT DISTINCT f.value AS cas, pg_temp.ninci(x) AS inci,
       coalesce((c ->> 'reachedViaGroupEntry')::boolean, false) OR c ->> 'entryScope' IN ('GROUP', 'GENERIC_CLASS') AS grp
FROM q_f2 f
CROSS JOIN LATERAL jsonb_array_elements(CASE WHEN jsonb_typeof(f.r -> 'constraints') = 'array' THEN f.r -> 'constraints' ELSE '[]' END) c
CROSS JOIN LATERAL (
    SELECT s FROM regexp_split_to_table(coalesce(c -> 'identifiers' ->> 'inci', ''), '\s*\[\d+\]\s*|;') s
    UNION ALL SELECT pg_temp.jtext(c -> 'identifiers' -> 'inciList')
    UNION ALL SELECT pg_temp.jtext(c -> 'nomenclature' -> 'inciEu')
    UNION ALL SELECT pg_temp.jtext(c -> 'nomenclature' -> 'inciUs')
    UNION ALL SELECT pg_temp.jtext(c -> 'nomenclature' -> 'inciIecic')) AS v(x)
WHERE f.id_type = 'CAS' AND pg_temp.ninci(x) IS NOT NULL;
CREATE INDEX ON q_ref_lookup (cas, inci);
ANALYZE q_ref_lookup;

-- Reference: lookup caveat (INCI items naming exactly one CAS through the fixed template).
CREATE TEMP TABLE q_caveat AS
SELECT f.value AS inci_item, pg_temp.ninci(f.value) AS inci, e ->> 'note' AS note,
       (regexp_match(e ->> 'note', '^Your identifier designates, in our substance index, a substance with a single CAS number \((\d{2,7}-\d{2}-\d)\)\.'))[1] AS cas,
       (SELECT count(DISTINCT m[1]) FROM regexp_matches(e ->> 'note', '(?<!\d)(\d{2,7}-\d{2}-\d)(?!\d)', 'g') m) AS n_cas_in_note
FROM q_f2 f CROSS JOIN LATERAL jsonb_array_elements(f.r -> 'identifierCaveats') e
WHERE f.id_type = 'INCI' AND e ->> 'note' ~ '\d{2,7}-\d{2}-\d';
CREATE TEMP TABLE q_ref_caveat AS
SELECT DISTINCT cas, inci, false AS grp FROM q_caveat WHERE cas IS NOT NULL AND n_cas_in_note = 1;
CREATE INDEX ON q_ref_caveat (cas, inci);

-- Pair classification per source.
CREATE TEMP TABLE q_ref_all AS
SELECT 'replay' AS src, cas, inci, grp FROM q_ref_replay
UNION ALL SELECT 'lookup', cas, inci, grp FROM q_ref_lookup
UNION ALL SELECT 'caveat', cas, inci, grp FROM q_ref_caveat;
CREATE INDEX ON q_ref_all (src, cas, grp, inci);
ANALYZE q_ref_all;
CREATE TEMP TABLE q_pair_cls AS
SELECT p.product_id, p.cas, p.inci, s.src,
       CASE WHEN EXISTS (SELECT 1 FROM q_ref_all r WHERE r.src = s.src AND r.cas = p.cas AND NOT r.grp AND r.inci = p.inci) THEN 'agree'
            WHEN EXISTS (SELECT 1 FROM q_ref_all r WHERE r.src = s.src AND r.cas = p.cas AND NOT r.grp) THEN 'conflict'
            ELSE 'no reference' END AS cls,
       EXISTS (SELECT 1 FROM q_ref_all r WHERE r.src = s.src AND r.cas = p.cas AND r.grp) AS group_ref,
       EXISTS (SELECT 1 FROM q_ref_all r WHERE r.src = s.src AND r.cas = p.cas AND r.grp AND r.inci = p.inci) AS group_match
FROM q_pair p CROSS JOIN (VALUES ('replay'), ('lookup'), ('caveat')) AS s(src);
CREATE INDEX ON q_pair_cls (src, product_id);
ANALYZE q_pair_cls;

CREATE TEMP TABLE q_prod_cls AS
SELECT src, product_id,
       CASE WHEN bool_or(cls = 'agree') THEN 'agree' WHEN bool_or(cls = 'conflict') THEN 'conflict' ELSE 'no reference' END AS cls
FROM q_pair_cls GROUP BY 1, 2;

-- REPORT

-- a1. PROVISIONAL. A1 completeness: active products with a CAS element / a parsable CAS, overall, by product type, by segment, ingredients in personal care
SELECT g.lvl, g.grp, count(*) AS products,
       count(*) FILTER (WHERE EXISTS (SELECT 1 FROM q_raw r WHERE r.product_id = g.product_id)) AS with_cas_element,
       count(*) FILTER (WHERE EXISTS (SELECT 1 FROM q_cas c WHERE c.product_id = g.product_id)) AS with_parsable_cas,
       round(100.0 * count(*) FILTER (WHERE EXISTS (SELECT 1 FROM q_cas c WHERE c.product_id = g.product_id)) / count(*), 1) AS pct_parsable
FROM (SELECT '0 all' AS lvl, 'all active' AS grp, product_id FROM q_prod
      UNION ALL SELECT '1 product_type', coalesce(product_type, '(null)'), product_id FROM q_prod
      UNION ALL SELECT '2 segment', coalesce(segment, '(null)'), product_id FROM q_prod
      UNION ALL SELECT '3 ingredients personal care', 'INGREDIENTS + PERSONALCARE', product_id FROM q_prod
                WHERE product_type = 'INGREDIENTS' AND segment = 'PERSONALCARE') g
GROUP BY 1, 2 ORDER BY 1, 3 DESC

-- a1b. PROVISIONAL. A1 at element and value level: raw CAS elements, distinct raw strings, distinct parsed values
SELECT count(*) AS raw_elements, count(DISTINCT raw_value) AS distinct_raw_strings,
       (SELECT count(DISTINCT value) FROM q_cas) AS distinct_parsed_values,
       count(DISTINCT product_id) AS products_with_element
FROM q_raw

-- a2. PROVISIONAL. A2 format classes at three levels
SELECT cls, count(*) AS raw_elements, count(DISTINCT raw_value) AS distinct_raw_strings, count(DISTINCT product_id) AS products
FROM q_raw GROUP BY ROLLUP (cls) ORDER BY 1 NULLS LAST

-- a2b. PROVISIONAL. A2 multi-value elements by separator (text between the first two tokens)
SELECT CASE WHEN sep = '' THEN '(whitespace only)' WHEN sep ~ '^(and|or|oder|und|et)$' THEN 'word: ' || sep ELSE sep END AS separator,
       count(*) AS raw_elements, count(DISTINCT raw_value) AS distinct_raw_strings, count(DISTINCT product_id) AS products
FROM q_raw WHERE cls = 'multi-value' GROUP BY 1 ORDER BY 2 DESC LIMIT 20

-- a2c. PROVISIONAL. A2 the 20 most frequent unparsed strings (exact raw string) with product counts
SELECT raw_value, count(*) AS raw_elements, count(DISTINCT product_id) AS products
FROM q_raw WHERE cls = 'unparsed' GROUP BY 1 ORDER BY 3 DESC, 1 LIMIT 20

-- a2d. PROVISIONAL. A2 residue: the 10 most frequent residues
SELECT res AS residue, count(*) AS raw_elements, count(DISTINCT product_id) AS products, min(raw_value) AS example
FROM q_raw WHERE cls = 'residue' GROUP BY 1 ORDER BY 2 DESC LIMIT 10

-- a2e. PROVISIONAL. A2 check-digit failures: raw elements with a failing token, distinct failing values, products
SELECT (SELECT count(*) FROM q_raw WHERE has_fail) AS raw_elements_with_failing_token,
       (SELECT count(DISTINCT value) FROM q_cas WHERE NOT check_ok) AS distinct_failing_values,
       (SELECT count(DISTINCT product_id) FROM q_cas WHERE NOT check_ok) AS products_with_failing_value,
       (SELECT count(DISTINCT product_id) FROM q_cas c WHERE NOT check_ok
          AND NOT EXISTS (SELECT 1 FROM q_cas d WHERE d.product_id = c.product_id AND d.check_ok)) AS products_only_failing_values

-- a2f. PROVISIONAL. A2 values the parser had to normalise, per kind (an element can show several kinds)
SELECT k.kind, count(*) AS raw_elements, count(DISTINCT r.raw_value) AS distinct_raw_strings, count(DISTINCT r.product_id) AS products
FROM q_raw r
CROSS JOIN LATERAL (VALUES
    ('non-standard hyphen character (en/em dash, U+2010, U+2011, minus)', r.raw_value ~ '[–—‐‑−]'),
    ('space next to a hyphen inside a number', translate(r.raw_value, '–—‐‑−', '-----') ~ '\d\s+-|-\s+\d'),
    ('leading or trailing whitespace', r.raw_value <> btrim(r.raw_value)),
    ('leading zero in a token (kept by F1, not normalised)', EXISTS (SELECT 1 FROM pg_temp.tokens(r.raw_value, 'CAS') t WHERE t ~ '^0'))) AS k(kind, hit)
WHERE k.hit AND r.n_tok > 0 GROUP BY 1 ORDER BY 2 DESC

-- a3a. PROVISIONAL. A3(a) distinct INCI per CAS (over all products carrying the CAS): distribution
WITH n AS (SELECT cas, count(DISTINCT inci) AS k, count(DISTINCT product_id) AS products FROM q_pair GROUP BY 1)
SELECT CASE WHEN k = 1 THEN '1' WHEN k = 2 THEN '2' WHEN k <= 5 THEN '3 to 5' WHEN k <= 10 THEN '6 to 10'
            WHEN k <= 50 THEN '11 to 50' ELSE 'more than 50' END AS distinct_inci, count(*) AS cas_values, sum(products) AS product_links
FROM n GROUP BY 1 ORDER BY min(k)

-- a3x. PROVISIONAL. A3 check: products carrying 7732-18-5 (any, with an INCI) and its distinct INCI
SELECT (SELECT count(DISTINCT product_id) FROM q_cas WHERE value = '7732-18-5') AS products_with_cas,
       (SELECT count(DISTINCT product_id) FROM q_pair WHERE cas = '7732-18-5') AS products_with_cas_and_inci,
       (SELECT count(DISTINCT inci) FROM q_pair WHERE cas = '7732-18-5') AS distinct_inci

-- a3b. PROVISIONAL. A3(a) the 20 CAS with the most distinct INCI, with the 3 most frequent INCI
WITH n AS (SELECT cas, count(DISTINCT inci) AS k, count(DISTINCT product_id) AS products FROM q_pair GROUP BY 1)
SELECT n.cas, n.k AS distinct_inci, n.products,
       (SELECT string_agg(inci || ' (' || c || ')', ' | ') FROM (SELECT inci, count(DISTINCT product_id) AS c FROM q_pair p
          WHERE p.cas = n.cas GROUP BY 1 ORDER BY 2 DESC, 1 LIMIT 3) x) AS top_inci
FROM n ORDER BY k DESC, cas LIMIT 20

-- a3c. PROVISIONAL. A3(b) distinct CAS per INCI: distribution
WITH n AS (SELECT inci, count(DISTINCT cas) AS k, count(DISTINCT product_id) AS products FROM q_pair GROUP BY 1)
SELECT CASE WHEN k = 1 THEN '1' WHEN k = 2 THEN '2' WHEN k <= 5 THEN '3 to 5' WHEN k <= 10 THEN '6 to 10'
            WHEN k <= 50 THEN '11 to 50' ELSE 'more than 50' END AS distinct_cas, count(*) AS inci_values, sum(products) AS product_links
FROM n GROUP BY 1 ORDER BY min(k)

-- a3d. PROVISIONAL. A3(b) the 20 INCI with the most distinct CAS, with the 3 most frequent CAS
WITH n AS (SELECT inci, count(DISTINCT cas) AS k, count(DISTINCT product_id) AS products FROM q_pair GROUP BY 1)
SELECT n.inci, n.k AS distinct_cas, n.products,
       (SELECT string_agg(cas || ' (' || c || ')', ' | ') FROM (SELECT cas, count(DISTINCT product_id) AS c FROM q_pair p
          WHERE p.inci = n.inci GROUP BY 1 ORDER BY 2 DESC, 1 LIMIT 3) x) AS top_cas
FROM n ORDER BY k DESC, inci LIMIT 20

-- a3e. PROVISIONAL. A3(c) products by number of parsed CAS (distinct values); from one multi-value element or several elements
WITH p AS (SELECT product_id, count(DISTINCT value) AS k,
                  (SELECT count(*) FROM q_raw r WHERE r.product_id = c.product_id AND r.n_tok > 0) AS elements
           FROM q_cas c GROUP BY 1)
SELECT CASE WHEN k = 1 THEN '1' WHEN k = 2 THEN '2' WHEN k = 3 THEN '3' WHEN k <= 5 THEN '4 to 5'
            WHEN k <= 10 THEN '6 to 10' ELSE 'more than 10' END AS parsed_cas, count(*) AS products,
       count(*) FILTER (WHERE elements = 1) AS from_one_element, count(*) FILTER (WHERE elements > 1) AS from_several_elements
FROM p GROUP BY 1 ORDER BY min(k)

-- a4a. PROVISIONAL. A4 reference coverage: Covalo CAS-INCI pairs, CAS values, pairs with any reference in any source
SELECT (SELECT count(*) FROM q_pair) AS pair_links, (SELECT count(*) FROM (SELECT DISTINCT cas, inci FROM q_pair) x) AS distinct_pairs,
       (SELECT count(DISTINCT cas) FROM q_pair) AS distinct_cas,
       (SELECT count(*) FROM (SELECT DISTINCT cas, inci FROM q_pair_cls WHERE cls <> 'no reference') x) AS distinct_pairs_with_any_reference,
       (SELECT count(DISTINCT product_id) FROM q_pair) AS products_with_pairs,
       (SELECT count(DISTINCT product_id) FROM q_pair_cls WHERE cls <> 'no reference') AS products_with_any_reference

-- a4b. PROVISIONAL. A4 pair level per source: agree, conflict, no reference; group references reported separately
SELECT src, cls, count(*) AS pair_links, count(DISTINCT (cas, inci)) AS distinct_pairs, count(DISTINCT cas) AS distinct_cas,
       count(*) FILTER (WHERE group_ref) AS pair_links_cas_also_has_group_ref,
       count(*) FILTER (WHERE group_match) AS pair_links_matching_only_via_group_or_also
FROM q_pair_cls GROUP BY 1, 2 ORDER BY 1, 2

-- a4c. PROVISIONAL. A4 group references only (excluded from agree and conflict): pairs whose CAS has a group reference and no non-group one
SELECT src, count(*) AS pair_links, count(*) FILTER (WHERE group_match) AS inci_named_by_group_entry, count(DISTINCT cas) AS distinct_cas
FROM q_pair_cls WHERE cls = 'no reference' AND group_ref GROUP BY 1 ORDER BY 1

-- a4d. PROVISIONAL. A4 product level per source (agree if any pair agrees; conflict if none agrees and one conflicts)
SELECT src, cls, count(*) AS products, round(100.0 * count(*) / sum(count(*)) OVER (PARTITION BY src), 1) AS pct
FROM q_prod_cls GROUP BY 1, 2 ORDER BY 1, 2

-- a4e. PROVISIONAL. A4 product level per source, products with exactly one parsed CAS and one INCI
SELECT c.src, c.cls, count(*) AS products
FROM q_prod_cls c
WHERE (SELECT count(DISTINCT cas) FROM q_pair p WHERE p.product_id = c.product_id) = 1
  AND (SELECT count(DISTINCT inci) FROM q_pair p WHERE p.product_id = c.product_id) = 1
GROUP BY 1, 2 ORDER BY 1, 2

-- a4f. PROVISIONAL. A4 20 conflict examples (most frequent conflicting pairs; replay and lookup), with the INCI the source serves for the CAS
SELECT x.src, x.cas, x.inci AS covalo_inci, x.products,
       (SELECT string_agg(DISTINCT r.inci, ' | ') FROM q_ref_all r WHERE r.src = x.src AND r.cas = x.cas AND NOT r.grp) AS reference_inci
FROM (SELECT src, cas, inci, count(DISTINCT product_id) AS products, row_number() OVER (PARTITION BY src ORDER BY count(DISTINCT product_id) DESC, cas, inci) AS rn
      FROM q_pair_cls WHERE cls = 'conflict' AND src IN ('replay', 'lookup') GROUP BY 1, 2, 3) x
WHERE x.rn <= 10 ORDER BY x.src, x.products DESC

-- a4g. PROVISIONAL. A4 caveat source: INCI items with a CAS-bearing caveat, template matches, exactly one CAS
SELECT count(DISTINCT inci_item) AS inci_items_with_cas_in_caveat,
       count(DISTINCT inci_item) FILTER (WHERE cas IS NOT NULL) AS template_single_cas,
       count(DISTINCT inci_item) FILTER (WHERE cas IS NOT NULL AND n_cas_in_note = 1) AS used_exactly_one_cas,
       count(DISTINCT inci_item) FILTER (WHERE cas IS NULL) AS not_used_other_wording,
       (SELECT count(*) FROM q_f2 WHERE id_type = 'INCI') AS inci_items
FROM q_caveat

-- a4h. PROVISIONAL. A4 caveat source: 10 examples as served
SELECT inci_item, cas, note FROM q_caveat WHERE cas IS NOT NULL AND n_cas_in_note = 1 ORDER BY md5(inci_item) LIMIT 10

-- a5. PROVISIONAL. A5 the 20 companies owning the most active products (product.company -> company.name)
WITH top AS (SELECT company_id, company_name, count(*) AS products FROM q_prod GROUP BY 1, 2 ORDER BY 3 DESC LIMIT 20),
pp AS (
    SELECT q.company_id, q.product_id,
           EXISTS (SELECT 1 FROM q_raw r WHERE r.product_id = q.product_id) AS has_el,
           EXISTS (SELECT 1 FROM q_cas c WHERE c.product_id = q.product_id) AS has_cas,
           EXISTS (SELECT 1 FROM q_raw r WHERE r.product_id = q.product_id AND r.cls = 'unparsed') AS has_unparsed,
           EXISTS (SELECT 1 FROM q_cas c WHERE c.product_id = q.product_id AND NOT c.check_ok) AS has_fail,
           (SELECT cls FROM q_prod_cls x WHERE x.src = 'replay' AND x.product_id = q.product_id) AS a4_replay,
           (SELECT cls FROM q_prod_cls x WHERE x.src = 'lookup' AND x.product_id = q.product_id) AS a4_lookup
    FROM q_prod q WHERE q.company_id IN (SELECT company_id FROM top))
SELECT t.company_name, t.products,
       round(100.0 * count(*) FILTER (WHERE has_cas) / t.products, 1) AS pct_parsable_cas,
       round(100.0 * count(*) FILTER (WHERE has_unparsed) / nullif(count(*) FILTER (WHERE has_el), 0), 1) AS pct_unparsed_of_with_element,
       round(100.0 * count(*) FILTER (WHERE has_fail) / nullif(count(*) FILTER (WHERE has_cas), 0), 1) AS pct_check_fail_of_parsable,
       round(100.0 * count(*) FILTER (WHERE a4_replay = 'conflict') / nullif(count(*) FILTER (WHERE a4_replay IN ('agree', 'conflict')), 0), 1) AS pct_a4_conflict_replay,
       round(100.0 * count(*) FILTER (WHERE a4_lookup = 'conflict') / nullif(count(*) FILTER (WHERE a4_lookup IN ('agree', 'conflict')), 0), 1) AS pct_a4_conflict_lookup,
       (SELECT round(100.0 * count(*) FILTER (WHERE f.status = 'UNKNOWN_IDENTIFIER') / nullif(count(*), 0), 1)
          FROM (SELECT DISTINCT c.value FROM q_cas c JOIN q_prod q2 USING (product_id) WHERE q2.company_id = t.company_id) v
          JOIN q_f2 f ON f.id_type = 'CAS' AND f.value = v.value) AS pct_cas_values_unknown,
       (SELECT count(DISTINCT c.value) FROM q_cas c JOIN q_prod q2 USING (product_id) WHERE q2.company_id = t.company_id) AS distinct_cas
FROM top t JOIN pp USING (company_id) GROUP BY t.company_id, t.company_name, t.products ORDER BY t.products DESC

-- a6. PROVISIONAL. A6 leading number of distinct CAS queried in F2, by status (shares within status)
WITH v AS (
    SELECT f.value, f.status, split_part(f.value, '-', 1)::int AS lead,
           (SELECT count(DISTINCT c.product_id) FROM q_cas c WHERE c.value = f.value) AS products
    FROM q_f2 f WHERE f.id_type = 'CAS' AND f.status IN ('HAS_DATA', 'KNOWN_WITHOUT_DATA', 'UNKNOWN_IDENTIFIER'))
SELECT status,
       CASE WHEN lead < 8000 THEN '1 below 8000' WHEN lead <= 8099 THEN '2 8000 to 8099' WHEN lead <= 8999 THEN '3 8100 to 8999'
            WHEN lead <= 9999 THEN '4 9000 to 9999' WHEN lead <= 67999 THEN '5 10000 to 67999'
            WHEN lead <= 99999 THEN '6 68000 to 99999' ELSE '7 100000 and above' END AS bin,
       count(*) AS cas_values, round(100.0 * count(*) / sum(count(*)) OVER (PARTITION BY status), 1) AS pct_of_status,
       sum(products) AS product_links,
       (SELECT count(DISTINCT c.product_id) FROM q_cas c JOIN v v2 ON v2.value = c.value
         WHERE v2.status = v.status AND v2.lead BETWEEN min(v.lead) AND max(v.lead)) AS distinct_products
FROM v GROUP BY 1, 2 ORDER BY 1, 2
