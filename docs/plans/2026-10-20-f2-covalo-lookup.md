# Plan F2: lookup run with Covalo identifiers first

Status: run approved by Timo (2026-10-22). Preparation done 2026-10-22 (value list, run command,
pre-flight command, dry run, runbook section 5a); the run has not started.

Goal: every distinct Covalo identifier gets Relay X's own status from EU lookup, so match and
mismatch can be stated before contract signature. Basis: results/2026-10-20-f1-matching-assessment.md.

## Source list
- All distinct Covalo values under the F1 rules (setup of sql/provisional/f1_matching_assessment.sql),
  not only values new to Relay X: CAS 6,766, EC 1,567, INCI 13,912, NAME 1,519 (`iupac`).
- One item per (type, value), one identifier per item, never combined, not deduplicated by
  substance: the question is the status of each Covalo identifier. Each item is queried with
  its own parameter (`cas`, `ec`, `inci`, `name`).
- CAS and EC values failing the check digit (CAS 227, EC 34) are not queried. They go to a
  separate list for local classification (M4e).
- Queried: 23,503 items (CAS 6,539, EC 1,533, INCI 13,912, NAME 1,519). Ordered by number of
  Covalo products, descending, so a partial run already covers most product links.
- Built with `python -m relayx.lookup_values build` into data/f2_lookup/20261022/ (gitignored):
  values.csv SHA-256 489d4c662807752b583a86ca8b5b80e6bc0b37ebdafec5a3881a35339ee343c9;
  excluded_check_digit.csv SHA-256 ae772164b7f5f75e186fdd4d6607a6f57ceb1cf10a5804bc9fca3fc4eb10f194.
  The run stores the list hash and refuses to resume against a changed list.
- Identifier-less ingredients (F1b item 2): no identifiers for the 41,985 products were found
  elsewhere in schema covalo that could serve as lookup values, so the list is unchanged.
- Values already in the existing source list (4,250) are not re-queried by the later full
  per-substance run if their F2 snapshot is recent.

## Calls
- lookup:batch only: `territory=EU`, `view=full`, 25 items per call, `limit=100` (25 x 100 =
  2,500 cap), default sections and default context, the same body as run
  20261019T174653Z_substance_pilot_eu. No GET lookup follow-ups: items whose `total` exceeds
  the rows returned are flagged in the analysis; any follow-up needs its own approval.
- Command: `python -m relayx.substance_pilot lookup` (relayx.covalo_lookup), runbook
  section 5a. Pre-flight first: `python -m relayx.substance_pilot preflight` (1 unit, /texts),
  which records RateLimit-Limit, -Remaining, -Reset and -Policy.
- Pacing on our own unit count (one unit per item sent), `--rate-per-minute` default 60, never
  above 300. 300 per minute only after the pre-flight shows a policy of 300. RateLimit-*
  headers are logged after every batch next to our count.
- 429: wait Retry-After + 2 s, else until RateLimit-Reset + 2 s. `truncated: true` (quota or
  the 20-second server time budget): `truncatedReason` recorded, then exactly the items after
  the last returned index are resent; unevaluated items are never recorded as results.
- `ok: false` items: error and message recorded, not retried, listed at the end (M5).
- Hard unit cap `--max-units`, default 24,000: the run stops cleanly before a batch or resend
  that would exceed it. 5xx and network errors: at most 3 retries with backoff; 401, 403 or
  any 400 stop the run (400 with the full body logged); 10 consecutive failed batches stop it.
- Every response is written byte-exact to data/raw/api/<run_id>/ and recorded before the next
  call; `--resume` restarts at the first unrecorded item and re-sends nothing recorded.
  Windows is kept awake from inside the process. `--max-items N` for a canary run.
- No database access during the run. Loading afterwards with `python -m relayx.load_raw`
  into `relayx_ops.extract_run` and `relayx_raw.api_response` (ADR-001 Amendment 1), with the
  usual count and hash checks. `source_ref` per call lists each item's seq, type, value and
  product count.
- Per-item record: the run manifest holds a ledger (call_no, index, type, value, ok, error,
  message, ingredientStatus) and a call log (items sent per call, SHA-256 of the exact request
  bytes). The stored bodies in `relayx_raw.api_response` are the single source of truth; the
  loader reconciles the ledger with them (item count per call, index, ingredientStatus, ok,
  error) and stops on any mismatch. The ledger is stored with the manifest in
  `relayx_ops.extract_run.manifest`. No new table.
- Units: 23,503 in 941 calls, plus resends after truncation. Duration: about 6.5 h at 60 per
  minute; at 300 per minute about 78 min by quota, but about 93 min by latency (pilot mean
  5.9 s per 25-item call, calls are sequential). Disk: about 0.62 GB at the pilot's
  26,463 bytes per item; upper bound 3.1 GB at 130 KB per item.

## Captured per item
`ingredientStatus.status` (contract enum: HAS_DATA, KNOWN_WITHOUT_DATA, UNKNOWN_IDENTIFIER,
NOT_SEARCHED), `ok`, `error`, `message`, `total`, returned logicalEntryIds, `otherNameMatches`,
`baseForm`, `withheldByScope`, `missingZones`, batch `truncated` and `truncatedReason`, HTTP
status. Absence states stored explicitly (CLAUDE.md rule 5).

## Mismatch classification
Per identifier first, then rolled up per Covalo product.

| Class | Meaning | Source |
|---|---|---|
| M0 matched | at least one identifier HAS_DATA, entries consistent across the product's identifiers | lookup |
| M1 no usable Covalo identifier | no value, or only unparsable values | Covalo side (46,274 products in F1) |
| M2 known without EU data | KNOWN_WITHOUT_DATA on every queried identifier; never read as "unregulated" | lookup |
| M3 unknown to Relay X | UNKNOWN_IDENTIFIER on every queried identifier | lookup |
| M4 ambiguous or conflicting | see sub-classes | lookup + replay |
| M5 not resolved | NOT_SEARCHED, `ok: false`, HTTP error, or not reached before a stop | lookup |

M4 sub-classes:
- M4a identifier disagreement: identifiers of one product resolve to different entry sets
  (e.g. CAS HAS_DATA, INCI KNOWN_WITHOUT_DATA or other entries); F1 indicator: 806 products.
- M4b GROUP fan-out: match only through a GROUP entry, or one value resolves to many entries
  or linked substances.
- M4c name containment only: the term appears in `otherNameMatches`, not in `constraints`.
- M4d Covalo multi-value value: a multi-CAS string (mixture) resolves to several substances.
- M4e check digit failure on the Covalo value: not queried, classified locally from the
  excluded list (261 values).
Mixed M2 and M3 on one product rolls up to M2. Matches only through EXEMPTION or
INVENTORY_LISTED entries are reported as a separate flag on M0 (F1: 5,683 products).

## Cross-checks and output
- Every returned logicalEntryId is in the replay; replay-based F1 matches that lookup does
  not return are listed as discrepancies.
- Results file: counts per class and sub-class, by identifier type and by product type and
  segment, plus the M4 lists for review.

## Decisions
1. Run approved (Timo, 2026-10-22).
2. NAME items (1,519 `iupac` values, whole-term match) are included in the value list.
3. Screening and opinions for Covalo values: decide after the opinions validation sample.
