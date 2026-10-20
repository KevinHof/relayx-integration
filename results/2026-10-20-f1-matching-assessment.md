# 2026-10-20 Fast-track F step 1: provisional matching assessment (PROVISIONAL)

Local only, no API calls. `python -m relayx.provisional_report sql/provisional/f1_matching_assessment.sql`
(TEMP objects only, about 11 s). Rules are in the SQL header. All figures are exact
identifier matches after light normalisation: a lower bound for INCI and names, and a
match means "the identifier appears in a Relay X entry", not "the product is restricted".

## a. Covalo identifiers (active products: not trashed, enabled, company not trashed)
116,938 products: 112,649 INGREDIENTS, 3,924 FORMULATIONS, 365 SERVICES.
70,664 have a usable identifier (all INGREDIENTS); 46,274 have none (41,985 ingredients,
of which 363 carry raw identifier values that yield nothing usable; formulations and
services carry none).

| Type | Distinct values | Product links | Check digit fails |
|---|---|---|---|
| CAS | 6,766 | 49,219 | 227 |
| EC | 1,567 | 5,159 | 34 |
| INCI | 13,912 | 111,892 | n/a |
| NAME (iupac) | 1,519 | 1,984 | n/a |

CAS raw elements 46,747: 43,968 single, 2,055 multi-value (`/`, `,`, `;`, `oder`), 157 with
residue, 567 unparsed (`MIXTURE`, `Proprietary`, malformed like `68647-73-41`). EC: 11 of 5,162
unparsed. `kevin.covalo_identifiers_long` has 8,400 distinct CAS (raw strings incl. junk; its
build script is not in the repo); this rebuild supersedes it for the assessment.

## b. Overlap with the replay and the Relay X catalogue
Relay X positional strings (current entries): CAS 7,126 distinct strings, 4 unparsed and 8
with residue (e.g. `(3) 67701-36-4`, `68477-83-8$`, `7085-19-0 [1] 708519-0 [2]`, `... and
others`); EC 6,632, 16 unparsed and 7 with residue. 88 enriched EC values fail the EC check
digit (65 start with 4). 216 entry versions flag `identifiersTruncated` on a linked substance.

| Covalo type | Distinct | In replay (literal) | In replay (any) | In catalogue | In neither |
|---|---|---|---|---|---|
| CAS | 6,766 | 964 | 1,012 | 1,758 | 5,006 |
| EC | 1,567 | 284 | 289 | 506 | 1,055 |
| INCI | 13,912 | 476 | 973 | 1,791 | 12,118 |
| NAME | 1,519 | 102 | 134 | 118 | 1,335 |

## c. Provisional coverage (products with at least one identifier found in the replay)
| Type | Products with type | Found (any) | Found (literal) |
|---|---|---|---|
| Any | 70,664 | 24,677 (34.9 %) | 21,179 |
| CAS | 33,427 | 10,766 | 10,568 |
| EC | 3,219 | 980 | 975 |
| INCI | 53,062 | 19,140 | 14,247 |
| NAME | 1,853 | 177 | 132 |
Share of all 116,938 active products: 21.1 %. Ingredients in personal care: 23,775 of
66,381 with a usable identifier.

Reading the 24,677:
- 5,683 match only EXEMPTION or INVENTORY_LISTED entries (e.g. WATER, AQUA, 7732-18-5 hit the
  "Exemptions" entry 26). By annexType: RESTRICTED 11,220, CLP_HARMONISED 9,371, EXEMPTION
  8,822, COLORANT 6,181, PROHIBITED 4,822, UV_FILTER 3,739, PRESERVATIVE 3,206.
- 10,323 match through at least one GROUP entry. Fan-out: 10,154 products hit 1 entry,
  6,546 hit 2 to 3, 6,990 hit 4 to 10, 987 hit more than 10.
- Concentration: without the 20 most frequent matched values, 18,003 products remain.
- Conflict indicator: of 5,975 products whose CAS hits an entry where both sides carry INCI,
  806 have no INCI match on any of those entries (spelling or real conflict, not yet split).

## d. Per-substance source list including Covalo identifiers
Compared by identifier value with the current list (replay identifiers incl. enriched,
plus catalogue): 19,514 Covalo values are new (CAS 5,006, EC 1,055, INCI 12,118, NAME 1,335);
8,718 of them sit on two or more products. 32,693 products have only new values.
Unit cost: one unit per item. All 23,764 Covalo values: about 23,800 units (6.6 h at 60/min);
the 19,514 new ones alone: about 19,500 units (5.4 h). Combined with the existing list
(about 16,000): about 35,500 lookup units.

## Open points
- Step 2 plan: docs/plans/2026-10-20-f2-covalo-lookup.md (awaits approval).
- Relay X data quality for VE: malformed printed CAS/EC strings, 88 EC values failing the
  check digit, `and others` truncation in printed lists.
- Not yet run: opinions validation sample, impurity-limits contaminant check (approved).
