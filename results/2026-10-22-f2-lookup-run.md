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
- The 2,292 vs 2,079 identifier-less constraint counts.
