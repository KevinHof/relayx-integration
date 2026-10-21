# 2026-10-21 F3 part 2: Covalo INCI against CosIng (Q2), bridge (Q3), referee flag (Q5) (PROVISIONAL)

Local only, read-only as relayx_app, TEMP objects only, no extensions installed, no API calls.
`python -m relayx.provisional_report sql/provisional/f3_cosing_bridge.sql --setup sql/provisional/f1_matching_assessment.sql --param cosing_table=kevin.cosing_ingredients`
(sections q0 to q12; rules in the SQL header). Covalo side: F1 objects unchanged. CAS and EC on
both sides: the F1 parser (the F3 file no longer carries its own copy). CosIng: Wayback
snapshot, latest update 2020-12-15, capture date PENDING. Every figure is given for all CosIng
rows ("all") and without rows whose only functions are PERFUMING or FRAGRANCE ("excl. fragr.").
Q4 and Q6 not started.

## 0. Target population
Active ingredients with a usable Covalo INCI and no usable Covalo CAS: 36,496 products, 11,385
distinct INCI (14 of them carry a Covalo EC).

## 1. Q2 INCI matching (cumulative; distinct = F1 INCI value, its level = best of its raw strings; product = at least one INCI matched)
| Level | Distinct INCI new, all | cum., all | Products cum., all | Target cum., all | Distinct cum., excl. fragr. | Products cum., excl. fragr. | Target cum., excl. fragr. |
|---|---|---|---|---|---|---|---|
| L0 trim | 7,607 | 7,607 | 45,287 | 30,884 | 7,149 | 43,852 | 30,156 |
| L1 case, spaces, U+00A0, U+00D7 | 280 | 7,887 | 48,886 | 33,652 | 7,420 | 47,406 | 32,910 |
| L2 punctuation, hyphens, brackets, spaces removed | 635 | 8,522 | 49,268 | 33,878 | 8,041 | 47,775 | 33,135 |
| L3 split on ";" and "," | 4 | 8,526 | 49,270 | 33,880 | 8,045 | 47,777 | 33,137 |
| Total | | 13,912 | 53,062 | 36,496 | 13,912 | 53,062 | 36,496 |

Share found in the snapshot: 61.3 % of distinct Covalo INCI (57.8 % excl. fragr.); 92.9 % of
products with INCI (90.0 %); 92.8 % of the target population (90.8 %).
- L3: 5 raw strings were split (21 components): 4 all matched, 1 partly, 0 none. 6,051 raw
  strings unmatched at L2 contain no ";" or "," outside numbers. Few Covalo values use these
  separators; "+" and "/" are not split.
- Unmatched: 5,386 distinct INCI (9,328 product links); excl. fragr. 5,867 (11,371). Products
  with no INCI found: 3,792 (5,285); target products 2,616 (3,359). Products with every INCI
  found: 46,292 (44,371).
- Fragrance-only rows: 481 Covalo INCI (2,043 product links) are found only through rows whose
  only functions are PERFUMING or FRAGRANCE.
- Duplicate CosIng INCI: all rows kept; a Covalo INCI matching duplicates carries all their
  reference numbers.
- Sample of 50 unmatched (seed 20261021): `pg_trgm` is not installed, so no nearest CosIng INCI
  is given. Patterns seen in the sample, not counted: spelling errors (METHYPARABEN, SODIUM
  HYALURONAT, LSOPROPYL ALCOHOL, CI 177492), synonyms or older names (LAURYL DIMETHYL BETAINE,
  BUTYLATED HYDROXY TOLUENE, GLYCERYL MONO STEARATE, MATRICARIA RECUTITA FLOWER EXTRACT),
  truncated fragments (DIMETHICONE/VIN, SACCHARO, VA, MANGANESE-DOPED), several INCI in one
  value (CETEARYL GLUCOSIDE/CETEARYL ALCOHOL, ISOPROPYL MYRISTATE + ISOPROPYL PALMITATE (25-40)),
  chemical or common names (L-HISTIDINE MONOHYDROCHLORIDE MONOHYDRATE, COCONUT FATTY ACID),
  non-INCI text (PROPANEDIOL FORMULATION GUIDELINES), label forms with a common name
  (THEOBROMA CACAO (COCOA) SEED EXTRACT), and plausible INCI that may be newer than the
  snapshot or named differently (DIPEPTIDE DIAMINOBUTYROYL BENZYLAMINE DIACETATE, CINNAMOMUM
  BURMANNII BARK OIL). Full sample: section q5 of the query output.

## 3. Q3 bridge (products with at least one INCI found; classes per identifier type)
| Class | CAS products, all | of which L0 / L1 / L2 / L3 | Distinct INCI | CAS products, excl. fragr. | EC products, all | EC products, excl. fragr. |
|---|---|---|---|---|---|---|
| Agree (sets overlap) | 13,401 | 12,569 / 711 / 121 / 0 | 4,515 | 12,789 | 1,611 | 1,582 |
| Conflict (both, no overlap) | 1,209 | 1,134 / 58 / 17 / 0 | 759 | 1,086 | 83 | 80 |
| Gain (Covalo none, CosIng some) | 29,971 | 27,276 / 2,547 / 146 / 2 | 7,960 | 29,410 | 36,131 | 34,961 |
| Covalo only (CosIng none) | 780 | 700 / 62 / 18 / 0 | 517 | 765 | 182 | 182 |
| Neither | 3,909 | 3,608 / 221 / 80 / 0 | 1,940 | 3,727 | 11,263 | 10,972 |
| Total | 49,270 | | | 47,777 | 49,270 | 47,777 |
"Covalo only" is a fifth class added because the four requested classes do not cover it.
Distinct INCI counts the Covalo INCI on the products of a class (an INCI can sit in several
classes). All CAS gain and neither products are target products.

- CAS agreement where both sides have CAS: 13,401 of 14,610 (91.7 %); EC 1,611 of 1,694.
- Check-digit failures excluded: CAS 15 distinct values reached by 121 products (11 products
  lose all CosIng CAS through this); EC 11 values, 601 products (19 lose all).
- Ambiguity in the CAS gain group (29,971 products): a gained CAS sits on more than one CosIng
  INCI for 19,866 products and on more than 10 for 3,885; 330 are flagged "(generic)"; 17,125
  gain more than one CAS; 15,186 carry several Covalo INCI (blends), so their CAS set describes
  a mixture, not one substance. EC gain (36,131): more than one CosIng INCI 23,505, more than 10
  3,619. "More than one" includes pairs such as AQUA and WATER (7732-18-5 sits on 2 CosIng
  INCI); "more than 10" is the stronger signal (e.g. 9003-11-6 on 75 INCI).
- Conflict examples (Covalo INCI: Covalo CAS vs CosIng CAS): LANOLIN 8007-54-0 vs 8006-54-0;
  SODIUM LAURYL SULFATE 85586-07-8 vs 151-21-3; STEARYL TRIETHOXYSILANE 13463-67-7 (titanium
  dioxide) vs 7399-00-0; POLYQUATERNIUM-10 68610-92-7 vs 68610-92-4 and four others; GLYCERYL
  RICINOLEATE 68459-67-6 vs 1323-38-2, 141-08-2; ELAEIS GUINEENSIS OIL 90990-15-1 vs
  8002-75-3; GLYCERYL STEARATE 91052-47-0 vs 31566-31-1; LAURETH-12 68439-50-9 vs 3056-00-6,
  9002-92-0. The examples mix Covalo typos, wrong CAS on Covalo, and alternative CAS for the
  same INCI. Full list: section q9.
- Ambiguous gain examples: POLOXAMER 402 via 9003-11-6 (75 CosIng INCI); ROSA DAMASCENA EXTRACT
  via 90106-38-0 (12); HIBISCUS SABDARIFFA SEED OIL via 84775-96-2 (7); blends of 5 to 8 INCI
  gaining one CAS per component. Full list: section q10.

## 4. Q5 referee flag
Defined as the query view `f3_referee_flag` in the SQL file (not stored): one row per Covalo
INCI and reference set, flag "found in CosIng snapshot" with level L0 to L3, or "not found in
CosIng snapshot". Counts equal the level table above (all: 7,607 / 280 / 635 / 4 found,
5,386 not found). Wording follows the plan: the snapshot is from 2020 or later and the capture
date is PENDING; "not found" is not "invalid".

## Caveats
CosIng is non-binding; the legal INCI list is the Glossary, Commission Implementing Decision
(EU) 2025/1175, without CAS. Snapshot, not current CosIng: INCI added later are "not found".
CosIng CAS can be multiple, generic or refer to related forms. A gained CAS identifies a
substance only when the product has one INCI and the CAS is specific to that INCI.

## Open points
- Decide which gain counts as usable for Q4: e.g. only single-INCI products, CAS on at most N
  CosIng INCI, no "(generic)".
- Conflicts (1,209 products) need a rule before F4: Covalo CAS kept, CosIng CAS kept, or flagged.
