# Open questions (as of 2026-10-20)

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
  - The ~20,470 figure comes from the `searchMeans` text of lookup responses (scope not
    stated). The EU replay holds 2,079 current entries with no identifier, so 20,470 is
    most likely all territories. Asked to Relay X.
  - Full EU replay done 2026-10-19: 15,205 rows, 15,064 entries, 15,058 current
    (results/2026-10-19-kickoff.md). Completeness tracked in Q9.

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
  - Measured 2026-10-19: full EU replay 77 pages, 77 units, 72 s plus one quota wait,
    170 MB raw. Re-baseline is cheap; cadence still to decide.

Q4 OPEN. Absence semantics. How to model 403 / 404 / withheldByScope /
INSUFFICIENT_DATA / missingZones as explicit states in raw and core layers.
  - Note: the live `subscription` block also carries `unavailableZones`, which is not in
    the contract schema.

Q5 OPEN. Seed list. Is identifiersonlyEU2.csv the complete EU substance index
(the PDF mentions 8,728 EU-covered substances), and how is it kept current?
  - 2026-10-19 sample: 67 of 210 catalogue rows return `KNOWN_WITHOUT_DATA` on EU lookup
    (31 of 50 EC-only rows). The catalogue is wider than the EU entry set. With option A it
    is no longer needed as a seed list, only as a test sample source.

Q6 OPEN. Schema layout. Proposal (not decided): relayx_raw (append-only responses),
relayx_ops (run log, cursor), relayx_core (normalised, versioned), plus a matching
layer. Needs an ADR before any schema is created. The ADR also covers a read-only DB role.

Q7 ANSWERED (Relay X, Pierre, Slack, 2026-10-19; RX-1). Quota: binding limit, unit cost
per /changes page, RateLimit-Reset format. The RateLimit-* headers remain the runtime
source of truth (CLAUDE.md rule 4).
  - Answer: 60 requests per minute per subscription, shared across all our keys.
    `RateLimit-Policy: 15000;w=900` is a platform-wide per-IP safeguard, not our limit;
    Relay X will fix the header and the docs. One /changes page = one unit regardless of
    size; `limit=200` is the maximum. Trial runs on the standard 60/min, adjustable when
    going commercial based on stated throughput.
  - RateLimit-Reset format: answered by observation (2026-10-20): contract and
    authenticated responses agree on a Unix timestamp; parsing stays defensive.
  - Observed on unauthenticated routes: `RateLimit-Limit: 15000`, Reset 900 / 793.
  - Observed on authenticated /changes: `RateLimit-Limit: 60`, Remaining 59 then 58
    (1 unit per page), Reset `1792419799` (Unix timestamp, 60 s ahead).
    `RateLimit-Policy: 15000;w=900` appears on both, possibly a separate gateway limit.
  - lookup:batch: items x limit is capped at 2,500 (400 `batch_result_too_large`, not in
    the contract). Remaining on batch responses lags: a batch was truncated mid-way after
    the previous response showed 22 units left. Header-based unit counts undercount batches.

Q8 ANSWERED (CLAUDE.md rule 4 changed 2026-10-19). Page /changes only with the returned
`nextCursor` (passed back as `cursor`); `nextSince` is for dating only.

Q9 ANSWERED by evidence (ADR-002, 2026-10-20). Does a /changes replay from an early date return every current EU entry
(completeness of option A)?
  - Observed 2026-10-19: `since=2000-01-01`, page 1 `total: 15205` (rows remaining after
    the cursor, not corpus size), earliest `knownSince` 2026-08-01T00:30:42Z, all 400 rows
    `FIRST_RECORDED`, CLP Annex VI Table 3 only, 14 GROUP entries, all with identifiers.
  - Full replay 2026-10-19: last page `truncated: false`, sum of `returned` = 15,205 =
    page 1 `total`. 33 annexRef values incl. CITES; 2,079 current entries without
    identifiers (all named).
  - Completeness check 2026-10-19: 249 of 249 entries returned by EU lookup for a
    stratified sample of 210 catalogue identifiers are in the replay (rate 1.000 in every
    stratum, 0 misses; 95 % upper bound on miss rate about 1.2 %).
  - /texts 2026-10-19: sum of `constraintCount` over 115 EU texts = 15,205 = replay rows.
  - Answered 2026-10-20 by evidence (ADR-002): replay row counts, lookup cross-check
    249 of 249, /texts `constraintCount` sum. Phase 1 gate passed. Limit: completeness of
    entries unreachable by lookup rests on internal consistency and Relay X's statement of
    method. Relay X confirmed the method (Slack, 2026-10-19); explicit confirmation that
    nothing is withheld beyond `withheldByScope` is pending under RX-3 (PARTLY ANSWERED).
  - The current-version issue for multi-version entries is tracked in Q10.

Q10 OPEN. Core model: how to determine the current version of an entry when feed order and
`isCurrent` disagree. Facts (2026-10-19): 31 of 147 multi-version EU entries have two versions
with `isCurrent: true`; `supersededByVersionId` points to version ids that are not exposed;
for 4 entries feed order and the supersession marker disagree (VE-16 to VE-18). Options to
decide in the phase 4 ADR: feed order, supersession marker by elimination, latest
`knownSince`, or flag as ambiguous and keep both. Asked to Relay X (RX-17, RX-18).

Q11 OPEN (2026-10-20). CosIng source for F3 (docs/plans/2026-10-20-f3-cosing-bridge.md):
which CosIng export is used, and where it is loaded in covalo-local-complete (schema, table).
To be confirmed by Kevin; file name, download date and SHA-256 are recorded at profiling.
