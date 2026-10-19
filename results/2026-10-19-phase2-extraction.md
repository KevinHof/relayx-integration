# 2026-10-19 Phase 2: raw load, corpus lists, entry history, per-substance pilot

All runs: territory EU, key with zone EUROPE. Raw files in `data/raw/`, loaded into
`relayx_raw` as `relayx_app` (ADR-001 and Amendment 1). Units: 761 requested in total
(3 + 147 + 460, plus 151 earlier today for the replay and checks are not counted here).

## 2a. Raw load of the /changes replay (run 20261019T143522Z_eu)
- `sql/001_raw_ops.sql` run as relayx_app: extract_run, changes_page, entry_version,
  api_response, view, append-only triggers.
- Loaded 77 pages and 15,205 entry versions (15,064 entries). Checks: rows = manifest =
  sum of `page_returned` = page 1 `total`; 0 non-200 pages; 0 duplicate
  (logical_entry_id, known_since); 0 null known_since; all 15,205 payload hashes
  recomputed from the stored JSONB match (canonical JSON round-trip is lossless).
- Guards verified: UPDATE, DELETE and TRUNCATE on raw tables are refused; reloading a
  loaded run is refused.

## 2b. Corpus lists (runs 20261019T174201Z_{texts,coverage,allergens}_eu)
| Endpoint | Access | Rows (= total) | Notes |
|---|---|---|---|
| /texts | 200 | 115 | 111 IN_FORCE, 4 without status, all legislator EC; sum of `constraintCount` = 15,205 = replay rows; `withheldByScope.count` 1 |
| /coverage | 200 | 51 scopes | 49 COMPLETE, 2 PARTIAL (both CITES species annexes); 44 negative, 6 positive, 1 mixed list |
| /allergens | 200 | 137 | basisActs `32009R1223` (PDF said 129 and 32023R1545) |
One unit each, one page each. Loaded; body hashes match after round-trip.

## 2c. Entry history, narrow option (run 20261019T174304Z_history_narrow_eu)
147 entries (141 with two versions, 6 retracted), 147 calls, all 200, loaded.
- Every one of the 288 versions matches a /changes row on `knownFrom` = `knownSince`, and
  the entry content is identical. History adds only the `knowledge` block; the feed adds
  only `changeKind`. For single-version entries history would add nothing beyond
  knownFrom = knownSince, so the full run (15,064 units) is not worth it.
- Knowledge window: 110 entries as documented (old version closed); 6 retracted as
  documented; 31 entries have BOTH versions `isCurrent: true` with `knownUntil: null`
  although one carries `supersededByVersionId` and `RULE_CHANGED` (VE-16).
- No version ids are exposed, so `supersededByVersionId` resolves only by elimination (VE-17).
- The 4 out-of-order entries: both versions current; the supersession marker sits on the
  later version, so the earlier one is the successor and "last row in feed" picks the
  superseded version (VE-18). Current-version rule is open for the core model (Q10).

## 2d. Per-substance redundancy pilot (run 20261019T174653Z_substance_pilot_eu)
100 catalogue items, seed 20261020: CAS 40, EC-only 20, INCI-only 20, name 20. 364 calls,
all 200, 460 units. Lookup via lookup:batch `view=full`, `limit=100` (no item exceeded it).
Name items were not sent to screening and opinions (40 NOT_QUERYABLE).

| Stratum | Lookup HAS_DATA | Screening endpoint items (substances) | in lookup context | Opinions endpoint = lookup | Impurity limits | Market-summary EU rows = lookup |
|---|---|---|---|---|---|---|
| CAS (40) | 28 | 34 (22) | 21 (10) | 2 = 2 | 0 | 28 of 28 |
| EC-only (20) | 10 | 10 (10) | 0 (0) | 0 = 0 | 0 | 10 of 10 |
| INCI-only (20) | 20 | 0 | 0 | 0 = 0 | 0 | 20 of 20 |
| Name (20) | 7 | not queryable | n/a | not queryable | 0 | 7 of 7 |

- Screening: lookup's `screeningLists` is a strict subset of the screening endpoint
  (21 of 44 items) and is empty for EC-only queries. The 23 extra items (ECHA dossier
  evaluation, CLH, restriction processes, EU positive list) are not in
  `regulatoryPipeline` either. The endpoint carries content lookup does not.
- Opinions: identical in both places, but only 2 substances had any opinion.
- Impurity limits: 0 of 100 returned a limit (99 `substanceKnown: true`).
- Market-summary: EU `constraintCount` and `entryRefs` equal the lookup result in all 65
  cases. The only other market is MC (Monaco, EU annexes by reference), which lookup also
  carries in `alsoAppliesIn`. EU rows also carry `coverage` (= /coverage summary),
  `appliesTo` (27 member states, direct) and `referencedBy` (other territories borrowing
  EU law); these are the same for every substance and are already in the pilot raw.
  The only substance-specific part not read directly from entries is the verdict
  (`status`, `statusBasis`, `statusMeans`): e.g. 8 CAS substances with EU constraints are
  `INSUFFICIENT_DATA`. Relay X's derivation rule for it is not documented.

## Recommendation for the full per-substance run (not started)
1. Lookup (lookup:batch, `view=full`, 25 items x `limit=100`): yes. About 16,000 units.
2. Screening: yes, the endpoint is not covered by lookup. About 14,000 units (no names).
3. Opinions: yes, provisionally. Equality rests on 2 substances, and the sibling context
   block (screening) proved incomplete. About 14,000 units. Can be dropped if a larger
   sample confirms equality.
4. Market-summary: exclude. Its EU content equals the entries; the remaining verdict can be
   derived and checked against the 101 pilot rows when a use needs it.
5. Impurity limits: defer. 0 of 100 yielded content; wait for RX-14 (list route) or run
   a targeted list of known contaminants (heavy metals, 1,4-dioxane, methanol, ...).
Total for 1 to 3: about 44,000 units, about 12 h of quota at 60/min, in background runs.

## Open points
- Kevin: decide on the recommendation above; provide the extraction-strategy ADR.
- Q10 (current version rule), RX-17 to RX-19 added; VE-15 to VE-21 recorded.
