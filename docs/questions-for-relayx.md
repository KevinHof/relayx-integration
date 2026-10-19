# Questions for Relay X (batched)

Status values: DRAFT (not yet sent), ASKED (date), ANSWERED (date, summary and source).
Linked findings: docs/vendor-evaluation.md (VE-n). Internal questions: docs/open-questions.md.

RX-1 ASKED 2026-10-19 (Kevin). Quota. Which limit binds (PDF: 60/min per key; contract:
per subscription per minute; observed `RateLimit-Limit` 60 on authenticated calls and
15000 on unauthenticated ones, `RateLimit-Policy: 15000;w=900` on all)? What is the unit
cost of one /changes page? Is `RateLimit-Reset` seconds or a Unix timestamp (both observed)?
(VE-5, Q7)

RX-2 DRAFT. lookup:batch. Please document the cap of 2,500 on items x `limit`
(`batch_result_too_large`). Does `RateLimit-Remaining` on a batch response reflect the
charge for that batch's items? We saw a mid-batch truncation after the previous response
showed 22 units left. (VE-3, VE-6)

RX-3 DRAFT. /changes as full extract. Please confirm that `/changes?since=<before corpus
start>&territory=EU`, paged by cursor to `truncated: false`, returns every version of every
EU entry visible to our key, with nothing withheld beyond `withheldByScope`. Is
2026-08-01T00:30Z the start of the knowledge log? (VE-7, VE-8, Q9)

RX-4 DRAFT. The `searchMeans` text says "20470 current constraints that carry no identifier
at all". Which territories and which identifier fields does this count cover? Our EU
replay has 2,079 current entries without CAS, EC, INCI, CLP index or Colour Index. (VE-11)

RX-5 DRAFT. Feed ordering. Entries Annex III 24, 70, 75 and Annex VI 28 (EU) show a
SUPERSEDED row at 2026-08-01 before their FIRST_RECORDED row at 2026-08-26. Which version
is current, and is this expected? logicalEntryIds: 36adaac2-b629-52b9-98b6-79e1c4b53fec,
12a04b9b-31b8-5762-a0ef-eea922a94c93, 81b9df22-e949-530c-b722-1c53893cfd4d,
9bc20320-a0fd-5730-9433-4459a57193a2. (VE-9)

RX-6 DRAFT. `subscription.unavailableZones` is served but not in the contract schema; how
does it differ from `missingZones`? Why is FRANCE a zone separate from EUROPE? (VE-3)

RX-7 DRAFT. Can the PDF be updated to the served contract (cursor paging, row content,
quota, `name` matching, base URL)? (VE-1)

RX-8 DRAFT. Identifier catalogue (identifiersonlyEU2.csv). What defines membership, how is
it kept current, and why do many rows (about a third in our sample, two thirds of EC-only
rows) return `KNOWN_WITHOUT_DATA` on EU lookup? (VE-12, Q5)

RX-9 DRAFT. Entries that exist only as RETRACTED rows (6 in the EU feed) have no
FIRST_RECORDED event. Is that intended for rows retracted before first publication? (VE-10)

RX-10 DRAFT. /entries/{id}/history carries a `truncated` flag but no paging. When is it
set, and how is the rest retrieved?

RX-11 DRAFT. Is there a field or filter that marks which EU layers are relevant to
cosmetics (e.g. to exclude CITES species annexes), or is scoping left to the consumer? (VE-13)

RX-12 DRAFT. Was 2026-08-01 your initial load? Every entry in our EU replay is first
recorded on or after 2026-08-01T00:30:42Z, so `knownSince` reflects your ingestion, not
the law. (VE-7)

RX-13 DRAFT. Does the corpus include provisions repealed before 2026-08-01, or mainly law
in force at build time? Where is `asOf` supported besides market-summary? The contract
lists it on /substances/lookup, lookup:batch and market-summary only; is there a way to
replay law time on /changes, /texts or /entries/{id}/history?

RX-14 DRAFT. Do the per-substance endpoints (impurity-limits, screening, opinions) have a
list or bulk route, or is per-substance lookup the intended way to get full coverage? Per
substance, our source list is about 16,000 items per endpoint.

RX-15 DRAFT. Are we fine to store a full local copy of all content accessible to our key
during the trial, for evaluation purposes?

RX-16 DRAFT. With a EUROPE subscription, do member-state territory codes (FR, DE, ...)
return content distinct from `EU` (national provisions), or only the EU entries again?
Note that FRANCE appears as a separate zone in `missingZones`. (VE-3)

RX-17 DRAFT. Knowledge window: 31 of the 147 EU entries with two versions show BOTH versions
with `isCurrent: true` and `knownUntil: null`, although one has `supersededByVersionId` and
`supersessionNature: RULE_CHANGED`. Should the superseded version be closed? How should a
consumer determine the current version? Example ids: 03c0ccef-0f56-59e8-8d17-21e7c4bb93ca,
062b62e2-051e-52e3-be90-2aeaac6e5239; the 4 ids in RX-5 are also affected. (VE-16, VE-18)

RX-18 DRAFT. `supersededByVersionId` refers to a version id that is not exposed in /changes
rows or history versions. Can version ids be served, so supersession chains can be resolved
when an entry has more than two versions? (VE-17)

RX-19 DRAFT. /texts?territory=EU reports `withheldByScope.count: 1`. Which text is withheld
from our key, why (licence or right not yet established), and does it affect any constraint
entries? /changes reported no withheld entries. (VE-20)
