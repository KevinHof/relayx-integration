# 2026-10-20 Data pack: Relay X EU content atlas

Local only, no API calls. Queries: `sql/reports/atlas_datapack.sql`
(`python -m relayx.provisional_report sql/reports/atlas_datapack.sql`, about 4 s).
Sources, all loaded 2026-10-19:

| Source | Run id |
|---|---|
| /changes replay (entries) | 20261019T143522Z_eu |
| /texts | 20261019T174201Z_texts_eu |
| /coverage | 20261019T174201Z_coverage_eu |
| /allergens | 20261019T174201Z_allergens_eu |
| Screening and opinions (100-substance pilot only) | 20261019T174653Z_substance_pilot_eu |

Current entry = entry without a RETRACTED row (15,058 of 15,064); attributes from its last row
in feed order (provisional, Q10). "No identifier" = none of CAS, EC, INCI, CLP index, Colour
Index. This file is longer than the usual one-page results note because it is a data pack.

## 1. Legal texts (/texts)

115 texts, all legislator EC: 109 IN_FORCE regulations, 2 IN_FORCE corrigenda, 4 without
status. Sum of `constraintCount` = 15,205 = replay rows (all versions); per text the count
equals the replay rows in every case. 29 texts carry entries; 86 carry none.

Texts with entries (current entries in brackets per annex):

| officialRef | CELEX | Status | constraintCount | Current entries | Annexes or lists (entries) |
|---|---|---|---|---|---|
| 32009R1223 Cosmetics Regulation | 32009R1223 | IN_FORCE | 4,350 | 4,235 | Annex II (1,866), III (589), IV (154), V (68), VI (33), Article 15(1) (369), Article 15(2) (1,156) |
| 32008R1272 CLP, Annex VI Table 3 | 32008R1272 | IN_FORCE | 2,364 | 2,346 | Annex VI Table 3 |
| EU_REACH_ANNEX_XVII | none | null | 2,108 | 2,108 | REACH Annex XVII |
| EU_REACH (REACH) | 32006R1907R(01) | IN_FORCE | 2,059 | 2,058 | CMR category 1A (331), CMR category 1B (854), Mutagens (431), Toxic category 1 (23), Toxic category 2 (302), Exemptions (75), REACH Annex V (42) |
| 32026R1383 (CITES, amends 338/97) | 32026R1383 | IN_FORCE | 1,644 | 1,644 | 11 annexes A to D by CITES appendix |
| EU_REACH_CANDIDATE_LIST | none | null | 253 | 253 | REACH Candidate List |
| 32025R0006 (CITES import suspensions) | 32025R0006 | IN_FORCE | 195 | 195 | Annex (1) (5), Annex (2) (190) |
| EU_REACH_ANNEX_XIV | none | null | 59 | 59 | REACH Annex XIV |
| EU_POPS (POPs Regulation 2019/1021) | none | null | 35 | 35 | POPs Regulation (34), Annex I, part A (1) |
| 19 CLP adaptations (ATPs) and 1 corrigendum | 32009R0790 ... 32025R1222 | IN_FORCE | 2,138 in total | 2,125 | Annex VI Table 3 only (largest: 32009R0790 805, 32011R0286 596, 32009R0790-corr 197) |

The 4 texts without status are the consolidated REACH Annex XVII, XIV, Candidate List and
POPs pseudo-texts: synthetic officialRef, no CELEX. CLP Annex VI entries are attributed to
the adaptation that introduced them; Cosmetics Regulation entries are all attributed to the
base act. Per-text detail for all 115: section 1a of the full query output,
`results/2026-10-20-atlas-datapack-output.tsv`.

Texts without entries (86), grouped by the act they amend (`amends` field, title for null):

| Amends (as served) | Texts | Note |
|---|---|---|
| 32009R1223 Cosmetics | 30 | titles are bare numbers ("2016/621") or "Omnibus II" to "Omnibus VIII" |
| 32008R1272 CLP | 29 | 23 of them are titled as amending Regulation 1223/2009 (Cosmetics), e.g. 32013R0344, 32020R1682: wrong `amends` link; 3 are CLP ATPs carrying coverage scopes but no entries (32014R1297, 32016R0918, 32019R0521) |
| EU_POPS | 10 | POPs Annex I amendments |
| EU_REACH_ANNEX_XVII | 6 | Annex XVII amendments 2023 to 2026 |
| null (REACH by title) | 7 | Annex XVII amendments and REACH corrections |
| EU_REACH | 3 | |
| null (CITES base act 338/97) | 1 | 31997R0338 |

`withheldByScope.count` on /texts: 1 (which text is not stated, RX-19).

## 2. Annexes and lists (current entries)

Raw category values, before any mapping:
- `annexType`: CLP_HARMONISED 4,471; PROHIBITED 3,426; RESTRICTED 2,951; INVENTORY_LISTED 1,644;
  CMR_1B 1,587; CMR_1A 354; SVHC_CANDIDATE 253; COLORANT 154; EXEMPTION 117; PRESERVATIVE 68;
  UV_FILTER 33.
- `nature`: LITERAL_ENTRY 13,504; DERIVED_BY_LAW 1,554 (all of Article 15(1) and 15(2), 29 of
  REACH Annex V).
- `entryScope`: SINGLE 14,286; GROUP 758; GENERIC_CLASS 14.
- Served meanings (`annexTypeMeans`, abridged): PROHIBITED "banned"; RESTRICTED "allowed under
  conditions"; COLORANT, PRESERVATIVE, UV_FILTER "positive list for that function";
  CLP_HARMONISED "hazard classification, not a cosmetic rule, may trigger one";
  CMR_1A/1B "dedicated CMR listing, category drives derogation"; SVHC_CANDIDATE "not a use
  limit, triggers information duties"; EXEMPTION "carve-out from a rule stated elsewhere";
  INVENTORY_LISTED "CITES listing, a trade permit regime, not a formulation ban".

| Annex or list | annexType | Entries | Literal / derived | Single / group / generic | CAS | EC | INCI | CLP idx | CI | No id |
|---|---|---|---|---|---|---|---|---|---|---|
| Annex II (Cosmetics) | PROHIBITED | 1,866 | 1,866 / 0 | 1,771 / 95 / 0 | 1,793 | 1,672 | 0 | 15 | 0 | 48 |
| Annex III | RESTRICTED | 589 | 589 / 0 | 485 / 104 / 0 | 535 | 513 | 536 | 0 | 0 | 48 |
| Annex IV | COLORANT | 154 | 154 / 0 | 132 / 22 / 0 | 137 | 75 | 11 | 0 | 154 | 0 |
| Annex V | PRESERVATIVE | 68 | 68 / 0 | 46 / 22 / 0 | 67 | 68 | 68 | 0 | 0 | 0 |
| Annex VI | UV_FILTER | 33 | 33 / 0 | 29 / 4 / 0 | 33 | 26 | 33 | 0 | 0 | 0 |
| Article 15(1) | PROHIBITED | 369 | 0 / 369 | 351 / 18 / 0 | 346 | 311 | 0 | 369 | 0 | 0 |
| Article 15(2) | PROHIBITED | 1,156 | 0 / 1,156 | 1,112 / 44 / 0 | 1,116 | 1,101 | 0 | 1,156 | 0 | 0 |
| Annex VI Table 3 (CLP) | CLP_HARMONISED | 4,471 | 4,471 / 0 | 4,315 / 156 / 0 | 3,886 | 4,132 | 0 | 4,471 | 0 | 0 |
| REACH Annex XVII | RESTRICTED | 2,108 | 2,108 / 0 | 2,107 / 0 / 1 | 2,038 | 1,529 | 0 | 0 | 0 | 70 |
| REACH Annex XIV | RESTRICTED | 59 | 59 / 0 | 59 / 0 / 0 | 49 | 50 | 0 | 0 | 0 | 9 |
| REACH Candidate List | SVHC_CANDIDATE | 253 | 253 / 0 | 252 / 1 / 0 | 213 | 215 | 0 | 0 | 0 | 38 |
| CMR category 1A (REACH) | CMR_1A | 331 | 331 / 0 | 324 / 7 / 0 | 320 | 313 | 0 | 330 | 0 | 0 |
| CMR category 1B (REACH) | CMR_1B | 854 | 854 / 0 | 847 / 7 / 0 | 834 | 838 | 0 | 851 | 0 | 0 |
| Mutagens (REACH) | CMR_1B | 431 | 431 / 0 | 431 / 0 / 0 | 429 | 430 | 0 | 428 | 0 | 0 |
| Toxic category 1 (REACH) | CMR_1A | 23 | 23 / 0 | 23 / 0 / 0 | 21 | 20 | 0 | 23 | 0 | 0 |
| Toxic category 2 (REACH) | CMR_1B | 302 | 302 / 0 | 288 / 14 / 0 | 272 | 263 | 0 | 298 | 0 | 0 |
| Exemptions (REACH) | EXEMPTION | 75 | 75 / 0 | 75 / 0 / 0 | 75 | 7 | 0 | 0 | 0 | 0 |
| REACH Annex V | EXEMPTION | 42 | 13 / 29 | 29 / 0 / 13 | 29 | 0 | 0 | 0 | 0 | 13 |
| POPs Regulation | PROHIBITED | 34 | 34 / 0 | 33 / 1 / 0 | 20 | 20 | 0 | 0 | 0 | 14 |
| Annex I, part A (POPs) | PROHIBITED | 1 | 1 / 0 | 1 / 0 / 0 | 1 | 1 | 0 | 0 | 0 | 0 |
| CITES 32026R1383, 11 annexes | INVENTORY_LISTED | 1,644 | 1,644 / 0 | 1,383 / 261 / 0 | 0 | 0 | 0 | 0 | 0 | 1,644 |
| CITES 32025R0006, Annex (1) and (2) | RESTRICTED | 195 | 195 / 0 | 193 / 2 / 0 | 0 | 0 | 0 | 0 | 0 | 195 |
| **Total** | | **15,058** | 13,504 / 1,554 | 14,286 / 758 / 14 | 12,214 | 11,584 | 648 | 7,941 | 154 | 2,079 |

INCI is printed only by Cosmetics Annexes III to VI (648 entries); Annex II prints none.

## 3. Coverage scopes (/coverage)

51 scopes: 49 COMPLETE (`completeAsOf` 2026-08-26), 2 PARTIAL. `scopeIsOpenByItsOwnText` is
false for all 51.

| List type | Scopes | Completeness | Absence means (served, first clause) |
|---|---|---|---|
| NEGATIVE_LIST | 44 | COMPLETE | "NOT COVERED by this scope": no obligation from this scope; others may apply |
| POSITIVE_LIST | 3 (Cosmetics Annex IV, V, VI) | COMPLETE | "NOT AUTHORISED" for that function |
| POSITIVE_LIST | 2 (CITES 32025R0006 Annex (1), (2)) | PARTIAL | "NOTHING": exhaustiveness not established, absence may be a gap |
| MIXED | 1 (REACH Exemptions) | COMPLETE | "THE GENERAL RULE APPLIES": a list of derogations |
| POSITIVE_LIST | 1 (REACH Annex V) | COMPLETE | "THE GENERAL RULE APPLIES" |

The 44 negative scopes: Cosmetics Annex II, III, Article 15(1), 15(2); CLP Annex VI Table 3
(20 scopes, one per text); 11 CITES 32026R1383 annexes; REACH Annex XIV, XVII, Candidate
List, CMR 1A, CMR 1B, Mutagens, Toxic 1, Toxic 2; POPs Regulation.
Mismatches between scopes and entries: "Annex I, part A" (POPs, 1 entry) has no scope; 4 CLP
adaptations with entries have no scope of their own (32015R1221, 32017R0776, 32020R1182,
32023R1435); 3 CLP adaptations have a scope but no entries (32014R1297, 32016R0918, 32019R0521).
The CITES import-suspension list (32025R0006) is typed RESTRICTED and served as a positive list.

## 4. Allergens (/allergens)

137 allergens, all from Annex III (`basisAnnexes`), basis act 32009R1223, rule
`DUTY_STATED_IN_THE_ENTRY` (the list is derived from the declaration duty printed in each
Annex III entry), `scanCapped` false. 135 distinct entryRefs. 129 carry CAS and EC.
All 137 carry a declaration threshold, served as text only (no number); all mention leave-on
and rinse-off; 119 state the 0,001 % / 0,01 % pair. `conditions` is empty on all 137.
The PDF said 129 allergens and basis act 32023R1545 (VE-21).

## 5. Proposed classification (for review, not a decision)

| Annex or list | Proposed class | Reason |
|---|---|---|
| Cosmetics Annex II | Core cosmetics | Prohibited substances list of Regulation 1223/2009 |
| Cosmetics Annex III | Core cosmetics | Restricted substances with limits and conditions; source of the allergen list |
| Cosmetics Annex IV, V, VI | Core cosmetics | Positive lists for colorants, preservatives, UV filters |
| Article 15(1), 15(2) | Core cosmetics | CMR prohibitions of the Cosmetics Regulation, derived by Relay X from CLP classifications |
| Allergens (/allergens) | Core cosmetics | Labelling duty under Article 19(1)(g), derived from Annex III |
| CLP Annex VI Table 3 | Indirectly relevant | Not a cosmetic rule; its CMR classifications trigger Article 15 |
| REACH Annex XVII | Indirectly relevant | Restrictions; some entries apply to cosmetics (e.g. D4/D5 in wash-off, microplastics), most do not |
| REACH Annex XIV | Indirectly relevant | Authorisation affects use and supply of the substance in the EU, not cosmetic products directly |
| REACH Candidate List (SVHC) | Indirectly relevant | No use limit; supply-chain information duties and a signal of future restriction |
| REACH CMR 1A, 1B, Mutagens, Toxic 1, Toxic 2 | Indirectly relevant | REACH Annex XVII appendices for supply to the general public; to verify whether cosmetics are excluded from the underlying entries; overlaps CLP CMR classes |
| POPs Regulation and Annex I, part A | Indirectly relevant | Prohibitions apply to all products, cosmetics included, for few substances |
| CITES 32026R1383 (11 annexes) | Marginal | Trade permit regime for species; relevant only for sourcing botanical or animal ingredients |
| CITES 32025R0006 import suspensions | Marginal | Same as above, import-specific; scope PARTIAL |
| REACH Exemptions | Not relevant | Registration carve-outs, not use limits; produces noise in matching (e.g. water) |
| REACH Annex V | Not relevant | Exemptions from registration; same reason |
| 86 texts without entries | Follow their amended act | Provenance for amendment chains only; the 23 mislinked Cosmetics amendments belong with core |

## 6. Well-known sources: present or absent

| Source | Entries | Screening list | Opinion reference | Note |
|---|---|---|---|---|
| Cosmetics Regulation Annexes II to VI | Yes, 2,710 | | | Plus Article 15(1)/(2), 1,525 derived entries |
| CLP Annex VI (Table 3) | Yes, 4,471 | ECHA_CLH_PROCESS (procedures under way) | | 21 texts (base act and adaptations) |
| REACH Annex XVII | Yes, 2,108 | ECHA_RESTRICTION_PROCESS (procedures under way) | | Plus 1,941 CMR appendix entries under EU_REACH |
| REACH Candidate List (SVHC) | Yes, 253 | ECHA_SVHC_IDENTIFICATION (procedures) | | |
| SCCS opinions | No | | Not observed | Contract lists SCCS as an opinion body; the pilot returned 2 opinions, both CIR; SCCS appears only inside Article 15 condition text (1,535 rows). Opinions validation sample pending. |
| IFRA | No | Not observed | | Contract names list code IFRA_STANDARDS (membership and link only, no limits); 0 of 100 pilot substances; the pilot returned list codes the contract does not name (6 ECHA lists, IARC) |
| CITES | Yes, 1,839 | | | 13 scopes; no identifiers, names only |

Other screening lists seen in the pilot: ECHA_DOSSIER_EVALUATION (22 memberships),
ECHA_EU_POSITIVE_LIST (6, food contact and drinking water), ECHA_SUBSTANCE_EVALUATION (2),
IARC_MONOGRAPHS (1). Screening and opinions figures rest on 100 substances only.

## Findings for the vendor evaluation (not yet recorded)
- 23 Cosmetics amending acts carry `amends` = CLP (32008R1272).
- Entry attribution differs by corpus: CLP entries sit on the adaptation, Cosmetics entries
  on the base act, so 86 of 115 texts carry no entries.
- Coverage and entries disagree for 8 CLP and POPs units (section 3).
- Screening list codes observed differ from those the contract names.
