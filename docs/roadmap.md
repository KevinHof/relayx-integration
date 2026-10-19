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
1. Full replay via /changes (done 2026-10-19: EU replay 15,205 rows, completeness check 249/249). Gate: completeness check result reviewed by Kevin. Then ADR on extraction strategy (to be provided by Kevin).
2. Raw load and broad extraction. Gate: ADR-001 (raw and ops layers, database role), accepted 2026-10-19.
   Status 2026-10-19: 2a done (replay loaded, all checks pass); corpus lists, narrow entry history and the per-substance pilot extracted and loaded; full per-substance run not started (awaits Kevin's decision on the pilot recommendation).
   a. Load the /changes replay into relayx_raw.changes_page and relayx_raw.entry_version.
   b. Extract every other endpoint into relayx_raw.api_response: corpus lists first
      (texts, coverage, allergens), then per-substance endpoints (lookup, market-summary,
      impurity-limits, screening, opinions) and entry history as background runs, each
      with a completeness report.
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
