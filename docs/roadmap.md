# Roadmap

Phases run in this order. Each one has a gate; do not start a phase before its gate is passed.

0. Kickoff (done): environment, API contract, open questions.
1. Full replay via /changes (in progress). Gate: completeness check result reviewed by Kevin. Then ADR on extraction strategy.
2. Raw load: entry versions into Postgres as JSONB, unchanged, with provenance. Gate: ADR-001 (raw and ops layers, database role).
3. Structure profiling: field dictionary in docs/data-model/, profiling queries in sql/profiling/. Gate: Kevin reviews the profile.
4. Core model: grains, entities and identifier model as an ADR, based on the profiling.
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

Running records: docs/vendor-evaluation.md (findings about Relay X data and API), docs/questions-for-relayx.md (batched questions).
