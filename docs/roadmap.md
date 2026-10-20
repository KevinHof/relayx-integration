# Roadmap

Principle: extract broadly, model late. All Relay X content accessible to our key is
extracted into the raw layer with full provenance. Core models are built per content type
only when a concrete use needs them. Every extracted endpoint gets an entry in the coverage
inventory (docs/relayx/coverage-inventory.md) and the field dictionary, and every extraction
run reports its completeness (what was queried, what returned content, from which source
list). Content without a change feed is kept as dated snapshots and compared by hash
between runs.

Phases run in this order. Each one has a gate; do not start a phase before its gate is passed.

0. Kickoff (done): environment, API contract, open questions.
1. Full replay via /changes (complete: EU replay 15,205 rows on 2026-10-19, completeness check 249/249). Gate passed 2026-10-20: completeness check reviewed by Kevin, extraction strategy recorded in ADR-002 (docs/decisions/002-extraction-strategy.md).
2. Raw load and broad extraction. Gate: ADR-001 (raw and ops layers, database role), accepted 2026-10-19.
   Status 2026-10-19: 2a done (replay loaded, all checks pass); corpus lists, narrow entry history and the per-substance pilot extracted and loaded; full per-substance run not started (awaits Kevin's decision on the pilot recommendation).
   a. Load the /changes replay into relayx_raw.changes_page and relayx_raw.entry_version.
   b. Extract every other endpoint into relayx_raw.api_response: corpus lists first
      (texts, coverage, allergens), then per-substance endpoints (lookup, market-summary,
      impurity-limits, screening, opinions) and entry history as background runs, each
      with a completeness report.
   Decisions 2026-10-20 (Kevin): market-summary excluded from the full run (verdict question
   RX-20); opinions validated on a targeted sample of about 50 Annex III / V substances
   (if lookup matches the endpoint, opinions come from lookup and the separate run is
   dropped); impurity limits checked on about 20 known contaminants. Full per-substance
   run waits for fast-track F step 1 and the step 2 lookup plan.
   Results 2026-10-20 (results/2026-10-20-targeted-checks.md): opinions equal on 50 of 50,
   so the separate opinions run is dropped; impurity limits for 10 of 20 contaminants;
   IFRA_STANDARDS served for 12 of 20 fragrance allergens.
F. Fast-track (2026-10-20): pre-signing matching assessment. The contract with Relay X is
   signed only after the full scope of match and mismatch between Relay X and Covalo data
   is known. Runs on raw data with provisional SQL (sql/provisional/), every object and
   figure labelled PROVISIONAL, replaced later by the phase 8 matching. Does not pass any
   phase gate.
   - Step 1 (local, no API calls): Covalo identifier inventory, overlap with replay
     identifiers and the Relay X catalogue, provisional coverage by identifier type, size
     of the per-substance source list including Covalo identifiers. Done 2026-10-20
     (results/2026-10-20-f1-matching-assessment.md).
   - Step 2 (proposal): lookup run with Covalo identifiers first, so every Covalo
     identifier gets Relay X's own status; mismatch classification.
   Fast-track order (2026-10-20):
   - F1b: step 1 additions. Done 2026-10-20 (in the step 1 results file), under review.
   - F3: CosIng as reference for INCI quality and the INCI to CAS bridge
     (docs/plans/2026-10-20-f3-cosing-bridge.md). SCHEDULED, waiting for the CosIng load.
   - F2: Covalo-first lookup run (docs/plans/2026-10-20-f2-covalo-lookup.md). PARKED,
     awaiting internal approval.
   - F4: mismatch classification. After F2 and F3.
L. Legal accuracy track: check Relay X content against the legal texts (e.g. annex
   membership, CosIng annex references, the Annex XVII entries 28 to 30 check). NOT STARTED;
   run in a separate chat.
3. Structure profiling of every extracted content type, not only constraint entries: field dictionary in docs/data-model/, profiling queries in sql/profiling/. Gate: Kevin reviews the profile.
4. Core model, decided per content type in order of use: grains, entities and identifier model as an ADR per content type, based on the profiling. Constraint entries first.
5. Normalisation: raw JSONB into core tables, reproducible from raw, with tests.
6. Diff pull and versioning: incremental /changes pull from the stored cursor, change log, idempotence test (a second run changes nothing).
7. Analysis: coverage, identifier completeness, GROUP entries.
8. Matching and overlap: Covalo identifier extraction rebuilt in the repo, match unit = (Covalo product, logicalEntryId) pair with evidence, match rates by identifier type and category, confidence tiers as an ADR, validated on a labelled sample.
9. Ingestion pipeline and handover to the tech team.

Grain hypotheses to confirm or reject in phase 3:
- entry version: logicalEntryId + knownSince
- entry: logicalEntryId
- identifier: entry + type + value + position marker + provenance (literal from legal text vs enrichment)
- condition or limit: only if entries carry repeated conditions
- Covalo side: product + identifier type + value
Clusters are not a primary grain. If needed, they are a derived view, which avoids the GROUP fan-out behind the duplicate-cluster bug.

Running records: docs/vendor-evaluation.md (findings about Relay X data and API), docs/questions-for-relayx.md (batched questions), docs/relayx/coverage-inventory.md (endpoints, access, extraction method and status).
