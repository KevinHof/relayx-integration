# Open questions (as of 2026-10-19)

Status values: OPEN, ASKED (to Relay X), ANSWERED (link the ADR or source).

Q1 OPEN. Full-extract completeness. No bulk export endpoint is documented in the PDF.
Enumerating by identifier does not reach the ~20,470 current constraints with no
identifier (GROUP entries such as "... and its salts"). Does openapi.json expose a bulk
or list-entries endpoint? If not, ask Relay X.
  Contract finding (2026-10-19, see docs/relayx/contract-notes-2026-10-19.md):
  - No bulk, export or list-entries route exists. The 12 operations are listed in the notes.
  - Chosen direction: option A, GET /changes replay from an early `since`, `territory=EU`,
    paged by `cursor`. Relay X indicated this is the intended route. Completeness is
    tracked as Q9.
  - Source of the ~20,470 figure is unknown; the PDF states 14,183 EU entries and 271
    substances with no CAS, EC or INCI. Check where 20,470 came from.

Q2 ANSWERED (by contract, docs/relayx/contract-notes-2026-10-19.md sections 2 and 3).
Re-fetching changed entries. /changes returns logicalEntryId + changeKind only.
Lookup works by substance identifier, not by entry id. Does /entries/{id}/history (or
any other route) return full current entry content?
  - The premise was wrong: /changes rows are full `Contrainte` objects + `changeKind` +
    `changedFields` + `knownSince`. Confirmed in practice on 2026-10-19 (400 rows, all
    required `Contrainte` fields present, about 9.5 KB per row).
  - GET /entries/{logicalEntryId}/history returns `versions[]`, each a full `Contrainte` +
    `changedFields` + `knowledge` (`knownFrom`, `knownUntil`, `isCurrent`, `retracted`,
    `supersededByVersionId`, `supersessionNature`, `coveredBy`). Not yet called.
  - Consequence: the diff pull does not need a re-fetch per changed entry.

Q3 OPEN. Extract runtime. At 60 units/min, ~14,000 lookups need roughly 4 hours
minimum. Confirm actual substance count and acceptable re-baseline cadence.
  - With option A, the EU replay is ~15,205 rows = ~77 pages of 200 at 1 unit per page
    (measured 2026-10-19), about 145 MB raw. Minutes, not hours. Cadence still to decide.

Q4 OPEN. Absence semantics. How to model 403 / 404 / withheldByScope /
INSUFFICIENT_DATA / missingZones as explicit states in raw and core layers.
  - Note: the live `subscription` block also carries `unavailableZones`, which is not in
    the contract schema.

Q5 OPEN. Seed list. Is identifiersonlyEU2.csv the complete EU substance index
(the PDF mentions 8,728 EU-covered substances), and how is it kept current?

Q6 OPEN. Schema layout. Proposal (not decided): relayx_raw (append-only responses),
relayx_ops (run log, cursor), relayx_core (normalised, versioned), plus a matching
layer. Needs an ADR before any schema is created. The ADR also covers a read-only DB role.

Q7 ASKED (to Relay X, 2026-10-19). Quota: binding limit, unit cost per /changes page,
RateLimit-Reset format. Until answered, the RateLimit-* headers are the source of truth
(CLAUDE.md rule 4).
  - Observed on unauthenticated routes: `RateLimit-Limit: 15000`, Reset 900 / 793.
  - Observed on authenticated /changes: `RateLimit-Limit: 60`, Remaining 59 then 58
    (1 unit per page), Reset `1792419799` (Unix timestamp, 60 s ahead).
    `RateLimit-Policy: 15000;w=900` appears on both, possibly a separate gateway limit.

Q8 ANSWERED (CLAUDE.md rule 4 changed 2026-10-19). Page /changes only with the returned
`nextCursor` (passed back as `cursor`); `nextSince` is for dating only.

Q9 OPEN. Does a /changes replay from an early date return every current EU entry
(completeness of option A)?
  - Observed 2026-10-19: `since=2000-01-01`, page 1 `total: 15205` (rows remaining after
    the cursor, not corpus size), earliest `knownSince` 2026-08-01T00:30:42Z, all 400 rows
    `FIRST_RECORDED`, CLP Annex VI Table 3 only, 14 GROUP entries, all with identifiers.
  - Not demonstrated: that the replay includes every annex, identifier-less collective
    entries, and nothing that lookup returns but the feed omits. Completeness check
    proposed in results/2026-10-19-kickoff.md, not run.
