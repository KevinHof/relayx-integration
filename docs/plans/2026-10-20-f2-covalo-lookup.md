# Plan F2: lookup run with Covalo identifiers first (PROPOSAL, not approved)

Goal: every distinct Covalo identifier gets Relay X's own status from EU lookup, so match and
mismatch can be stated before contract signature. Basis: results/2026-10-20-f1-matching-assessment.md.

## Source list
- 23,764 distinct Covalo values from the F1 rules (CAS 6,766, EC 1,567, INCI 13,912,
  NAME 1,519 from `iupac`). One item per (type, value), not deduplicated by substance: the
  question is the status of each Covalo identifier.
- Each item queried with its own parameter (`cas`, `ec`, `inci`, `name`). Values failing the
  check digit (261) are queried and flagged. Raw strings with no usable token are not
  queried; they count as class M1.
- Ordered by number of Covalo products, descending, so a partial run already covers most
  product links. Built locally, versioned by content hash, stored with the run.
- Values already in the existing source list (4,250) are not re-queried by the later full
  per-substance run if their F2 snapshot is recent.

## Calls
- lookup:batch, `territory=EU`, `view=full`, `context=true`, 25 items x `limit=100`
  (cap 2,500); GET lookup with `offset` for items whose `total` exceeds 100.
- Raw into `relayx_raw.api_response` (ADR-001 Amendment 1), `source_ref` per item with type,
  value and product count. Completeness report per coverage-inventory section 5.
- Units: about 23,800 plus follow-ups, about 6.6 h at 60/min, one background run,
  resumable per batch, own unit counting with a margin above the batch size (VE-6).

## Captured per item
`ingredientStatus.status` (contract enum: HAS_DATA, KNOWN_WITHOUT_DATA, UNKNOWN_IDENTIFIER,
NOT_SEARCHED), `total`, returned logicalEntryIds, `otherNameMatches`, `baseForm`,
`withheldByScope`, `missingZones`, `truncated`, HTTP status. Absence states stored
explicitly (CLAUDE.md rule 5).

## Mismatch classification
Per identifier first, then rolled up per Covalo product.

| Class | Meaning | Source |
|---|---|---|
| M0 matched | at least one identifier HAS_DATA, entries consistent across the product's identifiers | lookup |
| M1 no usable Covalo identifier | no value, or only unparsable values | Covalo side (46,274 products in F1) |
| M2 known without EU data | KNOWN_WITHOUT_DATA on every queried identifier; never read as "unregulated" | lookup |
| M3 unknown to Relay X | UNKNOWN_IDENTIFIER on every queried identifier | lookup |
| M4 ambiguous or conflicting | see sub-classes | lookup + replay |
| M5 not resolved | NOT_SEARCHED, HTTP error, truncated and not re-queued | lookup |

M4 sub-classes:
- M4a identifier disagreement: identifiers of one product resolve to different entry sets
  (e.g. CAS HAS_DATA, INCI KNOWN_WITHOUT_DATA or other entries); F1 indicator: 806 products.
- M4b GROUP fan-out: match only through a GROUP entry, or one value resolves to many entries
  or linked substances.
- M4c name containment only: the term appears in `otherNameMatches`, not in `constraints`.
- M4d Covalo multi-value value: a multi-CAS string (mixture) resolves to several substances.
- M4e check digit failure on the queried value.
Mixed M2 and M3 on one product rolls up to M2. Matches only through EXEMPTION or
INVENTORY_LISTED entries are reported as a separate flag on M0 (F1: 5,683 products).

## Cross-checks and output
- Every returned logicalEntryId is in the replay; replay-based F1 matches that lookup does
  not return are listed as discrepancies.
- Results file: counts per class and sub-class, by identifier type and by product type and
  segment, plus the M4 lists for review.

## Decisions needed
1. Approve the run (about 23,800 units, about 6.6 h).
2. Include NAME items (1,519 `iupac` values, whole-term match) or not.
3. Screening and opinions for Covalo values: decide after the opinions validation sample.
