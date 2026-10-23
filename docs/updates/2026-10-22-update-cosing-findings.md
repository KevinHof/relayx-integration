# CosIng work: companion update, 22 October 2026

Status of this document: working update written in the parallel CosIng chat on 2026-10-22. It is the companion to `2026-10-22-update-relayx-findings.md` (the main update) and is meant to be read together with it. It does not repeat the main update's Relay X findings; it refers to its sections where relevant.

All figures are PROVISIONAL unless stated otherwise. Labels: **Demonstrated** means measured in our data (results file and commit named) or taken from a primary source; **Inferred** means our interpretation, not verified; **Stated** means a claim by a person or third party that we have not verified (the source is named).

A shareable summary of this work exists as a Claude Doc, "CosIng identifier bridge: findings and proposal" (PDF copy in the Project). Two of its statements are now outdated by the main update; see section 7.

## 1. Provenance of the CosIng data

| Item | Value | Label |
|---|---|---|
| Content | CosIng "Ingredients and Fragrance Inventory" export (ingredients only; no annex exports used) | Demonstrated (column structure), Stated by Kevin (which export) |
| How obtained | Capture from the Internet Archive Wayback Machine, not a direct CosIng download | Stated by Kevin |
| Capture URL and capture date | Not known (recorded as PENDING in the plan doc) | |
| Vintage | Update dates in the file range from 2010-10-15 to 2020-12-15; 15,822 rows carry 2010, later years 197 to 2,751 each. The capture is therefore from 2020-12-15 or later | Demonstrated |
| File hashed in the repo folder | `data/cosing/cosing_clean.csv`, 5,859,404 bytes, SHA-256 `6cb1a58c...6441d4` (full hash in the profile results file); UTF-8, comma-delimited, quoted fields, no preamble lines, no export date printed | Demonstrated |
| File loaded through DBeaver | `COSING_Ingredients-Fragrance Inventory_v2.csv` (name seen in Kevin's DBeaver connection list) | Demonstrated (name only) |
| Database location | `covalo-local-complete`, database `covalo`, table `kevin.cosing_ingredients` (not a separate schema); `relayx_app` granted SELECT on this table only | Demonstrated |
| Rows | 28,712; file and table reconcile exactly (same rows, same reference numbers, no differing values) | Demonstrated, commit 1e4f2bb |
| Reference number | Unique, never empty, range 31,364 to 98,850 | Demonstrated |

**Not known:** the capture URL and date; whether `cosing_clean.csv` and the `_v2` file are the same content (the word "clean" suggests processing; Kevin does not recall whether the file was cleaned after capture); whether the capture was complete relative to CosIng at the time; the reuse terms for a bulk copy. Kevin described the data as accurate (Stated by Kevin); we treat it as accurate as of its capture date, not as current.

**Consequence (Inferred):** the snapshot predates both Glossary decisions (2022/677 and the current 2025/1175). INCI names added or renamed since then are missing or appear under old names. Every "not found in CosIng" in this document means "not found in a snapshot from 2020-12-15 or later".

## 2. Context and method

**What was explored.** Whether CosIng can act as a dictionary that translates Covalo's INCI names into CAS and EC numbers, how good Covalo's INCI names are against it, what the translation adds to Relay X matching, and whether Relay X's own identifier catalogue can serve the same purpose. The work ran as four Claude Code steps plus one small check done directly in this chat:

| Step | Content | Results file | Commit |
|---|---|---|---|
| F3 part 1 | Profile and file-to-table reconciliation (plan Q1) | `results/2026-10-21-f3-cosing-profile.md` | 1e4f2bb |
| F3 part 2 | Covalo INCI against CosIng, CAS and EC bridge, referee flag (plan Q2, Q3, Q5) | `results/2026-10-21-f3-cosing-bridge-part2.md` | 7851699 |
| F3 part 2b | Confidence tiers, product-level gain, validation sample | `results/2026-10-22-f3-tier-sizing.md` | 1354a62 |
| F3 part 3 | Effect on Relay X matching by option; conflicts; Relay X catalogue as bridge (extended plan Q4) | `results/2026-10-22-f3-bridge-options.md` | 39ee8c0 |
| Chat check | Structure of `identifiersonlyEU2.csv` (project file) | this document, section 4.3 | none |

All Claude Code steps ran locally and read-only as `relayx_app`, TEMP objects only, no extensions, no API calls. Queries are in `sql/provisional/f3_cosing_bridge.sql` (run with `sql/provisional/f1_matching_assessment.sql` as setup; the CosIng table name is a parameter). All commits are local; push status is not known.

**Matching and normalisation.** Covalo side: the same tables, active-product filter and parser as F1. INCI matching in cumulative levels: L0 equal after trimming; L1 adds case-insensitivity, collapsed whitespace, non-breaking space (U+00A0) to space and multiplication sign (U+00D7) to "x"; L2 removes punctuation, hyphens, brackets and spaces; L3 splits still-unmatched Covalo values on ";" and on "," where not between two digits, never on "/". CAS and EC on the CosIng side are parsed with the F1 parser (one parser for both sides), classified by pattern rather than column, placeholders dropped, check-digit failures excluded and counted, the "(generic)" qualifier kept as a flag.

**Decisions taken by Kevin in this chat:**

1. "/" is never a separator between INCI names (it is part of real names such as copolymers).
2. Fragrance-only CosIng rows (functions only PERFUMING or FRAGRANCE) are treated like all other rows; their contribution is reported as one line.
3. The bridge works per Covalo INCI component: a blend inherits the numbers of each matched component. Blends are reported separately, not excluded.
4. Where Covalo's CAS and a derived CAS conflict, Covalo's CAS stays the record and the derived CAS is not used for that product. In the analysis this was applied to CAS only; EC conflicts were only counted.
5. Confidence tiers per translation (INCI to number), CAS and EC separately:
    - T1: name matched at L0 or L1; exactly one valid number from CosIng for the INCI; that number on no other CosIng INCI; not flagged generic.
    - T2: every other translation not in T3 (matched at L2 or L3, several numbers for the INCI, or the number on 2 to 10 CosIng INCI).
    - T3: number on more than 10 CosIng INCI, or flagged generic.
6. Options for the matching effect: A (F1 baseline, Covalo identifiers plus Relay X's own identifiers on entries), B (A plus CosIng T1), C (B plus T2), D (C plus Relay X catalogue mappings, clean only or all).
7. Framing after part 3: CosIng is positioned as a tool for identifier quality and completeness, not as a lever on Relay X matching. Whether it is used in production is the CTO's decision.
8. The four suspected T2 cases (section 4.3) are not checked against ECHA now; Kevin plans an independent, Claude-assisted check of legal statuses on a sample as a separate track.

## 3. Findings: CosIng as a reference

**CosIng carries a CAS for only about half its rows (Demonstrated, 1e4f2bb).**

| | CAS | EC |
|---|---|---|
| Rows with a real value | 14,109 (49%) | 9,575 (33%) |
| Placeholder values | 4,091 ("-") | 5,455 ("-", "- / -", ",") |
| Rows with several numbers | 1,014 | 369 |
| Distinct numbers | 10,968 | 7,128 |
| Distinct numbers failing the check digit | 39 | 30 |
| Numbers shared by more than one INCI | 1,363 | 955 |

Every CAS and EC value starts with a space. Separators found: "/", ",", ";", "---". Qualifiers: "(generic)" and "(free base)" on CAS; "(I)", "(L)", a "*" prefix and "(EINECS)" on EC. Five values sit in the wrong column. One CAS (9003-11-6, poloxamers) sits on 75 INCI, so a CosIng CAS does not always identify a single substance.

**INCI hygiene (Demonstrated, 1e4f2bb).** 28,707 distinct INCI; 7 duplicated after lower-casing and trimming (14 rows); 483 with leading or trailing spaces; 11 with double spaces; 20 rows with a non-breaking space or a multiplication sign; 3,929 contain "/" as part of normal names; none contain ";".

**Fragrance Inventory (Demonstrated, 1e4f2bb).** No column separates fragrance inventory entries from cosmetic ingredients. 2,712 rows carry only PERFUMING or FRAGRANCE as function; using that as a split is not validated.

**Restriction column (Demonstrated, counts only).** 1,881 rows carry an annex reference such as II/123 or III/45a, some with free text: Annex II 821, III 777, IV 188, V 144, VI 33. Not compared with Relay X (legal accuracy track boundary).

**Caveats (Inferred).** CosIng is a non-binding information database; the legal INCI list is the Glossary of common ingredient names (Implementing Decision (EU) 2025/1175). A CosIng CAS can designate a related form (salt, hydrate, isomer) or a family. The INCI nomenclature itself originates from the Personal Care Products Council, so reuse rights for a bulk copy need checking (general knowledge, not verified for CosIng's terms).

## 4. Findings: overlaps

### 4.1 CosIng and Covalo: INCI recognition (Demonstrated, 7851699)

Covalo base: 53,062 active ingredient products carry an INCI (13,912 distinct values). Cumulative recognition, all CosIng rows (in brackets: excluding fragrance-only rows):

| Level | Distinct Covalo INCI | Products | Products with INCI but no Covalo CAS (36,496) |
|---|---|---|---|
| L0 trim only | 7,607 | 45,287 | 30,884 |
| up to L1 | 7,887 | 48,886 | 33,652 |
| up to L2 | 8,522 | 49,268 | 33,878 |
| up to L3 | 8,526 (61.3%; 57.8%) | 49,270 (92.9%; 90.0%) | 33,880 (92.8%; 90.8%) |

5,386 distinct Covalo INCI are not found; 3,792 products have no INCI found. L3 barely applies (5 Covalo values contain ";" or ","). 481 Covalo INCI are found only through fragrance-only rows. A random sample of 50 unmatched values (seed 20261021) shows typos, older names or synonyms, truncated values, several INCI joined with "/" or "+", chemical names and junk text, and some plausible INCI possibly newer than the snapshot. No nearest-match column was produced because pg_trgm is not installed.

### 4.2 CosIng and Covalo: CAS and EC bridge

**Per product, for the 49,270 products with an INCI found (Demonstrated, 7851699):**

| Class | CAS products | EC products |
|---|---|---|
| Agree (Covalo and CosIng sets overlap) | 13,401 | 1,611 |
| Conflict (both present, no overlap) | 1,209 | 83 |
| Gain (Covalo has none, CosIng has one) | 29,971 | 36,131 |
| Covalo only | 780 | 182 |
| Neither | 3,909 | 11,263 |

Where both sides have a CAS, they agree for 91.7% of products. 15 CAS and 11 EC values from CosIng were excluded for failing the check digit.

**Tiers at INCI level (Demonstrated, 1354a62).** Of the 8,526 recognised Covalo INCI, 5,681 get at least one valid CAS from CosIng; 2,845 get none.

| Tier | Covalo INCI, CAS (excl. fragrance-only) | Covalo INCI, EC (excl. fragrance-only) |
|---|---|---|
| T1 | 2,362 (2,237) | 1,667 (1,549) |
| T2 | 2,529 (2,309) | 1,896 (1,717) |
| T3 | 790 (692) | 356 (234) |
| Total with a number | 5,681 | 3,919 |

Reasons for T2 (overlapping): 2,089 share the number with 2 to 10 CosIng INCI; 1,334 belong to INCI with several numbers; 567 were matched only at L2 or L3. Only 9003-11-6 is shared by more than 50 CosIng INCI.

**Products gaining a CAS, by best tier (Demonstrated, 1354a62):**

| Product kind | Gain products | Best tier T1 / T2 / T3 | Gained CAS all from T1 INCI |
|---|---|---|---|
| Single INCI | 14,785 | 5,437 / 7,274 / 2,074 | 5,437 |
| Blend | 15,186 | 11,098 / 4,000 / 88 | 2,035 |

**CAS completeness of ingredient products** (our calculation from the figures above, each product counted once at its best tier, against 112,649 active ingredient products): today 33,427 (about 30%); with T1 about 49,960 (about 44%); with T1 and T2 about 61,240 (about 54%); with all tiers about 63,400 (about 56%). The main update gives 28.6% for today against all 116,938 active products; the two figures use different denominators (section 7).

**Tier accuracy is not measured.** A validation sample is drawn: `data/validation/f3_tier_sample.csv` (gitignored), 120 translations (60 T1, 40 T2, 20 T3, seed 20261022), verdict columns empty. Its converter script is not committed. Inferred from inspecting the sample, not validated: T2 mixes two kinds, specific numbers on INCI that carry several numbers (TOCOPHEROL, CI 45380, ZINC SULFATE) and botanical numbers shared across plant-part INCI, the latter closer to T3.

**Conflict stakes (Demonstrated, 39ee8c0).** The 1,209 CAS conflicts by type, and for how many the replay hit status changes with the CAS used:

| Type | Products | Hit status differs |
|---|---|---|
| Covalo CAS fails the check digit | 79 | 11 |
| Covalo CAS sits on a different CosIng INCI | 629 | 147 |
| Other | 501 | 95 |
| Total | 1,209 | 253 |

Examples: a Covalo typo (LANOLIN 8007- against 8006-54-0), titanium dioxide's CAS on a silane, alternative CAS for the same INCI. Inferred: these are mostly errors in Covalo's own data that produce false regulatory hits or misses today.

### 4.3 CosIng, Covalo and Relay X: effect on matching

**Matching by option (Demonstrated, 39ee8c0).** Products matching at least one current Relay X entry in the replay, of 112,649 ingredient products:

| Option | Products | Excluding exemption-only | Gain vs A | Distinct Covalo INCI found |
|---|---|---|---|---|
| A | 24,677 (21.9%) | 18,994 | | 973 |
| B | 24,683 | 18,999 | +6 | 979 |
| C | 25,306 (22.5%) | 19,675 | +629 | 1,099 |
| D clean | 25,306 | 19,675 | +629 | 1,099 |
| D all | 25,317 | 19,687 | +640 | 1,104 |
| Reference (all CosIng tiers) | 25,318 | 19,685 | +641 | 1,103 |

Option A reproduces F1 exactly. Of C's 629 gained products, 608 reach entries that print no INCI; the rest of the gain is mainly Annex IV, REACH Annex XVII and the Candidate List. C gains 338 single-INCI products and 291 blends. At most 4 gained products rest only on fragrance-only rows. D with all catalogue mappings mainly adds entries to products already found: products reaching Annex II rise from 1,982 to 2,296, Article 15(2) from 405 to 718, Toxic category 2 from 62 to 378.

**Fan-out (Demonstrated, 39ee8c0).** Products hitting more than 10 entries: A 987, C 1,163 (3 of them gained), D all 1,524 (138 gained; one product reaches 710 entries).

**Largest C gains come from T2 numbers (Demonstrated that they exist; correctness Inferred, not checked):**

- EC 310-127-6, mapped from MICA and from LIMNANTHES ALBA SEED OIL, reaches Annex IV entries 121, 134 and 135 (322 products). Inferred: as far as we know this is mica's EC and mica is an Annex IV colorant (CI 77019), so the MICA part may be a genuine gain; the LIMNANTHES ALBA part looks like a CosIng data error.
- CAS 9062-04-8, mapped from CARBOMER, reaches the borate entries (136 products), the same products and entries that Relay X's lookup returns (main update section 6.3). See section 7, point 2.
- EC 289-644-3, from cannabis seed oil, reaches Annex II entry 306 (55 products). Inferred: probably a false positive from a botanical number shared across plant parts.

**Why the gain is small (Inferred).** Most ingredients that gain a CAS are unregulated, so a new CAS rarely produces a new match. For regulated substances, Relay X's enriched identifiers already do the INCI to CAS translation: Option A finds 973 distinct Covalo INCI against 476 through printed names (F1). This is consistent with the main update's conclusion that local matching against the mirrored corpus is sound for regulated hits (main update section 4.4).

**Relay X catalogue as a bridge (Demonstrated).** Chat check on `identifiersonlyEU2.csv`: most rows carry several identifier types (4,130 rows with three of CAS, EC, CLP index and INCI; 1,219 with all four; 9,171 with CAS and EC; 980 with none). The INCI field is a synonym list separated by "|" (1,121 multi-valued rows, up to 49 names); split into single names the catalogue holds 6,727 distinct INCI, not the 4,178 distinct field values used in earlier counts. 6,133 names link to at least one CAS. Part 3 (39ee8c0): 14,207 rows, 9,943 clean (single valid CAS appearing in no other row); 14 CAS and 86 EC values fail the check digit.

| Catalogue mappings | Covalo INCI gaining a CAS | Products | Of which only through the catalogue |
|---|---|---|---|
| Clean | 1,316 | 17,788 | 358 INCI, 922 products |
| All | 1,746 | 19,907 | 455 INCI, 1,160 products |

Where CosIng (T1 or T2) and the catalogue both give a CAS for the same Covalo INCI, 1,282 of 1,291 agree (conflict examples: COCAMIDE MIPA, ALANINE). Inferred: the agreement may be partly circular if Relay X built parts of the catalogue from CosIng. 76 Covalo INCI not in CosIng are found among catalogue names (e.g. IRON OXIDE, 214 products; BISMUTH OXYCHLORIDE, 74). Catalogue CAS conflicts with Covalo's CAS: 745 products (clean), 726 (all). The "all" mappings carry the bundled CARBOMER numbers (EC 215-540-4 borax and others, the VE-36 pattern). Relay X has stated that the catalogue is a one-off, unmaintained export (main update section 6.1, Q09).

**Implementation facts (Demonstrated, 39ee8c0).** Dictionary rows (Covalo INCI to number pairs): CosIng T1 2,362 CAS and 1,667 EC; T2 3,366 and 2,219; T3 838 and 375; catalogue clean 1,348 and 878; catalogue not clean 2,399 and 1,356. Full rebuild about 100 seconds locally. Covalo inputs: `covalo.product` (id, type, segment, enabled, trashed, company, identifier keys cas, ec, inci, iupac) and `covalo.company` (id, trashed). Lookup sizing for derived numbers not yet sent to Relay X: B 1,397 values, C 2,285 (about 0.4 and 0.6 hours at 60 per minute; less at the current 300 per minute).

## 5. Answers to the six questions in section 9 of the main update

**1. Long-tail status (3,473 UNKNOWN CAS, about 8,500 UNKNOWN INCI): how many are listed in CosIng?** Not covered in this chat. This chat did not join CosIng with the F2 lookup statuses. What exists: 61.3% of all 13,912 distinct Covalo INCI are found in the snapshot (section 4.1), but not split by Relay X status. Missing: one local query joining the F2 status per value with the CosIng match (INCI at L0 to L3, CAS against CosIng CAS). Caveat for the intended use (Inferred): "listed in CosIng" does not mean "no EU constraint"; CosIng's own restriction column covers only 1,881 rows, is a non-binding indication, and the snapshot is from around 2021. A combined status would need to say "listed in CosIng snapshot, no constraint known to Relay X", not "unregulated".

**2. INCI quality.** Answered (Demonstrated, 7851699): exact 7,607 (54.7%), normalised up to L1 7,887, up to L2 8,522, after splitting 8,526 (61.3%) of 13,912 distinct values; 49,270 of 53,062 products (92.9%). Non-match categories from a 50-value sample: typos, older names or synonyms, truncations, values joining several INCI with "/" or "+", chemical names and junk, and possibly post-2020 INCI. The categories are not quantified beyond the sample.

**3. Bridge, especially Annex II and Article 15.** Answered (Demonstrated, 39ee8c0): T1 adds 6 products to Relay X matching; T1 and T2 add 629, of which 608 reach entries that print no INCI (Annex II, Article 15 and others); the per-annex breakdown per option is in the results file. The bridge adds substantially to CAS completeness (about 30% to about 44% of ingredient products with T1) but not to regulated hits. Inferred: Relay X's enriched identifiers already bridge the regulated substances.

**4. Synonym-aware CAS correctness.** Partial. Measured (Demonstrated, 7851699): for products whose INCI is found in CosIng and where both sides carry a CAS, 13,401 agree and 1,209 conflict (91.7% agreement), compared per product as sets, which avoids the cross-pairing inflation described in main update section 5. Anchoring on CosIng's INCI resolves synonyms only where CosIng lists both names; whether CosIng lists WATER beside AQUA, and how CI numbers and their INCI (CI 77891, TITANIUM DIOXIDE) are linked, was not specifically tested. Missing: an explicit check of AQUA and WATER and CI-number cases, and a rerun after the CAS normalisation fix (section 7, point 5).

**5. Fragrance houses (UNKNOWN CAS below 8000, functions).** Not covered in this chat. Related only: 2,712 CosIng rows carry only PERFUMING or FRAGRANCE; 481 Covalo INCI are found only through such rows. Missing: the join of the fragrance houses' UNKNOWN CAS with CosIng CAS and functions.

**6. Relay X cross-checks.** Partial.
- CARBOMER: Demonstrated that CosIng maps CARBOMER (T2, several numbers) to numbers including CAS 9062-04-8, and that this number reaches the same borate entries and 136 products as Relay X's lookup. Inferred: the false link sits in Relay X's identifiers on the borate entries, not in CosIng (section 7, point 2).
- ULTRAMARINES and FERRIC FERROCYANIDE: not covered.
- INCI printed by Relay X against CosIng INCI (F3 plan Q6): not covered; deliberately deferred from part 3.

## 6. Reconciliation with the F3 plan

The main update describes `docs/plans/2026-10-20-f3-cosing-bridge.md` as SCHEDULED. During this chat Claude Code updated the plan doc's provenance and status lines in each step (commits 1e4f2bb to 39ee8c0), so the description in the main update is probably based on an older view of the repo; the current file should be checked.

| Plan question | Status | Where |
|---|---|---|
| Q1 Profile | Done | 1e4f2bb |
| Q2 Covalo INCI against CosIng | Done | 7851699 |
| Q3 Bridge (agree, conflict, gain, neither) | Done, extended with tiers | 7851699, 1354a62 |
| Q4 Coverage effect | Done, extended to options A to D | 39ee8c0 |
| Q5 Referee flag | Done as a query view (`f3_referee_flag`), worded "found / not found in CosIng snapshot" | 7851699 |
| Q6 Relay X INCI against CosIng | Not done | |

**What in the plan should change:**

1. Provenance: Wayback Machine capture, table `kevin.cosing_ingredients` (not a `cosing` schema), file at `data/cosing/` (not `data/reference/cosing/`), capture date PENDING, latest update date 2020-12-15. Partly recorded already; verify.
2. Purpose: F3 no longer serves a matching gain for the contract assessment; it serves identifier quality and completeness, and a CTO decision on production use.
3. Add the confidence tiers, the options framing, the conflict rule (to apply to EC as well) and the Relay X catalogue as a second source (clean mappings only).
4. Add the three section 9 questions not in the original plan: long-tail status join with F2, synonym-aware correctness check, fragrance houses.
5. Keep Q6, now bundled with the ULTRAMARINES and FERRIC FERROCYANIDE checks.
6. Glossary reference: the part 1 message asked Claude Code to correct the plan's caveat to Implementing Decision (EU) 2025/1175 if it named 2022/677; the outcome was not reported explicitly. Verify.

## 7. Contradictions and divergences with the main update

1. **Identifier-less listings.** The CosIng deliverable (Claude Doc) says the roughly 37% of ingredient listings without identifiers is "still being verified". The main update (section 4.1, Demonstrated by F1b) confirms they are real: 41,622 have no value at all, 363 have only unusable values. The main update is the newer evidence; the deliverable needs correcting.
2. **CARBOMER.** The CosIng deliverable calls CAS 9062-04-8 from CARBOMER "likely a bad number", implicitly blaming CosIng. The main update (section 6.3) shows Relay X's substance index and catalogue bundle carbomer with borate numbers. Evidence on our side: the CosIng-derived CAS reaches exactly the borate entries and the 136 products that the lookup returns. Inferred, not verified: 9062-04-8 is one of carbomer's own CAS numbers, which would place the error in Relay X's identifiers on the borate entries and mean the bridge reproduced Relay X's false positive. The deliverable should be corrected once 9062-04-8 is verified.
3. **Core framing.** The main update (section 1) states that achievable coverage depends heavily on how well Covalo's INCI bridges to CAS. For regulated hits, this chat found the opposite: T1 adds 6 products, because Relay X's enrichment already bridges regulated substances (section 4.3). The framing still holds for completeness of Covalo's identifiers and possibly for the KNOWN versus UNKNOWN status (question 1, not measured). Suggested wording: coverage of regulated hits is limited by the regulations and by missing identifiers, not by INCI to CAS translation.
4. **Lookup run.** The CosIng deliverable lists the lookup run as open. The main update (section 4.2) reports it done on 2026-10-22 with 23,503 items, without CosIng-derived numbers. The deliverable needs updating; the derived numbers (about 1,400 for B) were not sent.
5. **CAS normalisation (divergence affecting our figures).** The main update (section 4.4) finds 74 lookup-only products caused by Covalo CAS stored with leading zeros, which the F1 parser keeps. F3 reused that parser, so some of our 1,209 conflicts, especially in the "other" group, may be leading-zero artefacts rather than real disagreements (Inferred). F3 parts 2 to 3 should be rerun after the parser fix in main update section 7, rule 1.
6. **CAS completeness denominators (not a contradiction).** Main update: 33,427 of 116,938 active products (28.6%). This document: 33,427 of 112,649 ingredient products (about 30%). Same count, different denominators.
7. **Correctness measures (not a contradiction).** Main update section 5: on the single-CAS caveat source, 55.3% agree and 10.0% conflict with Relay X as reference. This document: 91.7% agreement with CosIng where both sides have a CAS. Different references, populations and units (pairs versus products); they should not be compared directly.
8. **Coincidental percentages.** About 61.2% of Covalo's distinct INCI are UNKNOWN to Relay X (main update), and 61.3% are found in CosIng (this document). The two figures are unrelated; they should not be read as complements or overlaps until question 1 is measured.

## 8. Open questions and proposed next steps

**For the CTO's decision on production use:**

1. A current, official CosIng source: whether a maintained bulk export exists, and its reuse terms (the INCI nomenclature originates from the Personal Care Products Council).
2. Tier 1 accuracy: Kevin labels at least the 60 T1 rows of the validation sample (correct, related form, wrong, cannot tell, with source). Zero errors in 60 would support an error rate of at most about 5% at 95% confidence. Before labelling, send the pending part 2b addendum (T2 reason column, committed converter), because it regenerates the sample file.
3. Corrections to the deliverable from section 7, points 1, 2 and 4.
4. Ownership of the two worklists (CAS conflicts, unrecognised INCI).

**Further analysis, in proposed order (no messages drafted yet):**

1. Rerun F3 parts 2 and 3 after the CAS normalisation fix (leading zeros, whitespace, non-standard hyphens) to firm up the conflict figures.
2. Join CosIng with the F2 lookup statuses: answers questions 1 and 5 of the main update, locally, no API calls.
3. Synonym check: AQUA and WATER, CI numbers and their INCI, in CosIng and in the conflict list (question 4).
4. Plan Q6 plus ULTRAMARINES and FERRIC FERROCYANIDE in CosIng (question 6).
5. Verify the four T2 examples (MICA, LIMNANTHES ALBA, cannabis seed oil, CARBOMER), as part of Kevin's planned independent legal-status check or separately.
6. Update the F3 plan doc as listed in section 6.

**Open with Relay X (via the main track):** whether the catalogue mappings may be stored and reused (contract), and whether a maintained identifier list will exist (Q09 answer: one-off export).
