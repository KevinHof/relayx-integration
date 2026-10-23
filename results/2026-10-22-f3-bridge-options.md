# 2026-10-22 F3 part 3: effect of the CosIng bridge and the Relay X catalogue on matching, by option (PROVISIONAL)

Local only, read-only as relayx_app, TEMP objects only, no extensions, no API calls.
`python -m relayx.provisional_report sql/provisional/f3_cosing_bridge.sql --setup sql/provisional/f1_matching_assessment.sql --param cosing_table=kevin.cosing_ingredients --timeout 3600`
(sections o1 to o13; rules in the SQL header, "Rules, part 3"). Matching = F1 replay matcher
(cov_id and derived values against F1 rx_id, printed or enriched), replay 20261019T143522Z_eu.
Option A reproduces F1: 24,677 products (o13).

Readings applied (state them back if they differ from the intent):
- Tiers are the part 2b INCI-level tiers, per number type (CAS tier and EC tier of an INCI are
  separate), reference set "all" (fragrance-only rows included). B = numbers of T1 INCI,
  C = plus all numbers of T2 INCI (a T2 INCI can carry T3-level numbers), reference = plus T3 INCI.
- Conflict rule applied to CAS only, as written, per source: if a product has a Covalo CAS and the
  source's derived CAS do not overlap it, that source's derived CAS are not used for the product.
  Derived EC are used as they are; EC conflicts are only counted (item 3).
- Share of distinct INCI is given against the 13,912 Covalo INCI (a share of products does not
  apply to INCI). Product shares are of the 112,649 active ingredient products.
- The T2 reason column does not exist (no part 2b addendum), so the C gain is not split by T2 reason.

## 1. Matching effect per option
| Option | Products | Share | Excl. exemption-only | Share | Gain vs A | INCI found | Excl. | Share of 13,912 |
|---|---|---|---|---|---|---|---|---|
| A | 24,677 | 21.9 % | 18,994 | 16.9 % | | 973 | 884 | 7.0 % |
| B | 24,683 | 21.9 % | 18,999 | 16.9 % | 6 | 979 | 889 | 7.0 % |
| C | 25,306 | 22.5 % | 19,675 | 17.5 % | 629 | 1,099 | 1,000 | 7.9 % |
| D clean | 25,306 | 22.5 % | 19,675 | 17.5 % | 629 | 1,099 | 1,000 | 7.9 % |
| D all | 25,317 | 22.5 % | 19,687 | 17.5 % | 640 | 1,104 | 1,005 | 7.9 % |
| Reference C+T3 | 25,318 | 22.5 % | 19,685 | 17.5 % | 641 | 1,103 | 1,003 | 7.9 % |

Products found per annex or list (a product counts in each group it hits):
| Annex or list | A | B | C | D clean | D all | Ref |
|---|---|---|---|---|---|---|
| Annex II | 1,896 | 1,897 | 1,982 | 1,982 | 2,296 | 1,982 |
| Article 15(1) | 3,283 | 3,283 | 3,306 | 3,306 | 3,306 | 3,306 |
| Article 15(2) | 403 | 404 | 405 | 405 | 718 | 405 |
| Annex III | 10,561 | 10,563 | 10,597 | 10,597 | 10,794 | 10,607 |
| Annex IV | 6,181 | 6,181 | 6,647 | 6,647 | 6,647 | 6,647 |
| Annex V | 3,206 | 3,207 | 3,222 | 3,222 | 3,448 | 3,222 |
| Annex VI | 3,739 | 3,739 | 3,757 | 3,757 | 3,757 | 3,757 |
| CLP Annex VI Table 3 | 9,371 | 9,458 | 9,516 | 9,516 | 9,804 | 9,516 |
| REACH Annex XVII | 850 | 919 | 1,113 | 1,113 | 1,115 | 1,113 |
| REACH Candidate List | 1,044 | 1,090 | 1,293 | 1,293 | 1,295 | 1,293 |
| REACH Annex XIV | 21 | 21 | 21 | 21 | 21 | 21 |
| POPs Regulation | 24 | 24 | 24 | 24 | 24 | 24 |
| CMR 1A / 1B / Mutagens / Toxic 1 / Toxic 2 | 8 / 325 / 21 / 9 / 61 | 8 / 326 / 22 / 9 / 62 | 8 / 327 / 22 / 9 / 62 | same as C | 8 / 327 / 22 / 9 / 378 | same as C |
| CITES 32026R1383 | 303 | 303 | 305 | 305 | 305 | 307 |
| Exemptions | 8,822 | 8,856 | 8,913 | 8,913 | 8,922 | 8,913 |
| REACH Annex V | 2,006 | 2,006 | 2,008 | 2,008 | 2,008 | 2,008 |

Per scope class (docs/data-model/cosmetics-scope.md; REACH CMR appendices own group):
| Scope class | A | B | C | D clean | D all | Ref |
|---|---|---|---|---|---|---|
| Core cosmetics | 16,744 | 16,747 | 17,279 | 17,279 | 17,465 | 17,289 |
| Indirectly relevant | 10,064 | 10,202 | 10,419 | 10,419 | 10,474 | 10,419 |
| REACH CMR appendices | 391 | 393 | 394 | 394 | 708 | 394 |
| Marginal (CITES) | 303 | 303 | 305 | 305 | 305 | 307 |
| Not relevant | 8,822 | 8,856 | 8,913 | 8,913 | 8,922 | 8,913 |

Gained products (not found in A) by the entries reached (a product can reach both kinds):
| Option | Gained | Via entries printing no INCI | of which Annex II / Art 15 / CLP VI | Via entries printing INCI | Gained excl. exemption-only |
|---|---|---|---|---|---|
| B | 6 | 6 | 1 / 1 / 3 | 0 | 5 |
| C | 629 | 608 | 61 / 17 / 28 | 90 | 617 |
| D clean | 629 | 608 | 61 / 17 / 28 | 90 | 617 |
| D all | 640 | 608 | 196 / 152 / 163 | 234 | 628 |
| Reference | 641 | 610 | 61 / 17 / 28 | 100 | 627 |

Single-INCI and blend products (found / gained; all products of the kind):
| Option | Single INCI (32,082) | Blend (20,980) | No INCI (59,587) |
|---|---|---|---|
| A | 5,336 / 0 | 14,576 / 0 | 4,765 / 0 |
| B | 5,338 / 2 | 14,580 / 4 | 4,765 / 0 |
| C | 5,674 / 338 | 14,867 / 291 | 4,765 / 0 |
| D clean | 5,674 / 338 | 14,867 / 291 | 4,765 / 0 |
| D all | 5,684 / 348 | 14,868 / 292 | 4,765 / 0 |
| Reference | 5,682 / 346 | 14,871 / 295 | 4,765 / 0 |

Fragrance-only CosIng rows: gains resting only on numbers from fragrance-only rows: B 0, C 4,
D clean 4, D all 0, reference 4 products.

## 2. Fan-out
| Option | Products hitting more than 10 entries | of which gained | Max entries per product |
|---|---|---|---|
| A | 987 | | 64 |
| B | 1,070 | 0 | 64 |
| C | 1,163 | 3 | 64 |
| D clean | 1,163 | 3 | 64 |
| D all | 1,524 | 138 | 710 |
| Reference | 1,164 | 3 | 64 |

Gains are concentrated on a few numbers (section o8b):
- C: EC 310-127-6 (CosIng T2) for MICA 262, LIMNANTHES ALBA SEED OIL 54, PINUS PINASTER SEED OIL
  3 products, reaching Annex IV 121 (GROUP), 134 and 135 (322 products); CAS 9062-04-8 (T2) for
  CARBOMER, reaching REACH Annex XVII 65 (two entries) and Candidate List 100.014.129, the borate
  entries lookup also returned (136); EC 289-644-3 (T2) for CANNABIS SATIVA seed oil and extract,
  Annex II 306 (55); CAS 7440-44-0 (T2) for CHARCOAL POWDER and CI77266, Annex IV 126, 126a, 128
  and Exemptions 24 (46); CAS 13463-67-7 and EC 236-675-5 (T2) for CI77891 written without a
  space (14).
- D all adds the catalogue's not-clean numbers for CARBOMER: EC 215-540-4 (disodium tetraborate,
  VE-36) and CAS 10043-35-3, 124-30-1, 124-68-5, 126-97-6 and others, reaching 13 entries
  including Annex II 1396-x, Article 15(2) art.15/005-011-00-4, CLP 005-011-00-4 and Toxic
  category 2. These 133 to 135 products are already gained in C; D all adds entries, not products.
- B gains 6 products, all via T1 numbers (e.g. CAS 93-83-4 to Annex III 60 and CLP
  616-096-00-8; EC 201-173-7 to CMR, Article 15(2), Annex II 681).
Full top-20 lists per option: section o8.

## 3. Conflict stakes (1,209 products, CosIng CAS conflicts, all tiers)
| Group | Products | Hit status differs | Only Covalo CAS hits | Only CosIng CAS hits | Both hit, different entries | Neither hits |
|---|---|---|---|---|---|---|
| a Covalo CAS fails the check digit | 79 | 11 | 1 | 10 | 0 | 68 |
| b Covalo CAS sits on a different CosIng INCI | 629 | 147 | 98 | 49 | 75 | 334 |
| c other | 501 | 95 | 18 | 77 | 24 | 376 |
Examples (Covalo CAS vs CosIng CAS, entries hit), 10 per group in section o9b, e.g.
(a) TEA-COCOYL GLUTAMATE 68178-29-1 vs 68187-29-1 (CosIng hits Annex III 62); BASIC VIOLET 2
3245-91-7 vs 3248-91-7 (CosIng hits Annex III 278, Annex IV 67); STEARIC ACID 97-11-4 vs 57-11-4.
(b) STEARYL TRIETHOXYSILANE 13463-67-7 (titanium dioxide; hits Annex III 321, Annex IV 143,
Annex VI 27 / 27a, CLP 022-006-00-2, Article 15(1)) vs 7399-00-0 (no hit); POLYDIETHYLSILOXANE
1317-61-9 (iron oxide; Annex IV 121, 134, 135, 137) vs 63148-61-8; BEHENTRIMONIUM CHLORIDE
57-55-6 / 68607-24-9 vs 17301-53-0 (CosIng hits Annex III 286, 287, Annex V 44). (c) LACTIC ACID
79-33-4 (hits CLP 607-743-00-5) vs 50-21-5; LAVANDULA ANGUSTIFOLIA FLOWER EXTRACT 8016-78-2 vs
90063-37-9 (CosIng hits Annex III 360-2, 360-3).
Derived-number conflicts with Covalo (products): CosIng CAS B 766, C 1,162, reference 1,209;
catalogue CAS 745 (clean) and 726 (all). EC conflicts, not applied: CosIng 83 to 87, catalogue
75 (clean) and 86 (all).

## 4. Relay X catalogue as a bridge
- 14,207 rows; check-digit failures excluded: 14 CAS and 86 EC values; 11,210 rows with a valid
  CAS; 9,943 clean rows. 1,793 Covalo INCI match a catalogue name (1,696 at L0).
- Gaining a CAS (Covalo has none): clean 1,316 INCI, 17,788 products; all 1,746 INCI, 19,907
  products. Also gained through CosIng T1 or T2: clean 958 INCI (16,845 products), all 1,291
  (18,747); catalogue only: clean 358 INCI (922 products), all 455 (1,160).
- CAS agreement where CosIng (T1, T2) and the catalogue both give one: all 1,291 INCI, 1,282
  agree, 9 conflict; clean 958, 950 agree, 8 conflict. Conflicts: COCAMIDE MIPA 68333-82-4 vs
  1335203-30-9; ALANINE 302-72-7 / 56-41-7 vs 118-74-1; BIXA ORELLANA SEED EXTRACT, SEED OIL and
  SEED 89957-43-7 vs 1393-63-1 / 542-40-5; SILVER CITRATE 36701-38-9 vs 77-92-9; SODIUM MAGNESIUM
  SILICATE 101659-01-2 vs 53320-86-8; SODIUM RIBOFLAVIN PHOSPHATE 130-40-5 vs 83-88-5; STRONTIUM
  CHLORIDE HEXAHYDRATE 10025-70-4 vs 10476-85-4.
- Covalo INCI not found in CosIng at any level but found among the catalogue names: 76 (75 with a
  catalogue CAS; 672 product links). Examples: IRON OXIDE (214 products, 7 CAS), BISMUTH
  OXYCHLORIDE (74, 7787-59-9 clean), MINERAL OIL (39), PERFLUOROHEXYLETHYL TRIETHOXYSILANE (39),
  IRON OXIDES (32), ALUMINIUM (29), HELIANTHUS ANNUUS (SUNFLOWER) SEED OIL (26), POGOSTEMON CABLIN
  OIL (16), RED 30 (13), RICINUS COMMUNIS (CASTOR) SEED OIL (13).

## 5. Lookup sizing (derived numbers used, not among F1 Covalo values, replay identifiers or catalogue values)
| Option | New values | CAS | EC | Units | Hours at 60/min |
|---|---|---|---|---|---|
| A | 0 | 0 | 0 | 0 | 0 |
| B | 1,397 | 610 | 787 | 1,397 | 0.39 |
| C | 2,285 | 971 | 1,314 | 2,285 | 0.63 |
| D clean / D all | 2,285 | 971 | 1,314 | 2,285 | 0.63 |
| Reference | 2,305 | 982 | 1,323 | 2,305 | 0.64 |
Catalogue-derived numbers are catalogue values by definition, so D adds no units.

## 6. Implementation facts
- Dictionary rows (distinct Covalo INCI to number pairs): CosIng T1 2,362 CAS + 1,667 EC (2,478
  INCI); T2 3,366 CAS + 2,219 EC (2,633 INCI); T3 838 CAS + 375 EC (840 INCI); catalogue clean
  1,348 CAS + 878 EC (1,316 INCI); catalogue not clean 2,399 CAS + 1,356 EC (460 INCI).
- Rebuild runtime here: F1 setup 10 s plus F3 setup 88 s (CosIng parsing, part 2 matching, part 2b
  tiers and part 3 options, all TEMP), about 100 s. The lookup-sizing report query (o11) takes
  about 410 s on its own.
- Covalo tables and columns read: covalo.product (id, type, segment, enabled, trashed, company,
  identifiers keys cas, ec, inci, iupac); covalo.company (id, trashed). Other inputs:
  kevin.cosing_ingredients (cosing_ref_no, inci_name, cas_no, ec_no, function, chem_iupac_name for
  the sample only); kevin.relayx_eu_identifiers_v2 (id, cas_number, ec_number, inci_name,
  inci_name_us, substance_name); relayx_raw.entry_version (replay 20261019T143522Z_eu).

## Observations (not validated)
- The bridge adds few products: C +629 (2.5 % over A). Most Covalo INCI that gain a CAS already
  match the replay by name, or their numbers reach no entry.
- The largest C gains rest on T2 numbers that look questionable for the INCI concerned (mica EC on
  LIMNANTHES ALBA SEED OIL, carbomer CAS reaching borate entries); the validation sample verdicts
  (part 2b) should precede any use of T2.
- D all's extra hits are the VE-36 pattern (catalogue rows bundling CARBOMER with borates).
