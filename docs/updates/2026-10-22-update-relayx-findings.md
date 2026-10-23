# Relay X integration: consolidated update, 22 October 2026

Status of this document: working update written in the main Relay X chat on 2026-10-22. It consolidates the work since the 2026-10-21 handover. It is meant to be read together with a companion update written in a parallel chat that explored CosIng and its overlap with Covalo and Relay X. Where the two documents touch the same question, this one says so in section 9.

All figures are PROVISIONAL unless stated otherwise. Labels used throughout: **Demonstrated** means measured in our data or stated in a primary source; **Inferred** means our interpretation, not yet verified; **Stated by Relay X** means a claim by Pierre (Relay X) that we have not independently verified.

## 1. Context in brief

**Business question.** Covalo wants to sign a commercial contract with Relay X (Paris, CEO Mathis Gineste) for EU regulatory data, but only once the match and mismatch between Relay X's data and Covalo's ingredient data is understood. The contract draft is planned for the week of 26 October 2026. Four questions frame the evaluation: content (what Relay X holds), scope (what is relevant for cosmetics), matching (how well it connects to Covalo's products), and vendor reliability.

**Core framing.** Regulation keys on CAS and EC numbers; Covalo keys mainly on INCI. Achievable coverage therefore depends heavily on how well Covalo's INCI bridges to CAS, which is largely a question of Covalo's own data quality.

**Two tracks.** The fast track is a pre-signing matching assessment on raw data (steps F1 to F4, all figures provisional). The main track is the integration itself (phases 0 to 9: raw load, structure profiling, core data model, normalisation, versioning, analysis, matching tiers, pipeline and handover to P&T in early January 2027). The main track has been largely parked behind the fast track, deliberately.

**Environment.** Local PostgreSQL 14 (`covalo-local-complete`, Docker, port 5434, database `covalo`), Covalo data in schemas `covalo` and `kevin`, Relay X data in `relayx_raw` and `relayx_ops` (ADR-001, append-only raw, role `relayx_app`). Repo `KevinHof/relayx-integration` is the single source of truth. Claude Code runs in `C:\dev\relayx-integration`; long runs are started by Kevin from the Anaconda Prompt (cmd syntax: `cd /d`, `set PYTHONPATH=src`), conda env `relayx`.

## 2. What happened, 20 to 22 October

| Step | Outcome | Commit |
|---|---|---|
| F1b (step 1 follow-ups) | Done; identifier-less products confirmed real | e1aa065 |
| REACH Annex XVII entries 28 to 30 finding plus CMR appendix redundancy check | Recorded in the scope doc, status PROPOSED | 1e5bd05 |
| F3 CosIng bridge plan | Written, status SCHEDULED | 6ee758f |
| Pierre's full reply (Q01 to Q15 plus three points), API v1.1 guide received | See section 6 | n/a |
| F2 preparation (lookup run command, tests, dry run, runbook) | Done, 61 tests | 67bfa06 |
| F2 pre-flight, canary (100 items) and full lookup run | Run on 2026-10-22, 07:55 to 09:21 UTC, loaded clean | n/a |
| F2 profile | Done | 4f1736a |
| Covalo CAS quality (Part A) and F2 drill-down (Part B) | Done | 3e7946d |
| Loader fix for RETRACTION rows, verifications 2a to 2f | Done, 64 tests | b651ee9 |

None of these commits is known to be pushed. Push status since `b5b568f` is still unknown.

## 3. Content and scope

**Content** (unchanged since the 2026-10-21 handover, demonstrated). The 2026-10-19 replay holds 15,058 current EU entries across 11 annex types: 2,710 in Cosmetics Annexes II to VI, 1,525 Article 15 entries, 137 allergens. Only 648 entries print an INCI; Annex II and Article 15 print none. Opinions come from lookup as pointers, impurity limits are sparse and contaminant specific, IFRA is served as membership only.

New from Relay X (stated): the corpus holds only the current consolidated version of each act, with no legislative history before Relay X's initial load on 1 August 2026. Several versions of one entry can be current at once, separated by validity (transitional provisions; the example given is Regulation (EU) 2026/909, whose existence we confirmed; the specific transitional dates are not yet checked). Impurity limits exist for a few dozen substances only. There is no field marking cosmetics relevance; scoping is left to the consumer. France is the only member state with national cosmetic provisions in their data, served under a separate FRANCE zone that Covalo does not hold.

**Scope** (PROPOSED, decision pending with Kevin). The REACH CMR appendices (CMR 1A, CMR 1B, Mutagens, Toxic 1, Toxic 2; 1,941 entries) are proposed to move to "not relevant for cosmetic products", kept in raw. Grounds: paragraph 2(b) of entries 28 to 30 and Article 67(2) REACH (to be verified against CELEX 02006R1907). Redundancy check (demonstrated, printed identifiers only): 1,941 entries resolve to 1,235 distinct substances; 1,225 are also covered by Article 15, 0 by CLP Annex VI only, 10 by neither; 53 entries print no CAS or EC and were not counted. Under Article 67(2) these counts measure overlap, not legal coverage lost. The 10 "neither" substances are a lead for the legal accuracy track. A follow-up (extend the check with CLP index and enriched identifiers, correct the Glossary reference in the F3 plan to Implementing Decision (EU) 2025/1175, record a mis-printed name for CAS 7789-12-0) was drafted; whether it was sent to Claude Code is unknown.

## 4. Matching: what F1, F1b and F2 show

### 4.1 Covalo's identifier base (demonstrated)

Of 116,938 active products, 70,664 have a usable identifier (all ingredients); 46,274 have none. F1b confirmed that the 41,985 identifier-less ingredient products are real, not an extraction artefact: 41,622 have no value at all in CAS, EC, INCI or IUPAC; 363 have values that yield nothing usable; formulation tables could link at most about 1,318 (3%), only 272 through an explicit key.

### 4.2 The F2 lookup run (demonstrated)

Every distinct Covalo identifier value was sent to Relay X's `lookup:batch` (EU, `view=full`, 25 items per call, limit 100): 23,503 items (CAS 6,539, EC 1,533, INCI 13,912, NAME 1,519 from the IUPAC field), excluding 261 values failing the check digit. 942 calls, 23,514 units (11 resent after one truncation by the 20-second server time budget), 82 minutes at 300 per minute. The ledger matched the stored bodies for every item; no item exceeded the limit of 100. 32 items were refused (`name_too_short`, all one- or two-character INCI fragments from Covalo's data, 73 products); one item was NOT_SEARCHED (a blend stored as one INCI value, "WATER (AND) PROPANEDIOL (AND) STEMONA TUBEROSA ROOT EXTRACT").

Status by identifier type, share of distinct values:

| Type | HAS_DATA | KNOWN_WITHOUT_DATA | UNKNOWN_IDENTIFIER |
|---|---|---|---|
| CAS (6,539) | 15.7% | 31.2% | 53.1% |
| EC (1,533) | 18.7% | 13.0% | 68.2% |
| INCI (13,912) | 7.4% | 31.2% | 61.2% |
| NAME (1,519) | 10.3% | 10.1% | 79.6% |
| All (23,503) | 10.6% | 28.7% | 60.6% |

### 4.3 Product-level picture (demonstrated)

| Group, of 116,938 active products | Products | Share |
|---|---|---|
| At least one identifier known to Relay X (HAS_DATA, KNOWN_WITHOUT_DATA, or both) | 53,873 | 46% |
| Identifiers present, all unknown to Relay X | 16,733 | 14% |
| No usable identifier | 46,274 | 40% |

Within the 70,664 products with identifiers: 24,896 (35.2%) have at least one HAS_DATA identifier, 23,046 only KNOWN_WITHOUT_DATA, 16,733 only UNKNOWN_IDENTIFIER, 5,931 a mix of the last two. HAS_DATA is not the same as "restricted": it includes exemption-only and inventory-only hits and GROUP fan-out (F1: 5,683 products match only EXEMPTION or INVENTORY_LISTED entries).

### 4.4 Local matching versus Relay X's lookup (demonstrated)

The F1 replay-based match and the F2 lookup agree on 24,593 products. 303 are found only by lookup, 84 only by the replay match. Explanation of both groups after the drill-down:

| Group | Products | Explanation |
|---|---|---|
| Lookup only: CARBOMER via the substance index | 136 | Relay X false positive (section 6.3) |
| Lookup only: CAS stored with leading zeros (e.g. 0008008-56-8) | 74 | Our normalisation gap (F1 kept the zeros) |
| Lookup only: other literal INCI or name matches | 58 | Not yet explained, probably our normalisation |
| Lookup only: legitimate INCI-index enrichment | 34 | Found only by lookup, correctly |
| Lookup only: via a group entry | 1 | |
| Replay only: Relay X's guard, confirmed by the caveat | 49 | Entry names one substance and prints another number; F1 matched 42 of these through a linked substance flagged `printedByText`; Relay X deliberately withholds |
| Replay only: guard, probable | 1 | |
| Replay only: GROUP entry via fragments | 4 | Lavender fragments "Leaf", "Stem Extract" on both sides (section 6.3) |
| Replay only: other | 30 | 28 are ULTRAMARINES, a Relay X false negative (section 6.3) |

**Inferred.** Local matching against a mirrored corpus is sound for regulated hits; most divergences are explainable rules or fixable normalisation. The lookup is needed mainly for the KNOWN versus UNKNOWN distinction, which a replay of regulated entries cannot provide.

### 4.5 Identifier disagreement within products (demonstrated)

Of 18,441 products with identifiers of two or more types, 7,091 get different statuses depending on the type: KNOWN plus UNKNOWN 3,723; HAS plus KNOWN plus UNKNOWN 1,853; HAS plus UNKNOWN 895; HAS plus KNOWN 607; combinations with refused items 13. In about 3,355 products one identifier has data and another does not, so matching on a single identifier type would miss the regulation. Union across identifiers is mandatory.

### 4.6 The CAS gap: why 53% of Covalo CAS are unknown to Relay X

**Demonstrated.** None of the 3,473 UNKNOWN CAS appears anywhere in the replay. The most frequent UNKNOWN CAS are plant oils, butters, extracts and common emollients (65381-09-1, 67762-27-0, 61789-91-1); the most frequent UNKNOWN INCI are botanicals (BUTYROSPERMUM PARKII BUTTER, 326 products). The most frequent KNOWN_WITHOUT_DATA CAS are 56-81-5 and 107-88-0. CAS number ranges:

| Status | 68000 to 99999 | 100000 and above | Combined |
|---|---|---|---|
| HAS_DATA | 16.0% | 5.5% | 21.5% |
| KNOWN_WITHOUT_DATA | 27.3% | 11.0% | 38.3% |
| UNKNOWN_IDENTIFIER | 21.5% | 21.1% | 42.6% |

**Inferred.** Relay X's substance index includes some common unregulated ingredients (56-81-5 and 107-88-0 are, as far as we know, glycerin and butylene glycol) but not the long tail of natural and complex ingredients. This explains much of the gap, not all of it: 57% of UNKNOWN CAS sit below 68000. Consequence: for this long tail, Relay X cannot state "known, no EU constraint"; a second source would be needed to show such a status. This is where CosIng enters (section 9).

**Open: fragrance houses.** Lluch Essence and Indukern have the highest UNKNOWN shares (56 to 67% of their CAS). Their top unknowns are essential oils (8000-25-7, 8008-26-2), but 44 to 47% of their UNKNOWN CAS sit below 8000, a range typical of discrete chemicals. Whether this includes aroma chemicals that matter for allergen or IFRA rules is unresolved. A domain review of the top-20 list in `results/2026-10-22-f2-lookup-run.md` is proposed.

## 5. Covalo CAS quality (Part A, demonstrated unless marked)

**Completeness is the weak point.** 33,427 of 116,938 active products (28.6%) have a parsable CAS; 29.4% of ingredient products in personal care. 8 of the 20 largest companies have no parsable CAS at all (e.g. A & E Connock, Aston Chemicals, Moellhausen). This is a supplier-data issue, fixable at the source.

**Format is good.** 46,747 raw elements: 43,968 single (94.1%), 2,055 multi-value (separators "/" 931, "," 597, ";" 226, "&" 174, other 127), 157 with residue, 567 unparsable (MIXTURE most often). 227 distinct values (3.4%) fail the check digit, on 275 products; 151 products have only failing values. Normalisation needed for leading zeros (317 elements), whitespace (125), spaces around hyphens (88) and non-standard hyphen characters (62).

**Correctness is not yet measurable.** Internal consistency (one CAS with many INCI, one INCI with many CAS) is inflated by construction, because every CAS on a product pairs with every INCI on it (WATER shows 853 CAS). Agreement with Relay X as a reference: 39,534 distinct CAS-INCI pairs, 62.3% with any reference. Conflicts are dominated by synonyms our rule does not equate (AQUA versus WATER, CI 77891 versus TITANIUM DIOXIDE), plant-part and salt variants, and multi-ingredient products. On the cleanest subset (one CAS and one INCI per product, replay as reference) 945 agree and 586 conflict, surely overstated for the synonym reason. The single-CAS caveat source (3,164 INCI items where Relay X names the CAS an INCI resolves to) is the most informative: 55.3% agree, 10.0% conflict. **Inferred:** a correctness measure needs synonym-aware comparison against an independent reference, which is CosIng's role.

## 6. Vendor reliability

### 6.1 Pierre's answers (stated by Relay X, 2026-10-21)

Batch billing is one unit per item. The only trial limit is per minute; there is no daily or total cap. The rate was raised to 300 per minute on 2026-10-22 (verified in the pre-flight headers). Query data: queries are not sent to any AI model, not shared, not used to enrich their data; until 2026-10-22 usage records kept request identifiers for 90 days and error traces could hold request URLs; the subscription moved to reduced-tracking mode (operational logs only) on 2026-10-22. Reduced tracking cannot be verified from our side and has not been explicitly confirmed after the switch. All 15 questions were answered; highlights:

- Q01: `/changes` replay is a full extract; rows are versions; group by `logicalEntryId`, drop retracted, choose by validity; corrections made in place are visible only on a full replay.
- Q02, Q03: `knownSince` is knowledge time from 1 August 2026; no earlier legislative history.
- Q06: the four out-of-order entries (VE-18) are two wordings under Regulation (EU) 2026/909; `changeKind` labels were relabelled after the fact to FIRST_RECORDED.
- Q07: the six retracted rows were split continuation rows; retractions now arrive as dated events.
- Q08: our count of 2,079 EU entries without identifiers matches theirs; their `searchMeans` figure counts versions on CAS, EC and INCI only. We measured 2,298 such versions against their 2,292: treated as explained.
- Q09: the identifier catalogue (`identifiersonlyEU2.csv`) is a one-off, unmaintained export; a maintained identifier list "needs discussion".
- Q10: no cosmetics relevance field; "needs discussion".
- Q12 to Q15: France zone, rate limit, batch limits and docs alignment answered; guide v1.1 received (SHA-256 60a8e003...db707a).

### 6.2 API changes observed (demonstrated)

The served contract changed substantially on 2026-10-22 but still reports version 1.0.0: new `event` (RECORDED, RETRACTION) and `eventAt` on `/changes`, new batch routes for screening, impurity limits and opinions, `truncatedReason` for the time budget, new error codes, rate-limit headers now accurate. No version id field exists, so Relay X's advice to key a mirror on the version id has no basis in the current contract. `publishedOn` on opinions changed meaning. **Inferred:** responsiveness and transparency are high, but the API surface changes quickly without versioning; production use needs a change-notice and versioning commitment.

### 6.3 First demonstrated data defects

| Case | Type | Evidence | Effect |
|---|---|---|---|
| ULTRAMARINES | False negative in lookup | Annex IV entry 120 (CI 77007) carries "Ultramarines" as enriched `inciUs`; lookup for INCI ULTRAMARINES returns KNOWN_WITHOUT_DATA, total 0, no explanation in the body | 28 products; shows that a non-HAS status can hide an applicable entry |
| FERRIC FERROCYANIDE | Possibly the same | Lacks HAS_DATA; not analysed | Unknown |
| CARBOMER | False positive in lookup | Returns three borate entries (REACH Annex XVII entry 65 for 27522-09-4 and 22694-75-3; Candidate List for 1330-43-4) through the substance index; none names carbomer; same bundling as the catalogue export (CARBOMER with EC 215-540-4, VE-36) | 136 products would be shown reprotoxic borate restrictions they do not have |
| Lavender group entries | Fragmented `inciList` | Items "Leaf", "Stem Extract" stored separately | False matches on fragments |
| CAS 7789-12-0 | Wrong printed name (unverified) | Printed "Dichlorure de sodium, dihydrate" in a CMR appendix entry | Recording in the vendor evaluation pending |

These cases, plus the ingredientStatus questions below, were drafted for Pierre on 2026-10-22; whether they have been sent is for Kevin to confirm.

### 6.4 Open questions to Relay X

What defines "known" in the substance index behind lookup; whether UNKNOWN_IDENTIFIER is the expected answer for a valid unregulated cosmetic ingredient; whether an UNKNOWN or KNOWN_WITHOUT_DATA result can hide an applicable constraint (entries without identifiers, unlinked group entries; ULTRAMARINES shows it can); whether the index covers every substance with an SCCS opinion or pending mandate; confirmation of reduced tracking.

## 7. Rules for the matching design (from the fast track)

1. Normalise CAS: strip leading zeros, whitespace and non-standard hyphens before matching.
2. Block plant-part fragments ("LEAF", "STEM EXTRACT" and similar) as standalone match values, on both sides. Word count alone does not separate fragments from valid INCI.
3. Always take the union across all identifier types of a product; flag disagreements.
4. Never treat one route as proof. Record the route of every link (printed, enriched, group, INCI index, guard case, CosIng bridge) and tier by route.
5. Guard cases and GROUP matches through printed example numbers go to review, not auto-merge; their legal reading belongs to the legal accuracy track.
6. Exemption-only and inventory-only hits are flagged separately from restrictive hits.
7. Absence states stay explicit: HAS_DATA, KNOWN_WITHOUT_DATA, UNKNOWN_IDENTIFIER, NOT_SEARCHED, refused, out of scope or withheld, and on Covalo's side "no usable identifier". None of them means "unregulated".
8. INCI comparison needs synonym awareness (AQUA and WATER, CI numbers and their INCI); this needs a reference, not string rules.

## 8. Data model direction (conceptual, PROPOSED)

The model answers one question: for a Covalo ingredient, what does cosmetics-relevant EU regulation say, how sure are we, and as of when. It keeps three parts separate because each changes on its own clock and carries its own errors: the regulatory side (Relay X), the Covalo side, and the link between them. Layers: raw (exists, ADR-001), core regulatory model per content type, identity layer (identifiers from all sources, each source-labelled), link layer at identifier grain with route and confidence tier, serving layer (derived, largely P&T's design). Three clocks: law time (validity), knowledge time (Relay X `knownSince`), observation time (our runs). Versioning requires periodic full replays with hash comparison, because in-place corrections are invisible in the incremental feed. No canonical "Covalo substance" is created for now; whether one is built later, possibly with CosIng, is open. The data model is one of the three alignment points with P&T (Carlos, Thibault) and goes through an ADR before the build.

## 9. Interface with the CosIng work (parallel chat)

This document deliberately does not cover the CosIng exploration. The F3 plan in the repo (`docs/plans/2026-10-20-f3-cosing-bridge.md`, status SCHEDULED) was written before the parallel chat's work and may be out of date; the companion document should state which CosIng data was used (export, vintage, where loaded) so the plan can be reconciled. Whether CosIng is used in production is the CTO's decision. The questions this document needs CosIng to answer:

1. **Long-tail status.** Of the 3,473 UNKNOWN CAS and the roughly 8,500 distinct UNKNOWN INCI values (61.2% of 13,912), how many are listed in CosIng? This decides whether "listed in CosIng, no constraint found" can complement Relay X's UNKNOWN, subject to Relay X's answer on whether UNKNOWN can hide a constraint.
2. **INCI quality.** Share of Covalo's distinct INCI that are valid CosIng INCI (exact, normalised, after splitting), and the categories of non-matches.
3. **Bridge.** How much CosIng's INCI to CAS mapping adds to coverage, especially for Cosmetics Annex II and Article 15, which print no INCI.
4. **Synonym-aware CAS correctness.** Re-measure Covalo's CAS-INCI agreement with CosIng as the reference (section 5), resolving AQUA and WATER and CI-number cases.
5. **Fragrance houses.** Whether their UNKNOWN CAS below 8000 are in CosIng, and under which functions.
6. **Relay X cross-checks.** Whether ULTRAMARINES, FERRIC FERROCYANIDE and CARBOMER resolve in CosIng as expected (supports the defect reports); whether the INCI printed by Relay X match CosIng INCI.

Boundary: comparing CosIng's annex references with Relay X's annex membership belongs to the legal accuracy track, not to F3.

## 10. In flight and next steps

**With Claude Code, pending:** a loader change making a failed check a hard refusal with rollback (proposed before loading any new replay); then a fresh full EU replay (about 77 units), its load, and a comparison with the 2026-10-19 replay (new, changed, retracted; in-place corrections by hash on the old keys; `changeKind` and `publishedOn` differences classified as vendor relabels). Then a docs message recording Pierre's answers, the vendor-evaluation entries from section 6.3 and the matching rules from section 7.

**Decisions with Kevin:** the cosmetics scope; the CosIng approach (reconcile the parallel chat with F3); whether brand demos (planned early November on the full EU data) wait for F3; which contract terms to push hardest.

**Contract topics suggested by the evidence:** an error-correction commitment with response times; change notice and versioning for the API; defined semantics for UNKNOWN_IDENTIFIER and KNOWN_WITHOUT_DATA; a maintained substance index or identifier list; the query-data handling in writing; the rate needed for production.

**Main track after signing:** structure profiling, data model ADR and review with P&T, normalisation and versioning, matching tiers from section 7, pipeline and handover (mid-January 2027). Notion milestones from 6 November onward need re-dating.

## 11. Files in the repo

`results/2026-10-20-f1-matching-assessment.md` (with F1b), `results/2026-10-22-f2-lookup-run.md` (profile, drill-down, verifications), `results/2026-10-22-covalo-cas-quality.md`, `sql/provisional/f2_lookup_profile.sql`, `sql/provisional/covalo_cas_quality.sql`, `sql/provisional/cmr_appendix_redundancy.sql`, `docs/data-model/cosmetics-scope.md`, `docs/plans/2026-10-20-f2-covalo-lookup.md`, `docs/plans/2026-10-20-f3-cosing-bridge.md`, `docs/runbook.md` (section 5a), `docs/relayx/README.md`, `docs/relayx/openapi-2026-10-22.json`, `src/relayx/covalo_lookup.py`, `src/relayx/load_raw.py`. Raw run folders: `data/raw/api/20261022T075539Z_preflight`, `data/raw/api/20261022T075600Z_covalo_lookup_eu_canary100`, `data/raw/api/20261022T075923Z_covalo_lookup_eu`; value lists in `data/f2_lookup/20261022/` (gitignored).
