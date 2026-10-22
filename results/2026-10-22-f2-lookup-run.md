# 2026-10-22 F2 lookup run with Covalo identifiers (PROVISIONAL)

Run 20261022T075923Z_covalo_lookup_eu (full run only; the canary run is not used), loaded into
relayx_raw. Analysis local, read-only as relayx_app, TEMP objects only, no API calls:
`python -m relayx.provisional_report sql/provisional/f2_lookup_profile.sql --setup sql/provisional/f1_matching_assessment.sql --timeout 900`
(sections r1 to r13; rules in the SQL header). M0 to M5 classification not started.

## 1. Run integrity
- 942 calls, all HTTP 200, 07:59 to 09:21 UTC at 300 per minute (policy `300;w=60`, limit 300 on
  every call). Units sent 23,514 = manifest units = 23,503 items + 11 resent. 23,503 results,
  one per item (seq 1 to 23,503), none answered twice, none sent and never answered.
- RateLimit-Remaining vs our count, per fixed 60-second window (79 windows): equal on 919 calls;
  the server count is never higher than ours. 23 calls in two windows show the server lower by
  a constant 18 (calls 888 to 898) and 8 (calls 899 to 910). Call 888 was sent 13 s before its
  window closed and ran about 20 s; call 899 was sent 2 s before. Reading (not validated): units
  charged while a call straddles a window boundary count in the old window, whose last header
  came earlier. Whether the server charged call 888 for 25 items sent or 14 evaluated cannot be
  told from the headers. 75 calls saw Remaining 0 at the end of a window; no 429 occurred.
- Truncation: call 888 sent 25 items, returned indices 0 to 13, `truncatedReason` = server-side
  time budget of 20 seconds (no Retry-After). Call 889 sent exactly the 11 unevaluated items
  (seq 22,190 to 22,200: three Japanese-script INCI and eight long NAME values), in order. Each
  was answered once, in call 889; none has a ledger row in call 888.
- Ledger reconciliation: the manifest ledger in relayx_ops.extract_run (23,503 rows) matches the
  stored bodies on call, index, item, type, value, ok, error, message and ingredientStatus: 0 rows
  only in the ledger, 0 only in the bodies, 0 field mismatches. The load itself also passed the
  loader's ledger check (it refuses a run on any mismatch).

## 2. The 32 ok=false items
All INCI, all `name_too_short` (values of 1 or 2 characters): e.g. `1` (38 products), `10`, `D`,
`20`, `30`, `6`, `AG`, `C`, `PT`, `VP`, `B1`, `B2`, `B6`, `D)`, `E)`, `Γ`. They sit on 73 distinct
products (80 product links); 1 product has nothing but such a value. Origin in the value-list
build: the build does not split INCI strings. Each value is one element of the Covalo
`product.identifiers.inci` array, trimmed, upper-cased and whitespace-collapsed (F1
`norm_inci`). The raw elements carry leading spaces (`[ 1 ]`, `[ Ag]`, `[ d)]`) on products with
2 to 11 INCI elements, which suggests the arrays were split upstream in Covalo from a
comma-separated list (e.g. `B1`, `B2`, `B6` on one product). Not validated; value list unchanged.

## 3. ingredientStatus by identifier type (share of queried items of that type)
| Type | Items | HAS_DATA | KNOWN_WITHOUT_DATA | UNKNOWN_IDENTIFIER | NOT_SEARCHED | ok=false |
|---|---|---|---|---|---|---|
| CAS | 6,539 | 1,028 (15.7 %) | 2,038 (31.2 %) | 3,473 (53.1 %) | 0 | 0 |
| EC | 1,533 | 287 (18.7 %) | 200 (13.0 %) | 1,046 (68.2 %) | 0 | 0 |
| INCI | 13,912 | 1,027 (7.4 %) | 4,342 (31.2 %) | 8,510 (61.2 %) | 1 | 32 (0.2 %) |
| NAME | 1,519 | 156 (10.3 %) | 154 (10.1 %) | 1,209 (79.6 %) | 0 | 0 |
| All | 23,503 | 2,498 (10.6 %) | 6,734 (28.7 %) | 14,238 (60.6 %) | 1 | 32 (0.1 %) |

The NOT_SEARCHED item is INCI `WATER (AND) PROPANEDIOL (AND) STEMONA TUBEROSA ROOT EXTRACT`
(1 product, call 882 index 21). `identifierResolution`: `resolved: false`, `malformed: true`,
parameter `inci`; the value "names a blend of several ingredients joined by (and)", nothing was
searched, each ingredient should be queried as its own item. `total` 0, which the status
explanation says "says nothing about the ingredient".

## 4. Product level (70,664 products with a usable F1 identifier)
| Category | Products | Share |
|---|---|---|
| At least one HAS_DATA | 24,896 | 35.2 % |
| Only KNOWN_WITHOUT_DATA | 23,046 | 32.6 % |
| Only UNKNOWN_IDENTIFIER | 16,733 | 23.7 % |
| KNOWN_WITHOUT_DATA and UNKNOWN_IDENTIFIER | 5,931 | 8.4 % |
| Only ok=false | 1 | 0.0 % |
| NOT_SEARCHED, no HAS_DATA | 1 | 0.0 % |
| No queried value (check-digit failures only) | 56 | 0.1 % |
Categories use the statuses of queried values; an ok=false or unqueried value beside them does
not change the category (e.g. 50 HAS_DATA products also carry an ok=false value).

HAS_DATA vs the F1 replay match (24,677): both 24,593; lookup only 303 (HAS_DATA via INCI 217,
CAS 75, NAME 11); replay only 84 (lookup: only KNOWN_WITHOUT_DATA 72, mixed 8, only UNKNOWN 4);
neither 45,684.

## 5. Items with total above the constraints returned
None: no item has `total` above `returned` or above its constraints (limit 100), and none is
`scanCapped`.

## 6. Status disagreement within products (input for M4a)
18,441 products have queried identifiers of two or more types; 7,091 of them get different
statuses across types (statuses per type compared as sets). By status combination:
KNOWN_WITHOUT_DATA + UNKNOWN_IDENTIFIER 3,723; HAS_DATA + KNOWN_WITHOUT_DATA + UNKNOWN_IDENTIFIER
1,853; HAS_DATA + UNKNOWN_IDENTIFIER 895; HAS_DATA + KNOWN_WITHOUT_DATA 607; with ok=false 13.
Most frequent type combinations: CAS UNKNOWN / INCI KNOWN_WITHOUT_DATA 984; CAS KNOWN_WITHOUT_DATA
/ INCI UNKNOWN 831; CAS HAS_DATA / INCI UNKNOWN 264. Full list: section r10b.

## 7. Returned logicalEntryIds vs the replay
4,479 constraint rows, 1,560 distinct logicalEntryIds (none in `upcoming`); 1,558 are in replay
20261019T143522Z_eu. Not in the replay, both returned for NAME `sodium perborate monohydrate`:
- b3039cad-7f54-4a62-81fb-a76ccbd67214, CLP Annex VI Table 3, 005-022-00-4, knownSince
  2026-10-21T21:19:22Z
- f1e2cc38-3487-4397-8fcf-a6762d786e06, Article 15(2), art.15/005-022-00-4, knownSince
  2026-10-21T21:19:22Z
Both were recorded after the replay (latest knownSince in the replay 2026-10-16); a /changes
diff pull from the replay cursor should return them. Not checked (no API calls).

## Observation (not validated)
`searchMeans` on 21,952 results states that lookup does not reach "the 2292 current
constraints, in the markets your subscription opens, that carry no CAS, EC or INCI number". The
EU replay holds 2,079 current entries without identifiers (Q1). The basis of the 2,292 is not
stated.

## Open points
- M0 to M5 classification (not started).
- Whether Relay X charges truncated batches per item sent or per item evaluated.
- The 2,292 vs 2,079 identifier-less constraint counts (see B6 below).

## Drill-down (added 2026-10-22, PROVISIONAL)
Sections b1 to b6 of sql/provisional/f2_lookup_profile.sql (same command; rules in its header).

### B1 UNKNOWN_IDENTIFIER CAS, 30 most frequent (products; most frequent Covalo INCI on them)
None of the 3,473 UNKNOWN_IDENTIFIER CAS appears in the replay, printed or enriched.
65381-09-1 118 (CAPRYLIC/CAPRIC TRIGLYCERIDE 72); 67762-27-0 112 (CETEARYL ALCOHOL 100);
61789-91-1 104 (SIMMONDSIA CHINENSIS SEED OIL 44); 8000-25-7 101 (ROSMARINUS OFFICINALIS LEAF OIL
31); 84604-14-8 100 (ROSMARINUS OFFICINALIS LEAF EXTRACT 58); 91080-23-8 96 (BUTYROSPERMUM PARKII
BUTTER 62); 8007-69-0 85 (PRUNUS AMYGDALUS DULCIS OIL 60); 194043-92-0 77 (BUTYROSPERMUM PARKII
BUTTER 60); 8007-46-3 71 (THYMUS VULGARIS FLOWER/LEAF OIL 7); 8008-26-2 70 (CITRUS AURANTIFOLIA
OIL 26); 8024-32-6 70 (PERSEA GRATISSIMA OIL 44); 8024-06-4 69 (VANILLA PLANIFOLIA FRUIT EXTRACT
11); 8016-26-0 68 (CISTUS LADANIFERUS RESIN 1); 90045-98-0 67 (SIMMONDSIA CHINENSIS SEED OIL 52);
8015-73-4 64 (OCIMUM BASILICUM LEAF WATER 11); 1406-66-2 63 (TOCOPHEROL 52); 6290-03-5 60
(BUTYLENE GLYCOL 58); 84649-99-0 59 (THEOBROMA CACAO SEED BUTTER 19); 84929-27-1 59 (VITIS
VINIFERA SEED OIL 34); 85507-69-3 57 (ALOE BARBADENSIS LEAF JUICE 24); 68647-73-4 56 (MELALEUCA
ALTERNIFOLIA LEAF OIL 25); 8005-44-5 55 (CETEARYL ALCOHOL 55); 8007-08-7 54 (ZINGIBER OFFICINALE
ROOT OIL 9); 8008-52-4 53 (CORIANDRUM SATIVUM FRUIT OIL 11); 84650-00-0 53 (COFFEA ARABICA SEED
OIL 12); 90320-37-9 53 (PRUNUS AMYGDALUS DULCIS OIL 42); 8002-68-4 49 (JUNIPERUS COMMUNIS FRUIT
OIL 8); 9007-20-9 49 (CARBOMER 49); 94349-62-9 49 (ALOE BARBADENSIS LEAF JUICE 26); 8016-63-5 48
(SALVIA SCLAREA OIL 16).

### B2 UNKNOWN_IDENTIFIER INCI, 30 most frequent (products; most frequent Covalo CAS on them, its status)
BUTYROSPERMUM PARKII BUTTER 326 (91080-23-8, UNKNOWN); OLEA EUROPAEA FRUIT OIL 229 (8001-25-0,
KNOWN_WITHOUT_DATA); SIMMONDSIA CHINENSIS SEED OIL 211 (90045-98-0, UNKNOWN); PRUNUS AMYGDALUS
DULCIS OIL 162 (8007-69-0, UNKNOWN); ROSMARINUS OFFICINALIS LEAF EXTRACT 157 (84604-14-8, UNKNOWN);
PERSEA GRATISSIMA OIL 129 (8024-32-6, UNKNOWN); GLYCYRRHIZA GLABRA ROOT EXTRACT 102 (84775-66-6,
UNKNOWN); CI 77861 92 (13463-67-7, HAS_DATA); ORYZA SATIVA EXTRACT 87 (8016-60-2, UNKNOWN); VITIS
VINIFERA SEED OIL 83 (84929-27-1, UNKNOWN); PRUNUS ARMENIACA KERNEL OIL 72 (72869-69-3, UNKNOWN);
LIMNANTHES ALBA SEED OIL 71 (153065-40-8, UNKNOWN); MELALEUCA ALTERNIFOLIA LEAF OIL 69 (68647-73-4,
UNKNOWN); ROSMARINUS OFFICINALIS LEAF OIL 65 (8000-25-7, UNKNOWN); GLYCERIN (PLANT DERIVED) 60 (no
CAS); CURCUMA LONGA ROOT EXTRACT 59 (84775-52-0, UNKNOWN); WATER/AQUA 58 (56-81-5,
KNOWN_WITHOUT_DATA); ORYZA SATIVA BRAN OIL 55 (68553-81-1, UNKNOWN); CHAMOMILLA RECUTITA FLOWER
EXTRACT 53 (84082-60-0, UNKNOWN); ELAEIS GUINEENSIS OIL 52 (8002-75-3, UNKNOWN); MANGIFERA INDICA
SEED BUTTER 51 (90063-86-8, UNKNOWN); ZINGIBER OFFICINALE ROOT EXTRACT 49 (84696-15-1,
KNOWN_WITHOUT_DATA); OLEA EUROPAEA OIL UNSAPONIFIABLES 46 (156798-12-8, UNKNOWN); OLEA EUROPAEA LEAF
EXTRACT 45 (8001-25-0, KNOWN_WITHOUT_DATA); TRITICUM VULGARE GERM OIL 45 (68917-73-7, UNKNOWN);
ORYZA SATIVA BRAN WAX 44 (8016-60-2, UNKNOWN); TITANIUM DIOXIDE (CI 77891) 44 (no CAS); WATER (AQUA)
44 (7732-18-5, HAS_DATA); CITRUS MEDICA PEEL OIL 42 (8008-56-8, HAS_DATA); COFFEA ARABICA SEED
EXTRACT 41 (84650-00-0, UNKNOWN).

### B3 KNOWN_WITHOUT_DATA CAS, 15 most frequent (products; most frequent Covalo INCI); none in the replay
56-81-5 633 (GLYCERIN 501); 107-88-0 382 (BUTYLENE GLYCOL 356); 57-55-6 248 (PROPYLENE GLYCOL 132);
63148-62-9 244 (DIMETHICONE 232); 7631-86-9 243 (SILICA 222); 12001-26-2 201 (MICA 191); 9006-65-9
189 (DIMETHICONE 174); 1117-86-8 188 (CAPRYLYL GLYCOL 168); 6920-22-5 159 (1,2-HEXANEDIOL 143);
18282-10-5 154 (CI 77891 88); 73398-61-5 150 (CAPRYLIC/CAPRIC TRIGLYCERIDE 85); 9067-32-7 149
(SODIUM HYALURONATE 133); 25322-68-3 148 (PEG-8 12); 12003-38-2 147 (SYNTHETIC FLUORPHLOGOPITE
143); 61789-40-0 144 (COCAMIDOPROPYL BETAINE 111).

### B4 The 84 replay-only products
Classes per group (product, matched entry, matched Covalo value), first that applies: 2 guard
(entry not GROUP or GENERIC_CLASS, and the lookup body for the value has a caveat reporting
entries set aside: "were NOT returned" or "were removed"; 2a if the note names the entry's
logicalEntryId or a number the entry prints in its own field of the searched type, numbers taken
from the note by exact CAS or EC pattern only; 2b otherwise), 1 GROUP, 3 exemption or inventory,
4 other. The v1.1 guide could not be read here (no PDF reader); the guard is read from the
served caveat text.

| Class | Groups | Entry-value pairs | Products | Products by first class |
|---|---|---|---|---|
| 2a guard, confirmed | 65 | 31 | 49 | 49 |
| 2b guard, probable | 3 | 3 | 2 | 1 |
| 1 GROUP | 12 | 4 | 4 | 4 |
| 3 exemption or inventory | 0 | 0 | 0 | 0 |
| 4 other | 34 | 4 | 34 | 30 |
| Total | | | | 84 |

- F1 match route: 2a via a linked substance printedByText 51 groups (42 products), enriched 14
  (7); 2b enriched 2, own printed field 1; GROUP own printed field 12; other enriched 29, own
  printed field 5.
- Groups meeting more than one class definition: none.
- Examples, class 2a (entry, value, entry's own field, numbers in the note): Annex III 123
  f35e5a9c…, CAS 8013-86-3, own field 84696-07-1, note shows 84696-07-1 (27 products); Annex II
  168, CAS 93685-90-6, 67-48-1 / 67-48-1 (3); Annex III 286 and Annex V 44-3 / 44-5, CAS
  68002-62-0, 112-02-7 or 112-00-5 / note 112-02-7, 112-00-5 (2 each); Annex VI Table 3
  013-003-00-7, CAS 7784-13-6, 7446-70-0 / 7446-70-0 (2); Annex III 107, CAS 8007-47-4,
  85085-34-3 / 85085-34-3 (2); Annex IV 148, CAS 89957-89-1, 7659-95-2 / 7659-95-2 (2); Annex V 44
  and 44-4, CAS 1119-97-7, 17301-53-0 and 1119-94-4 / note 17301-53-0, 112-00-5, 1119-94-4,
  112-03-8, 112-02-7 "(+2 more)" (1 each). All CAS notes follow one template, as served for
  8007-47-4: "1 further constraint(s) are linked to the same substance but were NOT returned: each
  names ONE substance and its own text prints a DIFFERENT number in the field you searched, so
  serving it would contradict a text that speaks about which body it means. This is a deliberate
  guard against the index over-linking, not an absence of law. (GROUP entries are NOT withheld
  this way: their printed numbers are examples, so we serve them for any linked member.) The
  number(s) those entries print: 85085-34-3. ⚠️ Do NOT assume they designate your substance: a
  GROUP entry prints the numbers of its members or of its head, which are OTHER bodies. One of
  them may however be a SECOND number for the very body you searched — the EU corpus publishes
  some substances under two. Read the `literal` of what you find, and query the number separately
  before concluding." Every class 2 note as served, with the numbers taken from it: section b4c.
- Examples, class 2b: Annex V 44-2 and 44-6, CAS 1119-97-7, own field 57-09-0 and 1120-02-1: the
  note lists five numbers "(+2 more)" and these two are not among those shown. Annex VI Table 3
  611-142-00-3, NAME `sodium chloride`: the note (name containment) reads "8 entries whose text
  names DIFFERENT identifiers from the substance you asked for were removed … Removed, as
  examples: … "product-by-process definition polyazodyestuff obtained by coupling 4-[" (425-740-5)
  …"; numbers cannot be attributed for a NAME search under the rule, so 2b.
- Examples, class 1 GROUP: Annex III 360-2 and 360-3 (lavender, RESTRICTED, GROUP), Covalo INCI
  `STEM EXTRACT` (4 products) and `LEAF` (2), both UNKNOWN_IDENTIFIER in lookup: F1 matched
  fragments that occur on both sides (the replay's printed INCI strings split on [n] and ";",
  Covalo INCI arrays split upstream).
- Examples, class 4 other: Annex IV 120 (ULTRAMARINES, INCI, enriched, KNOWN_WITHOUT_DATA, 28
  products); Annex III 123, INCI `STEM EXTRACT` (own printed field, UNKNOWN_IDENTIFIER, 4);
  Annex III 355-2, INCI EUCALYPTUS GLOBULUS LEAF (own printed field, KNOWN_WITHOUT_DATA, 1);
  Annex IV 138, INCI FERRIC FERROCYANIDE (enriched, KNOWN_WITHOUT_DATA, 1).

### B5 The 303 lookup-only products
| Route (first by order) | Products | Entries |
|---|---|---|
| reachedViaGroupEntry | 1 | 1 |
| INCI index enrichment (INCI item, matchedBy substanceIndex) | 170 | 25 |
| other | 132 | 82 |
Other: CAS items 74 products (55 entries), INCI items matched literally 47 (26), NAME 11 (5).
Every returned entry of these products is in the replay. Most frequent entries: REACH Candidate
List 100.014.129 and REACH Annex XVII entry 65 (two entries), each via INCI CARBOMER (substance
index) for 136 products; Annex III 353 (citrus, via CAS 0008008-56-8 with leading zeros, and
INCI) 22; Annex VI Table 3 607-743-00-5 (LACTIC ACID, inci and name) 21; Annex IV 143, Annex VI 27
and 27a, Annex III 321 (INCI CI77891 without space, substance index) 14 each; Annex III 60
(OLEAMIDE DEA and NAME cocamide dea and others) 10.

### B6 searchMeans "2292"
Replay 20261019T143522Z_eu, entries not retracted, with nothing printed in identifiers cas, ec,
inci, casList, ecList or inciList: 2,298 versions; 2,289 entries with any such version; 2,288
entries whose latest version has none. Against 2,292: versions 6 more, entries (latest version)
4 fewer. It does not reconcile exactly. Most are CITES (Annex A to D) and Annex VI Table 3.
Possible reasons, not checked: the live measurement is three days later, Relay X's "current
version" may differ from latest knownSince (Q10), and "scoped to our markets" may include implied
zones. The earlier 2,079 used the F1 identifier set (including linked substances), a different
definition.

### Verifications (sections v1 to v6)
**2a ULTRAMARINES (28 products, B4 class 4).** F1 matched replay entry
09e7fba5-8ae6-51e1-b331-c8cf2a5d7dcc, Annex IV entry 120, COLORANT, SINGLE. Own fields: name
Lazurite, colourIndex 77007; no cas, ec, inci or inciList. Linked substances (printedByText): INCI
ULTRAMARINE BLUE, PIGMENT BLUE 29, CI 77007; colour index 77007. Nomenclature: inciEu null, inciUs
"Ultramarines", inciIecic "CI 77007". F1 matched ULTRAMARINES only through nomenclature.inciUs
(enriched). Lookup for INCI ULTRAMARINES (call 18, index 13): KNOWN_WITHOUT_DATA, total 0, no
constraints, searchMeans "Searched by inci through the substance index …", one caveat (the generic
INCI-index note: "Resolved through the INCI index, then widened to literal substance names. The
INCI index is PARTIAL. …"), no otherNameMatches, no withheldByIdentifier, withheldByScope count 0.
The body does not explain why entry 120 is not returned: nothing in it refers to that entry or
to a guard.

**2b CARBOMER (136 lookup-only products, B5).** Two queried values (CARBOMER, 214 products; a
variant with a leading space, 1 product) return the same three entries, all SINGLE, scope class
"indirectly relevant", matchedBy substanceIndex, reachedViaGroupEntry false:
- REACH Annex XVII entry 65, d8c7bb04-…, "Boric acid (H3BO3), ammonium salt", CAS 27522-09-4;
- REACH Annex XVII entry 65, ecb60768-…, "Ammonium borate", CAS 22694-75-3;
- REACH Candidate List 100.014.129, 24b3dca2-…, "Disodium tetraborate, anhydrous", CAS 1330-43-4.
Link: substance index only. No caveat names a single CAS for CARBOMER; none of the three entries
carries CARBOMER as an INCI in any field, and none is a GROUP entry. The body also carries a
name-containment note: 8 entries removed, examples "Carbomer" (9007-20-9), "Carbomer, sodium
salt" (73298-57-4). This is the same link as VE-36 (Relay X catalogue bundles CARBOMER with EC
215-540-4, disodium tetraborate).

**2c Lookup-only products with route "other" (132).** Link in the body: CAS items matched
literally (matchedBy cas) 74 products, 55 entries, 44 values; INCI items matched literally
(matchedBy inci) 47, 26, 14; NAME items with matchedBy empty 9 products (4 entries), matchedBy name
2 (1). No reachedViaGroupEntry and no substanceIndex in this route. Why F1 missed them: all 44 CAS
values carry leading zeros as stored in Covalo (e.g. 0008008-56-8, 0000078-70-6), which F1 keeps
and lookup normalises; the 14 INCI and 6 NAME values are not in the replay as F1 derives it (e.g.
LACTIC ACID, CITRUS LIMON OIL, PROPYLENE, HYDROXYETHYL ACRYLATE; NAME cocamide dea). 10 most
frequent entries: Annex VI Table 3 607-743-00-5 (LACTIC ACID, inci and name) 21; Annex III 353
GROUP (CAS 0008008-56-8, INCI CITRUS LIMON OIL) 11; Annex III 60 and Annex VI Table 3
616-096-00-8 (NAME cocamide, lauramide, oleamide, palm kernelamide dea, matchedBy empty) 8 each;
Annex III 366 GROUP (CAS 0008007-01-0) 7; Annex VI Table 3 601-011-00-9 (INCI PROPYLENE) 5;
Annex III 351-2 GROUP (0008008-57-9) 4; Annex III 357 GROUP (0008022-96-6) 4; Annex III 181 GROUP
(0008046-19-3) 3; Annex VI Table 3 607-072-00-8 (HYDROXYETHYL ACRYLATE) 3.

**2d STEM EXTRACT and LEAF (B4 class 1).** Covalo: both are separate elements of the INCI array,
e.g. `[Aster Tataricus] [Flower] [Leaf] [Stem Extract]`, `[ Epilobium Fleischeri] [Flower] [ Leaf]
[ Stem Extract]`, `[Actinidia Polygama Leaf] [ Stem Extract]` (LEAF 4 products, STEM EXTRACT 5),
so a name such as "… Flower/Leaf/Stem Extract" was split on "/" before it reached Covalo. Replay:
Annex III 360-2 and 360-3 (GROUP) print inci "Lavandula Intermedia Flower/Leaf/Stem Extract / …"
and "Lavandula Angustifolia Oil / Lavandula Angustifolia Flower/Leaf/Stem Extract", and their
inciList holds the fragments as items: `['Lavandula Intermedia Flower', 'Leaf', 'Stem Extract',
'Stem Oil', 'Lavandula Intermedia Oil']` and `['Lavandula Angustifolia Oil', 'Lavandula
Angustifolia Flower', 'Leaf', 'Stem Extract']`. Annex III 123 (Cupressus, SINGLE) has the same
pattern for STEM EXTRACT. F1 took the fragments from inciList (own field); the split is in Relay
X's inciList, not in F1.
F1 matches resting only on INCI values of one or two words: 11,407 of the 24,677 F1-matched
products (4,576 of them on one-word values only), 464 distinct values; 11,374 of the 11,407 also
have HAS_DATA in lookup. 460 of the 464 values are HAS_DATA in lookup; the other four are
ULTRAMARINES (45 products, KNOWN_WITHOUT_DATA), FERRIC FERROCYANIDE (4, KNOWN_WITHOUT_DATA), STEM
EXTRACT (5, UNKNOWN_IDENTIFIER), LEAF (4, UNKNOWN_IDENTIFIER). Most frequent: WATER 2,284, TITANIUM
DIOXIDE 1,872, AQUA 1,616, CI 77491 671, PHENOXYETHANOL 565, CI 77492 491, CI 77499 482, CI 77891
420, CI 19140 372, SODIUM BENZOATE 331. Full list: section v4d. Word count alone does not
separate fragments from valid INCI.

**2e A6, upper bins (share of the status's distinct CAS).**
| Status | CAS | 68000 to 99999 | 100000 and above |
|---|---|---|---|
| HAS_DATA | 1,028 | 164 (16.0 %) | 57 (5.5 %) |
| KNOWN_WITHOUT_DATA | 2,038 | 556 (27.3 %) | 224 (11.0 %) |
| UNKNOWN_IDENTIFIER | 3,473 | 747 (21.5 %) | 733 (21.1 %) |

**2f Fragrance houses.** UNKNOWN_IDENTIFIER CAS on their products by range:
| Range | Lluch Essence | Indukern |
|---|---|---|
| below 8000 | 456 (47.2 %) | 247 (44.0 %) |
| 8000 to 8099 | 99 (10.2 %) | 76 (13.5 %) |
| 8100 to 8999 | 0 | 0 |
| 9000 to 9999 | 4 (0.4 %) | 4 (0.7 %) |
| 10000 to 67999 | 265 (27.4 %) | 146 (26.0 %) |
| 68000 to 99999 | 107 (11.1 %) | 75 (13.3 %) |
| 100000 and above | 36 (3.7 %) | 14 (2.5 %) |
| Total | 967 | 562 |
20 most frequent (all Covalo products / Lluch / Indukern; most frequent Covalo INCI): 8000-25-7
101/5/2 (ROSMARINUS OFFICINALIS LEAF OIL); 8007-69-0 85/1/0 (PRUNUS AMYGDALUS DULCIS OIL);
8007-46-3 71/5/0 (THYMUS VULGARIS FLOWER/LEAF OIL); 8008-26-2 70/5/4 (CITRUS AURANTIFOLIA OIL);
8024-32-6 70/1/0 (PERSEA GRATISSIMA OIL); 8024-06-4 69/1/3 (VANILLA PLANIFOLIA FRUIT EXTRACT);
8016-26-0 68/8/7 (CISTUS LADANIFERUS RESIN); 90045-98-0 67/2/0 (SIMMONDSIA CHINENSIS SEED OIL);
8015-73-4 64/6/4 (OCIMUM BASILICUM LEAF WATER); 68647-73-4 56/3/3 (MELALEUCA ALTERNIFOLIA LEAF
OIL); 8007-08-7 54/4/2 (ZINGIBER OFFICINALE ROOT OIL); 8008-52-4 53/5/2 (CORIANDRUM SATIVUM FRUIT
OIL); 84650-00-0 53/0/2 (COFFEA ARABICA SEED OIL); 8002-68-4 49/3/2 (JUNIPERUS COMMUNIS FRUIT OIL);
94349-62-9 49/0/1 (ALOE BARBADENSIS LEAF JUICE); 8016-63-5 48/2/1 (SALVIA SCLAREA OIL); 8000-29-1
44/4/4 (CYMBOPOGON NARDUS OIL); 8015-92-7 44/2/1 (ANTHEMIS NOBILIS FLOWER OIL); 8016-36-2 43/4/4
(BOSWELLIA CARTERII GUM OIL); 8001-67-0 42/4/0 (COFFEA ARABICA SEED OIL). The INCI come from other
companies' products carrying the same CAS; the houses' own products carry no INCI (A5).
