# Questions for Relay X (batched)

Status values: DRAFT (not yet sent), ASKED (date), PARTLY ANSWERED (date, what is
answered and what is still pending, source), ANSWERED (date, summary and source),
MOVED TO CONTRACT (not asked as a question; covered in the contract with Relay X).
Linked findings: docs/vendor-evaluation.md (VE-n). Internal questions: docs/open-questions.md.

## Sent to Relay X
Shared list of 2026-10-19 (Q01 to Q15): docs/relayx/covalo-questions-for-relayx-2026-10-19.md.

| Shared | RX | Note |
|---|---|---|
| Q01 | RX-3 | Start of knowledge log asked separately as Q02 |
| Q02 | RX-12 | |
| Q03 | RX-13 | |
| Q04 | RX-14 | |
| Q05 | RX-10 | |
| Q06 | RX-5 | |
| Q07 | RX-9 | |
| Q08 | RX-4 | |
| Q09 | RX-8 | |
| Q10 | RX-11 | |
| Q11 | RX-6 | unavailableZones part only; the FRANCE part of RX-6 goes into the Slack follow-up |
| Q12 | RX-16 | Mentions FRANCE in missingZones; does not ask directly why FRANCE is a separate zone |
| Q13 | RX-1 | Asks which limit applies, per key or per subscription; /changes unit cost and Reset format stated as observations, not asked |
| Q14 | RX-2 | |
| Q15 | RX-7 | |

Not in the shared list: RX-15 (removed before sending, moved to contract); the FRANCE part
of RX-6 and RX-17 to RX-19 (Slack follow-up planned); RX-20 (added 2026-10-20, DRAFT).

## Questions

RX-1 ANSWERED 2026-10-19 (asked by Kevin 2026-10-19 as shared Q13; answer from Pierre, Relay X, Slack).
Quota. Which limit binds (PDF: 60/min per key; contract: per subscription per minute;
observed `RateLimit-Limit` 60 on authenticated calls and 15000 on unauthenticated ones,
`RateLimit-Policy: 15000;w=900` on all)? What is the unit cost of one /changes page? Is
`RateLimit-Reset` seconds or a Unix timestamp (both observed)? (VE-5, Q7)
  Answer:
  - Quota: 60 requests per minute, set per subscription and shared across all our keys.
    `RateLimit-Policy: 15000;w=900` is a platform-wide per-IP safeguard, not our limit.
    Relay X will fix that header and the docs. The trial runs on the standard 60/min; it
    can be adjusted when we go commercial, based on the throughput we state.
  - /changes: one page = one unit regardless of size; `limit=200` is the maximum; results
    are oldest first and resumable.
  - `RateLimit-Reset` format: not in Relay X's answer; answered by observation
    (2026-10-20, Kevin): the contract and our authenticated responses agree on a Unix
    timestamp. Parsing stays defensive (CLAUDE.md rule 4).

RX-2 ASKED 2026-10-19 (shared Q14). lookup:batch. Please document the cap of 2,500 on items x `limit`
(`batch_result_too_large`). Does `RateLimit-Remaining` on a batch response reflect the
charge for that batch's items? We saw a mid-batch truncation after the previous response
showed 22 units left. (VE-3, VE-6)

RX-3 PARTLY ANSWERED 2026-10-19 (asked as shared Q01; answer from Pierre, Relay X, Slack). /changes as full extract. Please
confirm that `/changes?since=<before corpus start>&territory=EU`, paged by cursor to
`truncated: false`, returns every version of every EU entry visible to our key, with
nothing withheld beyond `withheldByScope`. Is 2026-08-01T00:30Z the start of the knowledge
log? (VE-7, VE-8, Q9, ADR-002)
  Answered: the method is the intended one: `since=2000-01-01T00:00:00Z`, `limit=200`,
  follow `nextCursor` until none is left; results oldest first, resumable; retracted
  entries come through as RETRACTED.
  Pending: explicit confirmation that nothing is withheld beyond `withheldByScope`;
  start of the knowledge log (see also RX-12).

RX-4 ASKED 2026-10-19 (shared Q08). The `searchMeans` text says "20470 current constraints that carry no identifier
at all". Which territories and which identifier fields does this count cover? Our EU
replay has 2,079 current entries without CAS, EC, INCI, CLP index or Colour Index. (VE-11)

RX-5 ASKED 2026-10-19 (shared Q06). Feed ordering. Entries Annex III 24, 70, 75 and Annex VI 28 (EU) show a
SUPERSEDED row at 2026-08-01 before their FIRST_RECORDED row at 2026-08-26. Which version
is current, and is this expected? logicalEntryIds: 36adaac2-b629-52b9-98b6-79e1c4b53fec,
12a04b9b-31b8-5762-a0ef-eea922a94c93, 81b9df22-e949-530c-b722-1c53893cfd4d,
9bc20320-a0fd-5730-9433-4459a57193a2. (VE-9)

RX-6 ASKED 2026-10-19 (shared Q11). `subscription.unavailableZones` is served but not in the contract schema; how
does it differ from `missingZones`? Why is FRANCE a zone separate from EUROPE? (VE-3)
  FRANCE part: DRAFT, not in the shared list; goes into the Slack follow-up with RX-17 to
  RX-19.

RX-7 ASKED 2026-10-19 (shared Q15). Can the PDF be updated to the served contract (cursor paging, row content,
quota, `name` matching, base URL)? (VE-1)

RX-8 ASKED 2026-10-19 (shared Q09). Identifier catalogue (identifiersonlyEU2.csv). What defines membership, how is
it kept current, and why do many rows (about a third in our sample, two thirds of EC-only
rows) return `KNOWN_WITHOUT_DATA` on EU lookup? (VE-12, Q5)

RX-9 ASKED 2026-10-19 (shared Q07). Entries that exist only as RETRACTED rows (6 in the EU feed) have no
FIRST_RECORDED event. Is that intended for rows retracted before first publication? (VE-10)

RX-10 ASKED 2026-10-19 (shared Q05). /entries/{id}/history carries a `truncated` flag but no paging. When is it
set, and how is the rest retrieved?

RX-11 ASKED 2026-10-19 (shared Q10). Is there a field or filter that marks which EU layers are relevant to
cosmetics (e.g. to exclude CITES species annexes), or is scoping left to the consumer? (VE-13)

RX-12 ASKED 2026-10-19 (shared Q02). Was 2026-08-01 your initial load? Every entry in our EU replay is first
recorded on or after 2026-08-01T00:30:42Z, so `knownSince` reflects your ingestion, not
the law. (VE-7)

RX-13 ASKED 2026-10-19 (shared Q03). Does the corpus include provisions repealed before 2026-08-01, or mainly law
in force at build time? Where is `asOf` supported besides market-summary? The contract
lists it on /substances/lookup, lookup:batch and market-summary only; is there a way to
replay law time on /changes, /texts or /entries/{id}/history?

RX-14 ASKED 2026-10-19 (shared Q04). Do the per-substance endpoints (impurity-limits, screening, opinions) have a
list or bulk route, or is per-substance lookup the intended way to get full coverage? Per
substance, our source list is about 16,000 items per endpoint.

RX-15 MOVED TO CONTRACT (2026-10-20, Kevin). Removed from the shared list before sending:
storage and usage rights for the local copy will be covered in the contract with Relay X,
which Kevin is drafting. Original question: Are we fine to store a full local copy of all content accessible to our key
during the trial, for evaluation purposes?

RX-16 ASKED 2026-10-19 (shared Q12). With a EUROPE subscription, do member-state territory codes (FR, DE, ...)
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

RX-20 DRAFT. /substances/market-summary verdict. How are `status`, `statusBasis` and
`statusMeans` derived? In our pilot, 8 CAS substances with EU constraint entries (returned
by lookup and counted in market-summary `constraintCount`) show `INSUFFICIENT_DATA`. Which
inputs and rules lead to that verdict? (pilot run 20261019T174653Z_substance_pilot_eu)
