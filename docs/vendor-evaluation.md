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
Relay X has indicated /changes is the intended full-extract route; confirmation of a
complete replay is asked (RX-3).

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
