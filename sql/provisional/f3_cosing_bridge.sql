-- PROVISIONAL. F3 CosIng bridge (docs/plans/2026-10-20-f3-cosing-bridge.md). Part 1: profile (Q1).
-- Read-only; TEMP objects only; no joins to covalo or relayx_raw in this part.
-- The CosIng table is a parameter, so a current export can replace the Wayback snapshot:
--   python -m relayx.provisional_report sql/provisional/f3_cosing_bridge.sql --param cosing_table=kevin.cosing_ingredients
--
-- Rules:
--   Blank = NULL, empty or whitespace only. Placeholder = non-blank value with no digit (e.g. "-").
--   CAS / EC tokens: same extraction as F1 (en dashes and spaces around hyphens normalised;
--     CAS (?<!\d)\d{2,7}-\d{2}-\d(?!\d), EC (?<!\d)\d{3}-\d{3}-\d(?!\d)); check digits as in F1.
--   Residue = what is left of a CAS or EC value after removing tokens and whitespace.
--   INCI duplicate after normalisation: lower(btrim(inci_name)).

CREATE TEMP VIEW src AS SELECT * FROM {{cosing_table}};

CREATE FUNCTION pg_temp.prep(t text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT regexp_replace(translate(t, E'–—‐‑−', '-----'), '\s*-\s*', '-', 'g')
$$;

CREATE FUNCTION pg_temp.tokens(t text, kind text) RETURNS SETOF text LANGUAGE sql IMMUTABLE AS $$
    SELECT m[1] FROM regexp_matches(pg_temp.prep(t),
        CASE kind WHEN 'CAS' THEN '(?<!\d)(\d{2,7}-\d{2}-\d)(?!\d)'
                  ELSE '(?<!\d)(\d{3}-\d{3}-\d)(?!\d)' END, 'g') AS m
$$;

CREATE FUNCTION pg_temp.residue(t text, kind text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT btrim(regexp_replace(regexp_replace(pg_temp.prep(t),
        CASE kind WHEN 'CAS' THEN '(?<!\d)\d{2,7}-\d{2}-\d(?!\d)' ELSE '(?<!\d)\d{3}-\d{3}-\d(?!\d)' END, ' ', 'g'),
        '\s+', ' ', 'g'))
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
WHERE update_date ~ '^\d{2}/\d{2}/\d{4}$' GROUP BY 1 ORDER BY 1 DESC LIMIT 5
