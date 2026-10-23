# Session handover, 2026-10-23

Session from 2026-10-19 to 2026-10-23. State at close: working tree clean, no background run
active, nothing pushed (all commits local on main). Figures in results/ are PROVISIONAL.

## Main track (phases, extraction, raw layer, Relay X questions)
Done:
- Kickoff, contract analysis, /changes validation: 6b39bb8, f421dd6.
- Phase 1, resumable /changes replay and completeness check: 18c8925. ADR-002 extraction strategy,
  phase 1 gate closed, Relay X quota answers: 43529e9.
- ADR-001 raw and ops layers accepted: aaf1b50; principle "extract broadly, model late", coverage
  inventory: 498b00a, a5f7151.
- Phase 2, raw load, corpus lists, narrow history, per-substance pilot: b5b568f.
- Shared Relay X question list and RX mapping: 8bbec20, f31195d.
- Runbook: 8b1a3d3; `--resume` for corpus-list, history and per-substance commands: d0964fe.
- Atlas data pack: d66ecfe. Vendor evaluation VE-25 to VE-33, RX-21, cosmetics scope proposal:
  c2a53d2. Targeted checks (opinions, impurity, IFRA; 145 units): 95838f7. Annex XVII 28 to 30
  finding and CMR redundancy check: 1e5bd05. Fast-track order and legal accuracy track: 6ee758f.
- Relay X guide v1.1 hash recorded and contract re-fetched 2026-10-22 (docs/relayx/README.md,
  docs/relayx/openapi-2026-10-22.json): 67bfa06.
- Loader duplicate check keyed on (logicalEntryId, knownSince, event), 3 tests: b651ee9.
- Second full EU /changes replay prepared in runbook section 5a (commands, comparison plan,
  relabel rule for changeKind and publishedOn): 3e7946d, b651ee9. Not run.
Pending:
- Second EU replay: not run, not loaded; comparison query not written.
- docs/vendor-evaluation.md and docs/questions-for-relayx.md are not updated with this session's
  F2 findings (contract differences 2026-10-22, Relay X answer on Q08 / "2292", truncation
  charging, CARBOMER link, inciList fragments, ULTRAMARINES); Kevin said these come separately.
- RX-17 to RX-21 DRAFT; RX-2, RX-4 to RX-14, RX-16 ASKED; RX-3 PARTLY ANSWERED.
- Open questions Q1, Q3 to Q6, Q10, Q11 (CosIng capture URL and date PENDING), Q12.
- Cosmetics scope document is PROPOSED, review by Kevin pending.
- replay_stats still counts (logicalEntryId, knownSince) without `event`.

## F1 and F1b (pre-signing matching assessment, step 1)
Done: F1 step 1 and step 2 plan: 194a5ce. F1b additions: e1aa065. Results:
results/2026-10-20-f1-matching-assessment.md.
Pending: nothing open in this track; F1 objects are reused by F2 and F3 analyses.

## F2 (lookup run with Covalo identifiers)
Done:
- Preparation (value list builder, `substance_pilot lookup` and `preflight`, ledger check in the
  loader, tests, dry run, runbook 5a): 67bfa06.
- Runs by Kevin 2026-10-22: canary 20261022T075600Z_covalo_lookup_eu_canary100 and full run
  20261022T075923Z_covalo_lookup_eu (23,503 items, 23,514 units), both loaded into relayx_raw.
- Run profile: 4f1736a. Drill-down B1 to B7 and Covalo CAS quality (Part A): 3e7946d.
  Verifications 2a to 2f: b651ee9. Results: results/2026-10-22-f2-lookup-run.md,
  results/2026-10-22-covalo-cas-quality.md. SQL: sql/provisional/f2_lookup_profile.sql,
  sql/provisional/covalo_cas_quality.sql.
Pending:
- M0 to M5 mismatch classification not started.
- Whether Relay X charges a truncated batch per item sent or per item evaluated (call 888).
- "2292" vs the replay count (2,298 versions, 2,288 entries) not reconciled.
- The loader reports a failed check with exit code 1 after the transaction has committed; a hard
  refusal was offered, not decided.

## F3 (CosIng bridge) and catalogue bridge
Done:
- Plan and provenance: a865119. Part 1 profile and reconciliation: 1e4f2bb.
- Catalogue bridge and VE-36 / Q12: 9f39526, 400e27f.
- Part 2 (Q2 INCI matching, Q3 bridge, Q5 referee flag): 7851699.
- Part 2b tier sizing and validation sample: 1354a62.
- Part 3 options A to D and reference: 39ee8c0.
- Results: results/2026-10-21-f3-cosing-profile.md, results/2026-10-21-f3-cosing-bridge-part2.md,
  results/2026-10-22-f3-tier-sizing.md, results/2026-10-22-f3-bridge-options.md,
  results/2026-10-21-catalogue-bridge.md. SQL: sql/provisional/f3_cosing_bridge.sql,
  sql/provisional/catalogue_bridge.sql.
Pending:
- Kevin's verdicts on the validation sample (data/validation/f3_tier_sample.csv, columns verdict
  and note empty).
- Rule for the 1,209 CAS conflicts; choice of option for use.
- Q6 (Relay X side INCI against CosIng) not started.
- CosIng capture URL and capture date PENDING (Q11).

## Files outside the repository
- Gitignored data: data/f2_lookup/20261022/ (values.csv, excluded_check_digit.csv, build.json,
  SHA256SUMS.txt); data/validation/f3_tier_sample.csv (120 rows, SHA-256
  BEEEF7049559818229B9300944B56471D053B4C07D8502A3E542C1BB48402DAF); raw runs under data/raw/.
- Scratch files in the session scratchpad (temporary directory, not in the repo), including
  q16_to_csv.py, the converter that wrote data/validation/f3_tier_sample.csv from section q16 of
  the F3 report output; fetch_openapi.py and diff_openapi.py (contract fetch and diff of
  2026-10-22); pilot_bytes.py; exploration SQL f1_extra*.sql, f2_explore*.sql, f2_extra*.sql,
  f2_notsearched.sql. The sample can be regenerated from section q16; the converter itself is not
  committed.
- Uncommitted work in the repository: none.
