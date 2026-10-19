# Relay X coverage inventory (draft, 2026-10-19)

Every operation in the served contract (docs/relayx/openapi-2026-10-19.json), what it
provides, whether our key reaches it, how to extract it completely, estimated units and
status. Principle: extract broadly, model late (docs/roadmap.md). Raw target:
`relayx_raw.changes_page` / `entry_version` for /changes, `relayx_raw.api_response` for
everything else (ADR-001 and Amendment 1).

Access evidence (updated 2026-10-19 after phase 2 runs): every data route called so far returned 200. Earlier: subscription `grantedZones: ["EUROPE"]`, `withheldByScope.count` 0
on every /changes page, no 403 seen. Our scopes have not been read directly (a 403 would
list `grantedScopes`); per the PDF the EU corpus is fully served under `read:public`.
"Not called" means no evidence yet either way.

Unit estimates assume 1 unit per request for list routes and 1 per substance or entry for
keyed routes (contract: a batch item costs 1 unit). At the observed 60 units/min, 10,000
units take about 2.8 h of quota time. The binding limit is still asked (RX-1).

## 1. Summary

| Endpoint | Provides | Key access | Extraction method | Est. units | Status |
|---|---|---|---|---|---|
| GET /health | service status | yes (200, no key) | n/a | 0 | not content |
| GET /openapi.json | contract | yes (200, no key) | snapshot per run, en (and fr) | 0 | snapshot 2026-10-19 (en) |
| GET /changes | every recorded version of every entry, full `Contrainte` | yes (200) | time-keyed feed, cursor | 77 (EU) | DONE (run 20261019T143522Z_eu), loaded, all checks pass |
| GET /entries/{id}/history | all versions with `knowledge` window (knownFrom/Until, retracted, supersession, coveredBy) | yes (200) | per entry, from replay ids | 15,064 (all) or 147 (narrow) | narrow DONE 2026-10-19 (147), loaded; full not planned (adds only knownFrom = knownSince) |
| GET /texts | legal text catalogue, amendment chain, validity, deadSourceUrls | yes (200), 1 text withheld | paginated list per territory | 1 (EU, 115 texts) | DONE 2026-10-19, loaded |
| GET /coverage | coverage scopes, completeness, absenceMeans | yes (200) | paginated list per territory | 1 (EU, 51 scopes) | DONE 2026-10-19, loaded |
| GET /allergens | declarable allergens with threshold text, basisActs | yes (200) | paginated list per territory | 1 (EU, 137) | DONE 2026-10-19, loaded |
| GET /substances/lookup and POST lookup:batch | constraints in force, `upcoming`, `substanceContext` (opinions, screening, precedents, pipeline), ingredientStatus, otherNameMatches, baseForm | yes (batch 200) | per substance from the source list | about 16,000 plus paging follow-ups | pilot of 100 loaded; full run recommended |
| GET /substances/market-summary | verdict per market, statusMeans, entryRefs; no text | yes (200) | per substance | about 16,000 | pilot of 100 loaded; full run not recommended (EU rows equal lookup) |
| GET /substances/impurity-limits | impurity thresholds per market, regime, matrix, verificationLevel | yes (200) | per substance (name accepted) | about 16,000 | pilot: 0 of 100 with limits; deferred (RX-14) |
| GET /substances/screening | screening list membership (PFAS EPA, IFRA, ECHA processes), links | yes (200) | per substance (cas, ec, inci only) | about 14,000 | pilot of 80 loaded; full run recommended (lookup holds a subset) |
| GET /substances/opinions | scientific opinion pointers (body, reference, date, link) | yes (200) | per substance (cas, ec, inci only) | about 14,000 | pilot of 80 loaded; full run recommended provisionally |
| POST /mcp | same data as the HTTP routes, same quota | not used | not a separate source | 0 | out of scope |

Per-substance total: about 80,000 units, about 22 h of quota time at 60/min, run in the
background over several sessions. Corpus lists: under 10 units.

## 2. Limits by licence or design (content we will NOT get, whatever we extract)
- Opinions: pointers only (body, reference, date, link). No opinion text, limit or verdict
  (CIR and WHO licences). An empty list means "no opinion attached", not "none exists".
  Attached by substance, never by name.
- Screening: membership only. IFRA thresholds are not returned (private association); the
  link points to the IFRA document. `substanceKnown: false` means the identifier is not in
  the index and nothing is concluded. Name not accepted.
- Impurity limits: seven regimes (`MANDATORY_LIMIT` to `NON_DETECTABLE`) that are not
  comparable; each value carries `verificationLevel`, and some are `UNVERIFIED` ("no value
  is opposable until its verificationLevel is countersigned"). Name matched exactly.
- Allergens: `declarationThreshold` is text, not a number.
- Texts: `constraintCount` is not filtered by validity; amendment chains are incomplete when
  `withheldByScope.count` > 0; `deadSourceUrls` lists acts whose source link no longer resolves.
- Lookup: `view=standard` drops all `*Means` prose and `literal.fullText`; `view=summary` is a
  different flat shape; `linkedSubstances` capped at 25 substances x 40 values;
  `otherNameMatches` lists at most 50; `scanCapped` makes `total` a lower bound; `asOf`
  filters by date but does not restore superseded wordings (one consolidated version per act).
- Market-summary: no text; `AUTHORIZED` only where coverage is complete, else `INSUFFICIENT_DATA`.
- History: `truncated` flag with no paging (cause unknown, RX-10); 404 = not visible under
  our subscription.
- Scope `read:licensed` (LICENSED, RESTRICTED texts) is contractual; `UNQUALIFIED` texts are
  served to no one. Zones other than EUROPE return nothing (`missingZones`).
- Language: curated `means` are en by default, fr with `lang=fr`; free-text notes are French.

## 3. Extraction method per type
- Time-keyed (/changes): replay once from an early `since`, then incremental by stored
  cursor (phase 6). Complete by construction if Relay X confirms the feed (RX-3).
- Paginated lists (/texts, /coverage, /allergens): page with `limit=200` and `offset` until
  `returned` sums to `total`; one dated snapshot per run, compared by `body_sha256` per page
  with the previous run. Territory `EU` first; whether member-state codes (FR, DE, ...)
  return separate content is open (RX-16).
- Per entry (/history): ids from the replay. Option A all 15,064 entries (about 4.2 h);
  option B only entries with more than one version, retracted entries and the 4 ordering
  anomalies (about 150 units). The knowledge window is not in /changes rows, so A is the
  broad option.
- Per substance (lookup, market-summary, impurity-limits, screening, opinions): one call
  per source-list item per endpoint (lookup via lookup:batch). Snapshots, compared by hash
  per (endpoint, item) between runs. Lookup proposal: `view=full`, `context=true`, no
  `sections` (everything), `territory=EU`, batch of 25 with `limit=100` (items x limit cap
  of 2,500, VE-3), GET lookup with `offset` for items whose `total` exceeds 100.
  `substanceContext` in lookup may duplicate screening and opinions; to be checked on a
  sample before deciding whether both are needed.

## 4. Substance source list (proposal)
Union of three sources, each item tagged with its origin:
1. Replay, current entries: identifiers printed by the entry (`cas`/`casList`, `ec`/`ecList`,
   `inci`/`inciList`, `clpIndex`, `colourIndex`) and `linkedSubstances` identifiers (CAS, EC,
   INCI, CLP_INDEX, COLOUR_INDEX, SYNONYM). Measured: 7,759 distinct CAS, 8,613 distinct
   linked substances.
2. Relay X identifier catalogue (identifiersonlyEU2.csv / kevin.relayx_eu_identifiers_v2):
   14,207 rows, 11,686 distinct CAS, 2,988 rows without CAS.
3. Names of current entries with no identifier and no linked substance: 1,853 (mostly CITES
   species), queried by `name`.
Overlap measured on CAS: 7,747 in both, 3,939 catalogue only, 12 replay only, union 11,698.
Estimated list size with non-CAS items: about 16,000.

Item identity: one item per substance, deduplicated by CAS, then EC, then INCI, then
normalised name. Query identifier priority: CAS, EC, INCI, CLP index, Colour Index, name.
Items with only a name are queried on lookup, market-summary and impurity-limits, and
recorded as `NOT_QUERYABLE` for screening and opinions (name not accepted).
The list is built from local data, versioned by content hash and stored with each run.

## 5. Completeness report per extraction run
Every run writes results/<date>-<endpoint>-extract.md with:
- Source list: version hash, item counts by origin (replay only, catalogue only, both,
  name only).
- Strata: every count below is broken down by the query identifier used (CAS, EC-only,
  INCI-only, name). Name-based queries are always a separate stratum and never pooled with
  identifier queries, because matching semantics differ by endpoint: lookup `name` is a
  whole-term match (contract), impurity-limits `name` is an exact chemical-name match, and
  screening and opinions do not accept `name` at all (`NOT_QUERYABLE`).
- Per endpoint: items queried; result state counts: content returned, empty with stated
  reason (`ingredientStatus`, `substanceKnown: false`, empty list), HTTP 4xx/5xx by code,
  `truncated` or unevaluated and re-queued, `NOT_QUERYABLE`; items with `total` above the
  page and whether they were paged; `withheldByScope` and `missingZones` seen.
- Units: requests sent, units by headers, wall time.
- Cross-checks: every logicalEntryId returned by lookup is in the replay (as in the phase 1
  check); replay entries never returned by any lookup, by annexRef (reverse coverage);
  for list routes, sum of `returned` = `total`.
- Change against the previous run: items whose `body_sha256` changed, appeared or vanished.

## 6. Open points
- Access for routes not yet called is assumed from the scope description, not observed.
- Binding quota (RX-1) decides whether per-substance extraction takes about one day or longer.
- Whether to also fetch `lang=fr` (curated `means` in French): proposal en only, plus one
  fr snapshot of the corpus lists.
