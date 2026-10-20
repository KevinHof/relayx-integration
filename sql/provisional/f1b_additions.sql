-- PROVISIONAL. Fast-track F step 1 additions (F1b), 2026-10-20. Not the phase 8 matching model.
-- Read-only on covalo, relayx_raw and kevin; TEMP objects only (pg_temp); nothing persists.
-- Needs the TEMP objects of f1_matching_assessment.sql:
--   python -m relayx.provisional_report sql/provisional/f1b_additions.sql --setup sql/provisional/f1_matching_assessment.sql
-- Every figure produced here is PROVISIONAL.

-- Item 2: the 41,985 active INGREDIENTS products without a usable identifier under the F1 rules.
CREATE TEMP TABLE noid AS
SELECT cp.product_id, p.key, p.old_key, p.trade_name, p.company, p.identifiers
FROM cov_product cp JOIN covalo.product p ON p.id = cp.product_id
WHERE cp.product_type = 'INGREDIENTS'
  AND NOT EXISTS (SELECT 1 FROM cov_id i WHERE i.product_id = cp.product_id);
CREATE INDEX ON noid (key);
CREATE INDEX ON noid (old_key);
CREATE INDEX ON noid (product_id);
ANALYZE noid;

-- Top-level keys of every jsonb column in schema covalo whose name matches the search terms.
CREATE FUNCTION pg_temp.jsonb_key_scan() RETURNS TABLE (tbl text, col text, json_key text, n bigint)
LANGUAGE plpgsql AS $$
DECLARE r record;
BEGIN
    FOR r IN SELECT table_name, column_name FROM information_schema.columns
             WHERE table_schema = 'covalo' AND data_type = 'jsonb' ORDER BY 1, 2 LOOP
        RETURN QUERY EXECUTE format(
            'SELECT %L::text, %L::text, k, count(*) FROM (SELECT jsonb_object_keys(CASE WHEN jsonb_typeof(%I) = ''object'' '
            'THEN %I ELSE ''{}''::jsonb END) AS k FROM covalo.%I) x '
            'WHERE k ~* ''inci|cas|einecs|ec_|^ec$|iupac|composition'' GROUP BY k',
            r.table_name, r.column_name, r.column_name, r.column_name, r.table_name);
    END LOOP;
END $$;

-- Formulation rows (two tables) with a non-empty INCI array, and the product they link to.
CREATE TEMP TABLE form_row AS
SELECT 'product_formulation_item' AS src, f.product_id AS formulation_id, f.value AS row_name,
       f.properties -> 'inci' AS inci, f.properties -> 'linked_product_detail' AS link,
       f.properties ->> 'supplier' AS supplier
FROM covalo.product_formulation_item f
WHERE jsonb_typeof(f.properties -> 'inci') = 'array' AND jsonb_array_length(f.properties -> 'inci') > 0
UNION ALL
SELECT 'product_attributes', a.product_id, a.value, a.properties -> 'inci', a.properties -> 'linked_product_detail',
       a.properties ->> 'supplier'
FROM covalo.product_attributes a
WHERE jsonb_typeof(a.properties -> 'inci') = 'array' AND jsonb_array_length(a.properties -> 'inci') > 0;
ANALYZE form_row;

-- Identifier-less products reachable from formulation rows, per join (for 2d and 2e).
CREATE TEMP TABLE noid_form AS
SELECT DISTINCT n.product_id, 'explicit_link' AS via, f.src
FROM noid n JOIN form_row f ON f.link ->> 'key' = n.key
UNION
SELECT DISTINCT n.product_id, 'explicit_link', f.src
FROM noid n JOIN form_row f ON f.link ->> 'old_key' = n.old_key
UNION
SELECT DISTINCT n.product_id, 'trade_name', f.src
FROM noid n JOIN form_row f ON lower(btrim(f.row_name)) = lower(btrim(n.trade_name));
ANALYZE noid_form;

-- Items 3 to 5: product-to-entry matches with provenance, annex and proposed scope class.
-- Annex groups follow results/2026-10-20-atlas-datapack.md section 2; classes follow
-- docs/data-model/cosmetics-scope.md (PROPOSED), with the REACH CMR appendices as their own
-- group because their class is open.
CREATE TEMP TABLE entry_annex AS
SELECT DISTINCT logical_entry_id, payload ->> 'annexRef' AS annex_ref, payload -> 'text' ->> 'officialRef' AS text_ref
FROM relayx_raw.entry_version WHERE run_id = '20261019T143522Z_eu';

CREATE TEMP TABLE entry_group AS
SELECT logical_entry_id, annex_ref,
       CASE WHEN text_ref = '32026R1383' THEN 'CITES 32026R1383, 11 annexes'
            WHEN text_ref = '32025R0006' THEN 'CITES 32025R0006, Annex (1) and (2)'
            ELSE annex_ref END AS annex_group,
       CASE WHEN annex_ref IN ('Annex II', 'Annex III', 'Annex IV', 'Annex V', 'Annex VI', 'Article 15(1)', 'Article 15(2)')
                 THEN '1 core cosmetics'
            WHEN annex_ref IN ('Annex VI Table 3', 'REACH Annex XVII', 'REACH Annex XIV', 'REACH Candidate List',
                               'POPs Regulation', 'Annex I, part A') THEN '2 indirectly relevant'
            WHEN annex_ref IN ('CMR category 1A', 'CMR category 1B', 'Mutagens', 'Toxic category 1', 'Toxic category 2')
                 THEN '3 REACH CMR appendices (class open)'
            WHEN text_ref IN ('32026R1383', '32025R0006') THEN '4 marginal'
            WHEN annex_ref IN ('Exemptions', 'REACH Annex V') THEN '5 not relevant'
            ELSE '9 unclassified' END AS scope_class
FROM entry_annex
WHERE logical_entry_id IN (SELECT logical_entry_id FROM rx_entry);
CREATE INDEX ON entry_group (logical_entry_id);
ANALYZE entry_group;

CREATE TEMP TABLE pm AS
SELECT DISTINCT i.product_id, i.id_type, i.value, r.logical_entry_id, r.provenance, g.annex_group, g.scope_class
FROM cov_id i
JOIN rx_id r USING (id_type, value)
JOIN entry_group g USING (logical_entry_id);
CREATE INDEX ON pm (product_id);
ANALYZE pm;

-- Allergens (/allergens) as a list: CAS or EC of the allergen rows.
CREATE TEMP TABLE allergen_id AS
SELECT DISTINCT 'CAS' AS id_type, t.value FROM relayx_raw.api_response r,
    jsonb_array_elements(r.body -> 'allergens') a, pg_temp.tokens(a ->> 'cas', 'CAS') AS t(value)
WHERE r.run_id = '20261019T174201Z_allergens_eu' AND r.http_status = 200
UNION
SELECT DISTINCT 'EC', t.value FROM relayx_raw.api_response r,
    jsonb_array_elements(r.body -> 'allergens') a, pg_temp.tokens(a ->> 'ec', 'EC') AS t(value)
WHERE r.run_id = '20261019T174201Z_allergens_eu' AND r.http_status = 200;

-- Strong INCI normalisation for item 5: upper case, every character that is not a letter or
-- digit removed (spaces, hyphens, brackets, punctuation).
CREATE FUNCTION pg_temp.inci_strong(t text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT nullif(regexp_replace(upper(t), '[^A-Z0-9]', '', 'g'), '')
$$;

-- The 806 conflict products of F1 c5, with their CAS-matched entries.
CREATE TEMP TABLE c_hit AS
SELECT DISTINCT i.product_id, i.value AS cas, r.logical_entry_id
FROM cov_id i JOIN rx_id r USING (id_type, value) WHERE i.id_type = 'CAS';
CREATE TEMP TABLE n_hit AS
SELECT DISTINCT i.product_id, r.logical_entry_id
FROM cov_id i JOIN rx_id r USING (id_type, value) WHERE i.id_type = 'INCI';
CREATE TEMP TABLE conflict AS
SELECT DISTINCT c.product_id FROM c_hit c
WHERE EXISTS (SELECT 1 FROM cov_id i WHERE i.product_id = c.product_id AND i.id_type = 'INCI')
  AND EXISTS (SELECT 1 FROM rx_id r WHERE r.logical_entry_id = c.logical_entry_id AND r.id_type = 'INCI')
  AND NOT EXISTS (SELECT 1 FROM c_hit c2 JOIN n_hit n USING (product_id, logical_entry_id) WHERE c2.product_id = c.product_id);

CREATE TEMP TABLE conflict_pair AS
SELECT c.product_id, c.cas, c.logical_entry_id, g.annex_ref, ci.value AS covalo_inci, ri.value AS relayx_inci,
       pg_temp.inci_strong(ci.value) = pg_temp.inci_strong(ri.value) AS strong_equal
FROM conflict k
JOIN c_hit c USING (product_id)
JOIN entry_group g USING (logical_entry_id)
JOIN cov_id ci ON ci.product_id = c.product_id AND ci.id_type = 'INCI'
JOIN rx_id ri ON ri.logical_entry_id = c.logical_entry_id AND ri.id_type = 'INCI';

-- REPORT

-- 2a. PROVISIONAL. Columns in schema covalo whose names contain inci, cas, einecs, ec_, iupac or composition
SELECT table_name, column_name, data_type FROM information_schema.columns
WHERE table_schema = 'covalo'
  AND (column_name ILIKE '%inci%' OR column_name ILIKE '%cas%' OR column_name ILIKE '%einecs%'
       OR column_name ILIKE '%ec\_%' OR column_name ILIKE '%iupac%' OR column_name ILIKE '%composition%')
ORDER BY 1, 2;

-- 2b. PROVISIONAL. jsonb columns in schema covalo with top-level keys matching the same terms
SELECT tbl, col, json_key, n AS rows_with_key FROM pg_temp.jsonb_key_scan() ORDER BY 1, 2, 3;

-- 2c. PROVISIONAL. Size of the identifier-less set and what product.identifiers holds for it
SELECT count(*) AS noid_products,
       count(*) FILTER (WHERE EXISTS (SELECT 1 FROM cov_raw r WHERE r.product_id = n.product_id)) AS raw_values_none_usable,
       count(*) FILTER (WHERE (SELECT bool_or(jsonb_typeof(n.identifiers -> k) = 'array' AND jsonb_array_length(n.identifiers -> k) > 0)
                               FROM unnest(array['fema', 'e', 'jecfa', 'flavis', 'coe']) k)) AS food_identifier_keys_nonempty,
       count(*) FILTER (WHERE (SELECT bool_and(jsonb_typeof(n.identifiers -> k) IS DISTINCT FROM 'array'
                                               OR jsonb_array_length(n.identifiers -> k) = 0)
                               FROM unnest(array['cas', 'ec', 'inci', 'iupac']) k)) AS cas_ec_inci_iupac_all_null_or_empty
FROM noid n;

-- 2d. PROVISIONAL. Identifier-less products reachable through each path, with the join used
SELECT 'product.identifiers {cas,ec,inci,iupac}: raw values, none usable' AS path,
       'product.id = noid.product_id' AS join_used, count(DISTINCT n.product_id) AS noid_products_reached
FROM noid n JOIN cov_raw r ON r.product_id = n.product_id
UNION ALL
SELECT 'product.identifiers {fema,e,jecfa,flavis,coe} (food keys, not used in F1)', 'same row',
       count(*) FROM noid n
WHERE (SELECT bool_or(jsonb_typeof(n.identifiers -> k) = 'array' AND jsonb_array_length(n.identifiers -> k) > 0)
       FROM unnest(array['fema', 'e', 'jecfa', 'flavis', 'coe']) k)
UNION ALL
SELECT 'product_formulation_item.properties.inci', 'properties.linked_product_detail.key = product.key OR .old_key = product.old_key',
       count(DISTINCT product_id) FROM noid_form WHERE via = 'explicit_link' AND src = 'product_formulation_item'
UNION ALL
SELECT 'product_attributes.properties.inci', 'properties.linked_product_detail.key = product.key OR .old_key = product.old_key',
       count(DISTINCT product_id) FROM noid_form WHERE via = 'explicit_link' AND src = 'product_attributes'
UNION ALL
SELECT 'either formulation table, explicit link', 'as above, union of both tables',
       count(DISTINCT product_id) FROM noid_form WHERE via = 'explicit_link'
UNION ALL
SELECT 'either formulation table, trade name (heuristic)', 'lower(trim(row value)) = lower(trim(product.trade_name)), no link',
       count(DISTINCT product_id) FROM noid_form WHERE via = 'trade_name'
UNION ALL
SELECT 'either formulation table, explicit link or trade name', 'union of the two joins above',
       count(DISTINCT product_id) FROM noid_form
UNION ALL
SELECT 'either formulation table, trade name and supplier = company name (heuristic)',
       'trade name as above AND lower(trim(properties.supplier)) = lower(trim(company.name))',
       count(DISTINCT n.product_id) FROM noid n JOIN covalo.company c ON c.id = n.company
       JOIN form_row f ON lower(btrim(f.row_name)) = lower(btrim(n.trade_name)) AND lower(btrim(f.supplier)) = lower(btrim(c.name))
UNION ALL
SELECT 'user_activity.search_filter chemicalComposition keys (user search filters, not product data)',
       'user_activity.product_id = product.id::text',
       count(DISTINCT n.product_id) FROM noid n JOIN covalo.user_activity u ON u.product_id = n.product_id::text
       WHERE u.search_filter::text ~* 'chemical_?composition';

-- 2e. PROVISIONAL. Identifier-less products by segment, and how many sit in each formulation path
SELECT cp.segment, count(*) AS noid_products,
       count(*) FILTER (WHERE n.product_id IN (SELECT product_id FROM noid_form WHERE via = 'explicit_link')) AS via_explicit_link,
       count(*) FILTER (WHERE n.product_id IN (SELECT product_id FROM noid_form WHERE via = 'trade_name')) AS via_trade_name,
       count(*) FILTER (WHERE n.product_id IN (SELECT product_id FROM noid_form)) AS via_either
FROM noid n JOIN cov_product cp USING (product_id) GROUP BY ROLLUP (cp.segment) ORDER BY 2 DESC;

-- 3a. PROVISIONAL. Distinct Covalo INCI and CAS values by best match class (mutually exclusive: printed > enriched only > catalogue only > neither)
SELECT id_type,
       count(*) AS distinct_values,
       count(*) FILTER (WHERE in_replay_literal) AS replay_as_printed,
       count(*) FILTER (WHERE in_replay AND NOT in_replay_literal) AS replay_enriched_only,
       count(*) FILTER (WHERE NOT in_replay AND in_catalogue) AS catalogue_only,
       count(*) FILTER (WHERE NOT in_replay AND NOT in_catalogue) AS neither
FROM cov_val WHERE id_type IN ('INCI', 'CAS') GROUP BY 1 ORDER BY 1;

-- 3b. PROVISIONAL. Products by best match class over their values of that type (same classes; products carrying the type)
WITH best AS (
    SELECT i.product_id, i.id_type,
           min(CASE WHEN v.in_replay_literal THEN 1 WHEN v.in_replay THEN 2 WHEN v.in_catalogue THEN 3 ELSE 4 END) AS cls
    FROM cov_id i JOIN cov_val v USING (id_type, value) WHERE i.id_type IN ('INCI', 'CAS') GROUP BY 1, 2)
SELECT id_type, count(*) AS products_with_type,
       count(*) FILTER (WHERE cls = 1) AS replay_as_printed,
       count(*) FILTER (WHERE cls = 2) AS replay_enriched_only,
       count(*) FILTER (WHERE cls = 3) AS catalogue_only,
       count(*) FILTER (WHERE cls = 4) AS neither
FROM best GROUP BY 1 ORDER BY 1;

-- 4a. PROVISIONAL. Coverage per annex or list: products found (any, as printed), distinct Covalo INCI found, products found only through it
WITH per AS (SELECT annex_group, scope_class, product_id, bool_or(provenance = 'literal') AS literal FROM pm GROUP BY 1, 2, 3),
     n_groups AS (SELECT product_id, count(DISTINCT annex_group) AS k FROM pm GROUP BY 1)
SELECT p.scope_class, p.annex_group,
       count(*) AS products_any, count(*) FILTER (WHERE p.literal) AS products_as_printed,
       (SELECT count(DISTINCT value) FROM pm x WHERE x.annex_group = p.annex_group AND x.id_type = 'INCI') AS distinct_inci_found,
       count(*) FILTER (WHERE g.k = 1) AS products_only_here
FROM per p JOIN n_groups g USING (product_id)
GROUP BY 1, 2 ORDER BY 1, 3 DESC;

-- 4b. PROVISIONAL. Allergen list (/allergens) as its own list: products whose CAS or EC is an allergen CAS or EC
SELECT count(DISTINCT i.product_id) AS products_any,
       count(DISTINCT i.value) FILTER (WHERE i.id_type = 'CAS') AS distinct_cas_found,
       count(DISTINCT i.value) FILTER (WHERE i.id_type = 'EC') AS distinct_ec_found
FROM cov_id i JOIN allergen_id a USING (id_type, value);

-- 4c. PROVISIONAL. Coverage per proposed scope class (REACH CMR appendices as their own group)
WITH per AS (SELECT scope_class, product_id, bool_or(provenance = 'literal') AS literal FROM pm GROUP BY 1, 2),
     n_cls AS (SELECT product_id, count(DISTINCT scope_class) AS k FROM pm GROUP BY 1)
SELECT p.scope_class,
       count(*) AS products_any, count(*) FILTER (WHERE p.literal) AS products_as_printed,
       (SELECT count(DISTINCT value) FROM pm x WHERE x.scope_class = p.scope_class AND x.id_type = 'INCI') AS distinct_inci_found,
       count(*) FILTER (WHERE c.k = 1) AS products_only_this_class
FROM per p JOIN n_cls c USING (product_id) GROUP BY 1 ORDER BY 1;

-- 4d. PROVISIONAL. Products by the highest class they reach (core > indirect > CMR appendices > marginal > not relevant)
SELECT top_class, count(*) AS products,
       count(*) FILTER (WHERE literal) AS as_printed
FROM (SELECT product_id, min(scope_class) AS top_class,
             bool_or(provenance = 'literal' AND scope_class = (SELECT min(scope_class) FROM pm p2 WHERE p2.product_id = pm.product_id)) AS literal
      FROM pm GROUP BY product_id) x
GROUP BY ROLLUP (top_class) ORDER BY 1 NULLS LAST;

-- 5a. PROVISIONAL. The conflict set (F1 c5) split by strong INCI normalisation
SELECT count(*) AS conflict_products,
       count(*) FILTER (WHERE agrees) AS a_agrees_after_strong_normalisation,
       count(*) FILTER (WHERE NOT agrees) AS b_still_differs
FROM (SELECT k.product_id, coalesce(bool_or(p.strong_equal), false) AS agrees
      FROM conflict k LEFT JOIN conflict_pair p USING (product_id) GROUP BY 1) x;

-- 5b. PROVISIONAL. Ten examples of (a): Covalo INCI, Relay X INCI, CAS, annex
SELECT DISTINCT ON (product_id) product_id, covalo_inci, relayx_inci, cas, annex_ref
FROM conflict_pair WHERE strong_equal
ORDER BY product_id, covalo_inci LIMIT 10;

-- 5c. PROVISIONAL. Ten examples of (b): all Covalo INCI and all Relay X INCI values of the CAS-matched entries, CAS, annex
SELECT p.product_id, string_agg(DISTINCT p.covalo_inci, ' | ') AS covalo_inci,
       left(string_agg(DISTINCT p.relayx_inci, ' | '), 160) AS relayx_inci_all,
       string_agg(DISTINCT p.cas, ' | ') AS cas, string_agg(DISTINCT p.annex_ref, ' | ') AS annex_ref
FROM conflict_pair p
WHERE p.product_id NOT IN (SELECT product_id FROM conflict_pair WHERE strong_equal)
GROUP BY p.product_id ORDER BY p.product_id LIMIT 10;

-- 5d. PROVISIONAL. Group (b) by annex of the CAS-matched entry
SELECT annex_ref, count(DISTINCT product_id) AS products
FROM conflict_pair WHERE product_id NOT IN (SELECT product_id FROM conflict_pair WHERE strong_equal)
GROUP BY 1 ORDER BY 2 DESC
