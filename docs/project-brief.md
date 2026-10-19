# Project brief

## Objective
End-to-end integration of Relay X regulatory data into Covalo: ingestion, restructuring,
identifier matching and merge, versioning. Built and validated locally, then handed over.

## Planned components
1. Full extract: pull all accessible Relay X EU data and reconstruct it in local Postgres.
2. Scheduled diff pull: incremental updates via GET /changes with a stored cursor.
3. Analysis of the reconstructed data (coverage, completeness, GROUP entries, overlap).
4. Mapping and overlap testing against Covalo identifiers (INCI, CAS, EC, IUPAC).
5. SQL ingestion pipeline for periodic matching and merge into the Covalo data model.

## Matching approach
- INCI is the primary identifier but inconsistent in spelling and synonyms on both sides.
- CAS / EC / IUPAC are more precise but coverage is uneven on both sides.
- No predefined match-rate cutoff. Measure match rate by identifier type and ingredient
  category, then define proportional responses (auto-merge, flagged review, exclusion).
  Defining that framework is part of the work.

## Versioning
Detect and log Relay X updates over time, reusing the approach of the earlier CosIng
pipeline design (hash-based change detection, delta logging) where applicable.

## Prior exploration (sample data, schema `kevin`)
- Sample file demo-api-EU-2026-08-19.json: 54 substances, 189 constraint entries,
  180 unique logicalEntryId after dedup (logicalEntryId is the lowest stable grain).
- Scripts build_entries_table.py and build_product_clusters.py produced
  kevin.relayx_entries_table (180 rows) and 143 CAS-anchored clusters with a long
  identifier table (1,537 rows across INCI, CAS, EC, CHEMNAME).
- covalo_identifiers_long built by unnesting Covalo JSONB array columns
  (guard: jsonb_typeof(col) = 'array', because JSON null scalars pass IS NOT NULL).
- Join on (identifier_type, identifier_value_normalized): 121 of 143 clusters matched.
- Known bug: about 40% of clusters are exact duplicates, caused by GROUP entries fanning
  out to multiple CAS values without per-CAS disambiguation. Not yet fixed.
- Ground-truth accuracy validation not yet performed.
- identifiersonlyEU2.csv is Relay X's own identifier catalogue (14,207 rows),
  not Covalo data.
