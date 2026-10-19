# Open questions (as of 2026-10-19)

Status values: OPEN, ASKED (to Relay X), ANSWERED (link the ADR).

Q1 OPEN. Full-extract completeness. No bulk export endpoint is documented in the PDF.
Enumerating by identifier does not reach the ~20,470 current constraints with no
identifier (GROUP entries such as "... and its salts"). Does openapi.json expose a bulk
or list-entries endpoint? If not, ask Relay X.

Q2 OPEN. Re-fetching changed entries. /changes returns logicalEntryId + changeKind only.
Lookup works by substance identifier, not by entry id. Does /entries/{id}/history (or
any other route) return full current entry content?

Q3 OPEN. Extract runtime. At 60 units/min, ~14,000 lookups need roughly 4 hours
minimum. Confirm actual substance count and acceptable re-baseline cadence.

Q4 OPEN. Absence semantics. How to model 403 / 404 / withheldByScope /
INSUFFICIENT_DATA / missingZones as explicit states in raw and core layers.

Q5 OPEN. Seed list. Is identifiersonlyEU2.csv the complete EU substance index
(the PDF mentions 8,728 EU-covered substances), and how is it kept current?

Q6 OPEN. Schema layout. Proposal (not decided): relayx_raw (append-only responses),
relayx_ops (run log, cursor), relayx_core (normalised, versioned), plus a matching
layer. Needs an ADR before any schema is created.
