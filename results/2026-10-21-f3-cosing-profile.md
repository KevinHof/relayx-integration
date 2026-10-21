# 2026-10-21 F3 part 1: CosIng snapshot profile, Q1 (PROVISIONAL)

Local only, read-only as relayx_app, TEMP objects only, no API calls, no joins to covalo or
relayx_raw. Plan: docs/plans/2026-10-20-f3-cosing-bridge.md.
- Reconciliation: `python -m relayx.cosing_reconcile data/cosing/cosing_clean.csv --table kevin.cosing_ingredients`
- Profile: `python -m relayx.provisional_report sql/provisional/f3_cosing_bridge.sql --setup sql/provisional/f1_matching_assessment.sql --param cosing_table=kevin.cosing_ingredients`
  (sections p1 to p20; since part 2 the file reuses the F1 parser, hence `--setup`)

## Source and caveats
CosIng Ingredients-Fragrance Inventory export, Wayback Machine capture (older snapshot, not
the current CosIng). Capture URL and capture date: PENDING. Whether the file was cleaned
after capture: not recalled (Kevin, 2026-10-21); Kevin considers it accurate.
- CosIng is a non-binding information database. The current legal INCI list is the
  Glossary of common ingredient names, Commission Implementing Decision (EU) 2025/1175,
  which carries no CAS. CosIng CAS values can be multiple or refer to related forms.
- An INCI absent from the snapshot may have been added to CosIng or the Glossary after the
  capture date. The Q5 flag is worded "found / not found in CosIng snapshot of <capture
  date>", never "valid / invalid INCI". Q6 non-matches may reflect entries newer than the
  snapshot.
- Snapshot date lower bound: latest `update_date` in the file is 2020-12-15.

## Provenance and reconciliation
| Item | Value |
|---|---|
| File | data/cosing/cosing_clean.csv (not data/reference/cosing/, which is empty) |
| Size, SHA-256 | 5,859,404 bytes, 6cb1a58cc94d640e7cf2354c4a4b607d177362198587c5f8b39c12db3c6441d4 |
| Encoding, delimiter | UTF-8 without BOM, comma; quoted fields; no embedded line breaks |
| Lines before the header | none; the file states no export date |
| Data rows | 28,712 (28,713 physical lines incl. header), all 10 fields wide |
| Table | kevin.cosing_ingredients, 28,712 rows, readable by relayx_app |

Columns map one to one by position: COSING Ref No > cosing_ref_no (integer), INCI name >
inci_name, INN name > inn_name, Ph. Eur. Name > ph_eur_name, CAS No > cas_no, EC No > ec_no,
Chem/IUPAC Name / Description > chem_iupac_name, Restriction > restriction, Function >
function, Update Date > update_date (all text). Keyed on the reference number: every row is
in both, no duplicates, and 0 values differ in any column (CAS, EC and INCI included; leading
spaces kept). Empty fields in the file are NULL in the table only where the file field is
empty; whitespace-only fields are kept as whitespace.

## Profile (Q1)
Reference number `cosing_ref_no`: unique, no NULL, 31,364 to 98,850.

Cosmetic ingredients vs Fragrance Inventory: no column marks the distinction. The only
indicator is `function`: PERFUMING on 2,717 rows, FRAGRANCE on 1,338, and 2,712 rows carry
only PERFUMING or FRAGRANCE. Using that as a split is not validated. 218 rows have no
function; 481 say NOT REPORTED.

Fill rates (value present, not blank): INCI 28,712; CAS 18,200 (of which 4,091 the placeholder
"-"); EC 15,030 (5,455 placeholders "-", " - ", "- / -", ","); chem/IUPAC 28,227; restriction
1,881; INN 519; Ph. Eur. 183; update date 28,712.

INCI:
| Measure | Rows |
|---|---|
| Distinct exact / after lower-case and trim | 28,707 / 28,705 |
| Values duplicated exact / after lower-case and trim | 5 / 7 (14 rows) |
| Leading or trailing space | 483 |
| Double space | 11 |
| Non-ASCII | 20 rows: U+00A0 no-break space (21 times), U+00D7 multiplication sign (1) |
| Contains "/" | 3,929 (mostly valid INCI: copolymers, ferments, mixed extracts) |
| Contains ";" / " and " | 0 / 2 (TERPENES AND TERPENOIDS, ... SINPINE) |
| Not upper case | 0 |
Duplicate examples: CITRUS NOBILIS PEEL EXTRACT, HYDROGENATED PALM KERNEL OIL, METHOXYETHANOL,
SH-POLYPEPTIDE-40, PRUNUS AMYGDALUS DULCIS SHELL EXTRACT, LACTOBACILLUS/RADISH ROOT FERMENT
FILTRATE, PPG-70 BIS-(2-AMINOPROPYL) ETHER.

CAS and EC (every non-blank value starts with a space):
| Measure | CAS | EC |
|---|---|---|
| With a real value | 14,109 | 9,575 |
| One number / several numbers | 13,093 / 1,014 | 9,203 / 369 |
| Value with no valid number | 2 (`31916`; `201-642-6`, an EC) | 3 (`29-750-0`, `208-021-`, `85-91-6`, a CAS) |
| One number plus extra text | 134 | 448 |
| Distinct numbers | 10,968 | 7,128 |
| Distinct numbers failing the check digit | 39 | 30 |
| Numbers on more than one INCI | 1,363 | 955 |

Separators and qualifiers left after removing numbers: CAS "/" (754 rows), "(generic)" or
"(Generic)" (125), ",", ";", "---", "(free base)"; EC "/", "/-" and "-/" (mixed with
placeholders), "(I)" (121), "(L)" (14), "*" prefix (e.g. `*614-341-3`, 24), "(EINECS)", "--".
Numbers on most INCI: CAS 9003-11-6 (75 INCI), 25322-68-3 (47), 68439-49-6 (34); EC
284-511-6 (25), 285-379-2 (24). Generic polymer and extract CAS numbers are shared by many
INCI, so a CAS from CosIng does not identify one substance.
Check-digit failure examples: CAS 23749-19-7, 8006-90-6, 136-17-7, 7446-19-7 / 7733-02-0 /
7746-20-0; EC 423-420-1, 146-420-6, 221-761-2, 200-390-6.

Restriction column (1,881 rows with a value): annex and entry references in the form
`II/123`, `III/45a`, `Annex III/1`, several per row possible, some with free text (hair dye
conditions, narcotics, refining history). Rows citing: Annex II 821, III 777, IV 188, V 144,
VI 33. Not compared with Relay X (legal accuracy track).

Update date: all dd/mm/yyyy, 2010-10-15 to 2020-12-15. Rows per year: 2010 15,822; 2011
2,751; 2012 723; 2013 720; 2014 1,833; 2015 796; 2016 1,347; 2017 197; 2018 1,536; 2019
1,521; 2020 1,466. Latest dates have 1 or 2 rows each (2020-12-15, -11, 11-30, 11-26, 11-18).

Examples (10 per irregular pattern) for INCI, CAS and EC are in sections p7, p8 and p14 of
the query output.

## Points for review before Q2
- Normalisation for Q2: trim, collapse spaces, replace U+00A0 with a space; "/" is not a
  multi-INCI separator in CosIng.
- CAS and EC parsing: tokens as in F1; treat "-" and "," as placeholders; ignore qualifiers
  "(generic)", "(I)", "(L)", "*".
- Fragrance Inventory rows cannot be separated reliably; decide whether the function proxy
  is acceptable or whether all rows are treated alike.
- Capture URL and capture date still PENDING.
