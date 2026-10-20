# Relay X vendor evaluation: running record

Findings about Relay X data and API, kept as evaluation deliverables. Each finding states
whether it is DEMONSTRATED (observed in our own calls or data, with the evidence location)
or UNVALIDATED (inferred, or stated by Relay X only). Questions to Relay X live in
docs/questions-for-relayx.md (RX-n). Raw evidence lives in data/raw/ (gitignored).

## A. Contract and documentation

VE-1 DEMONSTRATED (2026-10-19). The PDF (RX-API-EU-01 v1.0, Aug 2026) lags the served
contract on design-relevant points: /changes paging (PDF: advance with `nextSince`;
contract: opaque `nextCursor`), /changes and /history row content (PDF examples show ids
only), quota scope (PDF: per key; contract: per subscription), `name` matching (PDF:
substring; contract: whole term), scopes, and base URL (PDF `app.relay-x.com`, working host
`api.relay-x.com`). The PDF itself says the contract binds. Full diff:
docs/relayx/contract-notes-2026-10-19.md section 5.

VE-2 DEMONSTRATED. No bulk, export or list-entries route among the 12 operations. A full
extract is possible only through the /changes knowledge feed (see VE-8).

VE-3 DEMONSTRATED. Undocumented server limits and fields:
- lookup:batch refuses items x limit above 2,500 with `400 batch_result_too_large`; the
  error code is in the contract, the cap is not (data/raw/completeness/, first attempt).
- `subscription.unavailableZones` is served but absent from the `Abonnement` schema;
  `missingZones` lists FRANCE as a zone separate from EUROPE.

VE-4 DEMONSTRATED. The contract is unusually explicit about absence semantics
(`subscription`, `withheldByScope`, `ingredientStatus`, `absenceMeans`, 404 meaning on
/history). Positive for integration safety.

## B. Quota and rate-limit headers

VE-5 DEMONSTRATED. Three sources disagree on the quota: PDF "60 per key per minute",
contract "per subscription per minute, Reset = Unix timestamp", headers on unauthenticated
routes `Limit 15000`, Reset 900 (seconds). On authenticated routes the headers show
`Limit 60`, 1 unit per /changes page, Reset as a Unix timestamp. `RateLimit-Policy:
15000;w=900` appears on all responses. Asked (RX-1).
  Relay X response 2026-10-19 (Pierre, Slack), the same day as the question: the binding
  quota is 60 requests per minute per subscription, shared across keys; the 15000;w=900
  policy is a platform-wide per-IP safeguard. Relay X acknowledged the header and
  documentation inconsistency and plans to fix both. UNVALIDATED until the fix ships;
  responsiveness on this point is a positive signal.

VE-6 DEMONSTRATED. On lookup:batch, `RateLimit-Remaining` lags the real charge: a 12-item
batch came back `truncated: true` after the previous response showed 22 units left, and
the first batch of each window moved Remaining by only 1 or 2. Header-based accounting
undercounted 210 items as 173 units. Truncation was correctly flagged and the unevaluated
item was identifiable by index. Clients must keep a margin above the batch size.

## C. Completeness of the /changes feed

VE-7 DEMONSTRATED (2026-10-19). The EU feed from `since=2000-01-01` is internally
consistent: 77 pages, sum of `returned` = page 1 `total` = 15,205 rows, last page
`truncated: false`, no duplicate (logicalEntryId, knownSince), knownSince from
2026-08-01T00:30:42Z (corpus ingestion start) to 2026-10-16.

VE-8 DEMONSTRATED on a sample. Every entry that EU lookup returned for a stratified
sample of 210 catalogue identifiers (CAS 100, EC-only 50, INCI-only 50, name-only 10) is in
the replay: 249 of 249, rate 1.000 in every stratum (95 % upper bound on miss rate about
1.2 %). UNVALIDATED: completeness for entries no identifier or catalogue name reaches.
Relay X confirmed the replay method on 2026-10-19 (Slack); explicit confirmation that
nothing is withheld beyond `withheldByScope` is pending (RX-3 PARTLY ANSWERED, ADR-002).

## D. Data quality

VE-9 DEMONSTRATED. 4 entries (EU Annex III 24, 70, 75; Annex VI 28) have a SUPERSEDED row
dated 2026-08-01 before their FIRST_RECORDED row dated 2026-08-26. This contradicts the
feed's own `changeDetection` definition and makes the current version ambiguous. Asked (RX-5).

VE-10 DEMONSTRATED. 6 entries exist in the feed only as RETRACTED rows, with no creation
event. All carry errata "Identifier-column overflow, not an entry" (Annex II / III rows
holding CAS overflow). The retraction itself is documented and explained; the missing
FIRST_RECORDED row means a consumer cannot assume every entry starts with one.

VE-11 DEMONSTRATED. 2,079 current EU entries carry no CAS, EC, INCI, CLP index or Colour
Index; all carry a name. 1,834 of them are CITES annexes (species). The `searchMeans` text
on lookup states 20,470 "current constraints that carry no identifier at all", ten times
the EU count; scope not stated (RX-4).

VE-12 DEMONSTRATED. Relay X's EU identifier catalogue (identifiersonlyEU2.csv,
kevin.relayx_eu_identifiers_v2, 14,207 rows) is wider than the EU entry set: 67 of 210
sampled rows return `KNOWN_WITHOUT_DATA` on EU lookup (31 of 50 EC-only rows). It is not a
reliable seed list for "substances with EU constraints" (Q5, RX-8).

VE-13 DEMONSTRATED. The EU feed includes non-cosmetics layers: CITES wildlife-trade annexes
(about 1,839 entries), CLP, REACH, POPs. Consistent with the PDF ("six bodies of law"), but
scope filtering is the consumer's job; no flag marks cosmetics relevance (RX-11).

VE-14 DEMONSTRATED. Free-text notes (`verificationNote`, `errataNote`) are in French, as
the contract states. `annexRef` values contain non-ASCII punctuation and French
("hors Appendices CITES").

## E. Entry history and knowledge window (2026-10-19, run 20261019T174304Z_history_narrow_eu)

VE-15 DEMONSTRATED. /entries/{id}/history for the 147 entries with more than one version or
a retraction (147 calls, all 200): every one of the 288 versions matches a /changes row on
`knowledge.knownFrom` = `knownSince`, with identical entry content. History adds only the
`knowledge` block; the feed adds only `changeKind`. For single-version entries the history
would add nothing beyond knownFrom = knownSince (not called).

VE-16 DEMONSTRATED. Knowledge window inconsistent for 31 of the 147 entries: both versions
carry `isCurrent: true` and `knownUntil: null`, although one of them has a
`supersededByVersionId` and `supersessionNature: RULE_CHANGED`. The contract says a
superseded version is closed. 110 entries behave as documented (old version closed,
`isCurrent: false`); the 6 retracted entries have one version with `isCurrent: false` and
`retracted` set, as documented. (RX-17)

VE-17 DEMONSTRATED. `supersededByVersionId` cannot be resolved: no version id is exposed in
any /changes row or history version. With two versions per entry the successor follows by
elimination; with more it would not. (RX-18)

VE-18 DEMONSTRATED. For the 4 out-of-order entries (VE-9), history shows both versions with
`isCurrent: true`; the `supersededByVersionId` marker sits on the LATER version (FIRST_RECORDED,
2026-08-26), so the EARLIER version (SUPERSEDED row, 2026-08-01) is its successor. Feed order
alone ("last row is current") therefore picks the superseded version for these 4 entries.

## F. Corpus lists (2026-10-19, runs 20261019T174201Z_*_eu)

VE-19 DEMONSTRATED. /texts, /coverage and /allergens for EU are accessible (200), each in one
page: 115 texts (111 IN_FORCE, 4 without status), 51 coverage scopes (49 COMPLETE, 2 PARTIAL;
44 negative, 6 positive, 1 mixed list), 137 allergens. The 115 texts' `constraintCount` sum
to 15,205, exactly the replay's row count (all versions). Positive consistency signal.

VE-20 DEMONSTRATED. One EU text is withheld under our key: /texts returns
`withheldByScope.count: 1` ("redistribution right licensed beyond your key scope, or not yet
established"; amending acts among them, so amendment chains from this list are incomplete).
/changes reported `withheldByScope.count: 0` on every page. Which text it is, is not stated.
(RX-19)

VE-21 DEMONSTRATED. PDF figures are out of date for the lists: allergens 137 with basisActs
`32009R1223` (PDF: 129, `32023R1545`); coverage 51 scopes, 49 COMPLETE (PDF example: 36 scopes,
PARTIAL shown).

## G. Per-substance pilot (2026-10-19, run 20261019T174653Z_substance_pilot_eu)

VE-22 DEMONSTRATED. `substanceContext.screeningLists` in lookup is a strict subset of
/substances/screening: 21 of 44 items for the same 100 substances, and empty for all 20
EC-only queries where the endpoint returned 10 items. Lookup alone under-reports screening
memberships.

VE-23 DEMONSTRATED. /substances/market-summary EU rows agree with lookup in all 65 cases
(`constraintCount` and `entryRefs`). Consistency signal between endpoints.

VE-24 DEMONSTRATED. /substances/impurity-limits returned no limit for any of 100 sampled
catalogue substances. The dataset is narrow; a per-substance sweep has low yield (RX-14).
