# 2026-10-22 F3 part 2b: tier sizing and validation sample (PROVISIONAL)

Local only, read-only as relayx_app, TEMP objects only, no extensions, no API calls, no joins to
relayx_raw.
`python -m relayx.provisional_report sql/provisional/f3_cosing_bridge.sql --setup sql/provisional/f1_matching_assessment.sql --param cosing_table=kevin.cosing_ingredients`
(sections q13 to q16; rules in the SQL header, "Rules, part 2b"). Part 2 sections q0 to q12
reproduce unchanged in the same run. CosIng: Wayback snapshot, latest update 2020-12-15, capture
date PENDING. Figures for all CosIng rows; excl. fragr. (without rows whose only functions are
PERFUMING or FRAGRANCE) in brackets.

## Definitions as applied
- Mapping = (Covalo INCI F1 value, valid CosIng number), from the CosIng rows the INCI matched at
  its best level. Valid = passes the check digit.
- Sharing = distinct CosIng INCI carrying the number within the reference set, counted on the L1
  key (case, spaces, U+00A0). Part 2 q8 counted on lower(btrim); the two differ only for CosIng
  INCI that differ in internal whitespace.
- Generic = "(generic)" follows the number on any CosIng row of the reference set.
- Tier order: T3 is tested first (sharing > 10 or generic), then T1, else T2. So a generic number
  is T3 even when its sharing is 10 or less.

## 1. INCI level
Distinct Covalo INCI with at least one valid CosIng number, by INCI-level tier (of 8,526 matched;
8,045 excl. fragr.). Product links = sum of products carrying those INCI (all products, not only
gain products).

| Tier | CAS INCI | CAS product links | CAS mappings | EC INCI | EC product links | EC mappings |
|---|---|---|---|---|---|---|
| T1 | 2,362 (2,237) | 38,284 | 2,362 | 1,667 (1,549) | 34,296 | 1,667 |
| T2 | 2,529 (2,309) | 47,672 | 3,242 | 1,896 (1,717) | 37,670 | 2,213 |
| T3 | 790 (692) | 5,229 | 962 | 356 (234) | 4,074 | 381 |
| Total | 5,681 (5,238) | | 6,566 | 3,919 (3,500) | | 4,261 |

- Matched INCI without a valid CosIng number: CAS 2,845 (2,807), EC 4,607 (4,545).
- Reasons for T2 mappings (not exclusive), CAS / EC: level L2 or L3 567 / 336; INCI has several
  numbers 1,334 / 560; sharing 2 to 10 2,089 / 1,667.

Mappings by number of CosIng INCI sharing the number (all rows):

| Sharing | CAS mappings | CAS distinct INCI | CAS distinct numbers | EC mappings | EC distinct INCI | EC distinct numbers |
|---|---|---|---|---|---|---|
| 1 | 3,524 | 3,097 | 3,127 | 2,213 | 2,030 | 1,979 |
| 2 to 3 | 985 | 915 | 610 | 660 | 626 | 412 |
| 4 to 10 | 1,247 | 1,208 | 363 | 1,007 | 970 | 282 |
| 11 to 50 | 761 | 722 | 71 | 381 | 361 | 45 |
| more than 50 | 49 | 49 | 1 | 0 | 0 | 0 |

The only CAS on more than 50 CosIng INCI is 9003-11-6 (poloxamers). Sharing 1 holds 3,524 CAS
mappings, but 1,162 of them are not T1 (INCI with several numbers, matched at L2/L3, or generic).

## 2. Product level (gain class: Covalo has no number of that type)
Best tier over the INCI that contribute a gained number; "all from T1" = every contributing INCI
is T1. No gain product lacks a tier. Best-tier columns are for all rows only.

| Products | Gain | Best T1 | Best T2 | Best T3 | All from T1 |
|---|---|---|---|---|---|
| CAS, single INCI | 14,785 (14,246) | 5,437 | 7,274 | 2,074 | 5,437 (5,473) |
| CAS, blend | 15,186 (15,164) | 11,098 | 4,000 | 88 | 2,035 (2,080) |
| CAS, total | 29,971 (29,410) | 16,535 | 11,274 | 2,162 | 7,472 (7,553) |
| EC, single INCI | 17,674 (16,560) | 7,096 | 8,416 | 2,162 | 7,096 (7,093) |
| EC, blend | 18,457 (18,401) | 12,825 | 5,425 | 207 | 3,201 (3,237) |
| EC, total | 36,131 (34,961) | 19,921 | 13,841 | 2,369 | 10,297 (10,330) |

- Single-INCI products with a T1 CAS: 5,437 of 14,785 (36.8 %). This is the cleanest candidate
  group for Q4.
- Blends: 11,098 have at least one T1 INCI, but only 2,035 have all gained CAS from T1 INCI. Even
  then the CAS set describes the components of a mixture, not the product.
- Excluding fragrance-only rows changes the all-from-T1 counts by 2.2 % or less.

## 3. Validation sample
- File: data/validation/f3_tier_sample.csv (gitignored), 120 rows: 60 T1, 40 T2, 20 T3 CAS
  mappings, all CosIng rows, one weight per mapping, seed 20261022 (order by
  md5('20261022' || covalo_inci || '|' || cas) within tier). SHA-256
  BEEEF7049559818229B9300944B56471D053B4C07D8502A3E542C1BB48402DAF.
- Produced from section q16 of the report output (TSV) with a CSV writer; UTF-8, no non-ASCII
  characters in this sample. verdict and note are empty.
- Column notes: cosing_inci, cosing_ref_no and cosing_chem_name list all CosIng rows that support
  the mapping (" | " separated); ec lists the valid EC numbers on those rows, not an EC paired to
  the CAS; covalo_products counts all products carrying the Covalo INCI; mapping tier, not
  INCI-level tier.

## Observations (not validated)
- In the sample, T2 contains two different kinds: specific numbers with sharing 1 on INCI that
  carry several CAS (e.g. TOCOPHEROL, CI 45380, ZINC SULFATE) and botanical extract numbers shared
  by 2 to 10 plant-part INCI. The second kind looks closer to T3.
- T3 also contains numbers flagged generic with low sharing (e.g. sharing 2).

## Open points
- Kevin labels the sample; the verdicts decide whether T1 (and which part of T2) is usable for Q4.
- Conflict rule (1,209 CAS products) still open from part 2.
