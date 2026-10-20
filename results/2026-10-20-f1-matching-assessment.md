# 2026-10-20 Fast-track F step 1: provisional matching assessment (PROVISIONAL)

Local only, no API calls. `python -m relayx.provisional_report sql/provisional/f1_matching_assessment.sql`
(TEMP objects only, about 11 s). Rules are in the SQL header. All figures are exact
identifier matches after light normalisation: a lower bound for INCI and names, and a
match means "the identifier appears in a Relay X entry", not "the product is restricted".

## Sources and rules
Copied from the header of `sql/provisional/f1_matching_assessment.sql`:

```
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
```

Exact definitions in the same file (verbatim fragments):

| Item | Source tables and columns, code |
|---|---|
| Active products | `FROM covalo.product p JOIN covalo.company c ON c.id = p.company WHERE NOT p.trashed AND p.enabled AND NOT c.trashed` |
| Identifier types | `covalo.product.identifiers` keys `('cas', 'CAS'), ('ec', 'EC'), ('inci', 'INCI'), ('iupac', 'NAME')`, only when `jsonb_typeof(p.identifiers -> k.key) = 'array'`, elements with `jsonb_typeof(e) = 'string'` |
| Pre-cleaning (CAS, EC) | `regexp_replace(translate(t, E'–—‐‑−', '-----'), '\s*-\s*', '-', 'g')` |
| CAS token | `(?<!\d)(\d{2,7}-\d{2}-\d)(?!\d)`, check digit: weighted sum of digits mod 10 |
| EC token | `(?<!\d)(\d{3}-\d{3}-\d)(?!\d)`, check digit: weighted sum of first six digits mod 11 |
| INCI | `nullif(upper(regexp_replace(btrim(t), '\s+', ' ', 'g')), '')` |
| NAME | `nullif(lower(regexp_replace(btrim(t), '\s+', ' ', 'g')), '')` |
| Relay X INCI and NAME strings | split on `'\s*\[\d+\]\s*|;'` before normalisation |
| Catalogue | `kevin.relayx_eu_identifiers_v2`: `cas_number`, `ec_number` (tokens as above), `inci_name` and `inci_name_us` split on `'\s*\|\s*'`, `substance_name` as NAME |

F1b additions (`sql/provisional/f1b_additions.sql`) use the same objects plus, for item 5,
`regexp_replace(upper(t), '[^A-Z0-9]', '', 'g')` as strong INCI normalisation.

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

## F1b additions (2026-10-20, all figures PROVISIONAL)
`python -m relayx.provisional_report sql/provisional/f1b_additions.sql --setup sql/provisional/f1_matching_assessment.sql`
(about 1 min, TEMP objects only).

### Identifier-less ingredients (41,985): identifiers elsewhere in schema covalo
Column names containing inci, cas, einecs, ec_, iupac or composition: one, and it is not an
identifier (`user_registration_request.special_case`, jsonb, matches "cas" inside "special_case").
Top-level JSONB keys with those terms: `product.identifiers` (cas, ec, inci, iupac),
`product_attributes.properties.inci` (35,663 rows), `product_formulation_item.properties.inci`
(35,916 rows), `user_activity.search_filter` (`metadata.chemicalComposition_multi_string`,
`metadata.chemical_composition_multi_string`).

| Path | Join | Products of the 41,985 reached |
|---|---|---|
| product.identifiers cas, ec, inci, iupac: all null or empty | same row | 41,622 |
| product.identifiers cas, ec, inci, iupac: values present, none usable | same row | 363 |
| product.identifiers fema, e, jecfa, flavis, coe (food keys, not used in F1) | same row | 74 |
| product_formulation_item.properties.inci | `properties.linked_product_detail.key = product.key OR .old_key = product.old_key` | 272 |
| product_attributes.properties.inci | same | 30 (all within the 272) |
| either formulation table, trade name (heuristic) | `lower(trim(row value)) = lower(trim(product.trade_name))` | 1,308 |
| either formulation table, explicit link or trade name | union | 1,318 |
| trade name and supplier = company name (heuristic) | as above plus supplier match | 202 |
| user_activity.search_filter | `user_activity.product_id = product.id::text`; these are users' search filters, not product data | 0 |

Both INCI-bearing tables hold formulation tables of FORMULATIONS products (INCI of each
ingredient row). By segment the 41,985 are PERSONALCARE 35,154, FOOD 3,896, HOMECARE 2,617,
LUBRICANTS 317, CERAMICS 1; 1,260 personal-care products are reachable through a formulation
row. Reading: the identifier-less count reflects the source data (41,622 products have no
value in cas, ec, inci or iupac), not the extraction. At most about 3 % could gain an INCI through
formulation rows. Not added to the matching.

### Distinct values next to products (INCI and CAS, best class per value or product)
| Unit | Type | Total | Replay as printed | Replay enriched only | Catalogue only | Neither |
|---|---|---|---|---|---|---|
| Distinct values | CAS | 6,766 | 964 | 48 | 748 | 5,006 |
| Products | CAS | 33,427 | 10,568 | 198 | 6,594 | 16,067 |
| Distinct values | INCI | 13,912 | 476 | 497 | 821 | 12,118 |
| Products | INCI | 53,062 | 14,247 | 4,893 | 10,119 | 23,803 |

Enriched identifiers matter for INCI (4,893 products, 497 values) and little for CAS.

### Coverage per annex or list and per proposed scope class
Classes from docs/data-model/cosmetics-scope.md (PROPOSED); REACH CMR appendices as their own
group. "Only here" = the product matches no entry of any other annex group (or class).

| Class | Annex or list | Products (any) | Products (as printed) | Distinct INCI | Only here |
|---|---|---|---|---|---|
| Core | Annex III | 10,561 | 8,996 | 505 | 4,624 |
| Core | Annex IV | 6,181 | 5,150 | 144 | 1,452 |
| Core | Annex VI | 3,739 | 3,731 | 32 | 429 |
| Core | Article 15(1) | 3,283 | 3,223 | 26 | 0 |
| Core | Annex V | 3,206 | 3,056 | 76 | 250 |
| Core | Annex II | 1,896 | 879 | 123 | 223 |
| Core | Article 15(2) | 403 | 241 | 25 | 0 |
| Indirect | Annex VI Table 3 (CLP) | 9,371 | 8,164 | 239 | 1,498 |
| Indirect | REACH Candidate List | 1,044 | 548 | 25 | 43 |
| Indirect | REACH Annex XVII | 850 | 382 | 27 | 28 |
| Indirect | POPs Regulation | 24 | 1 | 1 | 0 |
| Indirect | REACH Annex XIV | 21 | 21 | 1 | 0 |
| CMR appendices | CMR category 1B | 325 | 178 | 14 | 0 |
| CMR appendices | Toxic category 2 | 61 | 48 | 6 | 0 |
| CMR appendices | Mutagens | 21 | 10 | 5 | 0 |
| CMR appendices | Toxic category 1 | 9 | 9 | 0 | 0 |
| CMR appendices | CMR category 1A | 8 | 1 | 3 | 0 |
| Marginal | CITES 32026R1383 | 303 | 175 | 30 | 192 |
| Not relevant | Exemptions | 8,822 | 6,994 | 71 | 3,940 |
| Not relevant | REACH Annex V | 2,006 | 798 | 35 | 0 |

No product matches CITES 32025R0006 or POPs "Annex I, part A". Allergen list (/allergens, by
CAS or EC): 2,930 products, 142 distinct CAS, 60 distinct EC.

| Class | Products (any) | Products (as printed) | Distinct INCI | Only this class | Highest class reached |
|---|---|---|---|---|---|
| Core cosmetics | 16,744 | 14,507 | 775 | 7,853 | 16,744 |
| Indirectly relevant | 10,064 | 8,481 | 259 | 1,951 | 2,250 |
| REACH CMR appendices (open) | 391 | 230 | 21 | 0 | 0 |
| Marginal | 303 | 175 | 30 | 192 | 238 |
| Not relevant | 8,822 | 6,994 | 71 | 5,445 | 5,445 |
| Total | | | | | 24,677 |

Every product matched by a CMR appendix also matches a core or indirect entry, so the open
class decision does not change the "highest class reached" counts.

### Conflicts: CAS hit, no INCI agreement on the same entries (806 products)
(a) INCI agrees after strong normalisation (case, spaces, hyphens, brackets, punctuation
removed): 22. (b) INCI still differs: 784.

(a) examples (Covalo INCI / Relay X INCI, CAS, annex): METHYL PARABEN / METHYLPARABEN, 99-76-3,
REACH Candidate List; BENZOPHENONE 3 / BENZOPHENONE-3, 131-57-7, Annex VI; MEA LAURYL SULFATE /
MEA-LAURYL SULFATE, 4722-98-9, Annex III; CHROMIUM(III) OXIDE / CHROMIUM (III) OXIDE, 1308-38-9,
Annex IV; C.I. 45370 / CI 45370, 596-03-2, Annex IV; DISODIUM UNDECYLENAMIDO MEA- SULFOSUCCINATE /
DISODIUM UNDECYLENAMIDO MEA-SULFOSUCCINATE, 26650-05-5, Annex III; DM DM HYDANTOIN / DMDM
HYDANTOIN, 6440-58-0, Annex V (two products); ETHYLENE DIAMINE / ETHYLENEDIAMINE, 107-15-3,
Annex VI Table 3; RICINUSCOMMUNIS SEED OIL / RICINUS COMMUNIS SEED OIL, 8001-79-4, Exemptions.

(b) examples (all Covalo INCI values / all Relay X INCI values of the CAS-matched entries):

| Covalo INCI | Relay X INCI | CAS | Annex |
|---|---|---|---|
| CYCLOPENTASILOXANE; DIMETHICONE/VINYLTRIMETHYLSILOXYSILICATE CROSSPOLYMER | CYCLOMETHICONE; CYCLOTETRASILOXANE; OCTAMETHYLCYCLOTETRASILOXANE (D4) | 556-67-2 | Annex II, CLP, Art. 15(1), XVII, SVHC |
| AMODIMETHICONE/...COPOLYMER; GLYCERIN; PHENOXYETHANOL (PRESERVATIVE); TRIDECETH-5 | 2-PHENOXYETHANOL; PHENOXYETHANOL | 122-99-6 | Annex V, CLP |
| OCTYL TRIAZONE | ETHYLHEXYL TRIAZONE; chemical name | 88122-99-0 | Annex VI |
| P-CHLORO-M-XYLENOL | CHLORO-XYLENOL; CHLOROXYLENOL | 88-04-0 | Annex V, CLP |
| ETHYLHEXYL GLYCERIN+PENOXY ETHANOL. | 2-PHENOXYETHANOL; ETHYLHEXYLGLYCERIN; PHENOXYETHANOL | 122-99-6, 70445-33-9 | Annex V, CLP |
| GLYCERYL STEARATE SE | C10-18 TRIGLYCERIDES | 85665-33-4 | Exemptions |
| CHLORHEXIDINE ACETATE; CHORHEXIDINE ACETATE; SALIDINE ACT | CHLORHEXIDINE; CHLORHEXIDINE DIACETATE; ... | 56-95-1 | Annex V |
| TROLAMINE SALICYLATE | CALCIUM SALICYLATE; salicylate group names | 2174-16-5 | Annex III, V, CLP, Art. 15(1) |
| ETHYLHEXYL METHOXYCINNAMATE / OCTINOXATE; OCTINOXATE; OCTYL METHOXYCINNAMATE; SALISOL OMC | OCTINOXATE / ETHYLHEXYL METHOXYCINNAMATE; ETHYLHEXYL METHOXYCINNAMATE | 5466-77-3 | Annex VI |
| OCTISILATE; OCTYL SALICYLATE; SALISOL OS | 2-ETHYLHEXYL SALICYLATE / OCTISALATE); ETHYLHEXYL SALICYLATE | 118-60-5 | Annex VI |

Patterns in the (b) examples, not counted: several names in one value on either side
("A / B", "+", "(PRESERVATIVE)"), older or US synonyms (OCTYL TRIAZONE, OCTINOXATE), typos and
trade names in Covalo's INCI field, and Covalo blends whose CAS belongs to one component.
Product counts of (b) by annex of the CAS-matched entry: Annex III 287, CLP 258,
Exemptions 187, Annex II 121, Candidate List 118, Annex XVII 112, Annex V 95, Annex IV 77,
Article 15(1) 71, Annex VI 29, others 46.

## Open points
- Step 2 plan: docs/plans/2026-10-20-f2-covalo-lookup.md (parked until internal approval).
- Relay X data quality: recorded as VE-25 to VE-28 in docs/vendor-evaluation.md.
- Opinions and impurity-limits checks have run: results/2026-10-20-targeted-checks.md.
