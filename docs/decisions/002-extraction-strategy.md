# ADR-002: Extraction strategy via /changes replay

Date: 2026-10-20 (decision taken 2026-10-19, before ADR-001; recorded afterwards)
Status: Accepted

## Context
Relay X offers no bulk export or list-entries route. Lookup by identifier cannot reach entries without identifiers (2,079 current EU entries, 1,834 of them in the CITES annexes). /changes returns full entry objects keyed on knowledge time and is paged by an opaque nextCursor.

## Options considered
A. /changes replay from an early date (chosen)
B. Identifier sweep via lookup:batch over the identifier catalogue
C. Hybrid of A and B

## Decision
Use a /changes replay from 2000-01-01 (territory=EU) for the full extract of constraint entries, and the same route, from the stored cursor, for incremental pulls. Content outside the constraint entries (corpus lists, per-substance endpoints) is extracted separately, as listed in docs/relayx/coverage-inventory.md.

## Evidence
- Replay 20261019T143522Z_eu: 77 pages, 77 units, 170 MB raw. The last page is not truncated; rows (15,205) equal the total reported on page 1 and the manifest. 15,064 distinct entries, 15,058 current.
- Cross-check: 249 of 249 entries returned by lookup for a 210-item stratified sample are present in the replay (rate 1.000 in every stratum).
- /texts: the sum of constraintCount over 115 EU texts equals 15,205, the replay row count.
- Narrow history run (147 entries): every version matches a /changes row on knownFrom = knownSince with identical content. History adds only the knowledge block, so a full history run is not needed for extraction.
- Relay X (Pierre, Slack, 2026-10-19) confirmed this is the intended method: since=2000-01-01T00:00:00Z, limit=200, follow nextCursor until none is left; results oldest first, resumable; retracted entries come through as RETRACTED.

## Limits of the evidence
The cross-check shows that entries reachable by lookup are in the replay. For entries unreachable by lookup, completeness rests on the internal consistency of the replay, the /texts totals and Relay X's statement of method, not on an independent source. Relay X has not yet explicitly confirmed that nothing is withheld beyond withheldByScope.

## Consequences
- One mechanism serves the full extract and the diff pull for constraint entries.
- Identifying the current version of an entry cannot rely on feed order alone (VE-16 to VE-18); the rule is decided in the core model (Q10).
- The pipeline counts its own quota units; RateLimit-Remaining lags on batch calls.
