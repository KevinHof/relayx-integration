# Relay X contract notes (openapi snapshot 2026-10-19)

Source: `docs/relayx/openapi-2026-10-19.json`, fetched 2026-10-19 14:02 UTC
(OpenAPI 3.1.0, info.version 1.0.0, 153,781 bytes,
sha256 773dbe63bd5b08653a2498a7826a10a109f078a2c388d1b9568196e491d4dada).
Server: `https://api.relay-x.com/api/regulatory/v1`.

Everything below is what the contract STATES. Nothing here has been verified with a data
call yet (only /health and /openapi.json were called).

## 1. Route inventory (complete list, 12 operations)

| Route | Key | Paging | Purpose |
|---|---|---|---|
| GET /health | no | - | status only |
| GET /openapi.json | no | - | contract (`lang` en/fr) |
| GET /substances/lookup | yes | limit/offset | constraints for one substance; params cas, ec, inci, name, clpIndex, colourIndex, synonym, territory, asOf, sections, lang, view, context |
| POST /substances/lookup:batch | yes | per item `limit` | same as lookup, max 50 items (25 with view=full), 1 unit per item |
| GET /substances/market-summary | yes | - | status per market, no text |
| GET /substances/impurity-limits | yes | - | impurity thresholds |
| GET /substances/screening | yes | - | screening list membership (PFAS, IFRA) |
| GET /substances/opinions | yes | - | scientific opinion references |
| GET /allergens | yes | limit/offset | declarable allergens per market |
| GET /changes | yes | cursor (limit) | knowledge feed since an instant |
| GET /entries/{logicalEntryId}/history | yes | none (`truncated` flag) | all versions of one entry |
| GET /texts | yes | limit/offset | legal text catalogue with amendment chain |
| GET /coverage | yes | limit/offset | coverage scopes and `absenceMeans` |

No route lists entries, exports the corpus, or returns the current state of an entry by id
other than `/entries/{logicalEntryId}/history`. There is no bulk or export route.
A remote MCP endpoint (`/mcp`, `x-relayx-mcp`) exposes 10 tools over the same data and draws
on the same quota; its pagination clamps offsets (`offsetClamped`), unlike HTTP.

## 2. GET /changes (feed)

- `since` (required, date-time UTC `YYYY-MM-DDTHH:MM:SSZ`). Time axis is KNOWLEDGE
  (`recordedFrom`), not law.
- `cursor` (optional, opaque): "the one the previous response returned in `nextCursor`";
  "When supplied, it replaces `since` for filtering."
- `territory`, `legislator` filters. Unknown code returns 400 (`unknown_territory`,
  `unknown_legislator`) since 2026-08-11; a valid code outside the contract returns 200 with
  zero rows and `subscription.missingZones`.
- `limit` 1..200, default 50, silently clamped. `offset` exists but the route description says
  page with `cursor`, "never with `offset`".
- Ordered oldest-first; rows written mid-run are appended.
- Response `ReponseNouveautes` (required fields): `since`, `nextSince`, `nextCursor`,
  `cursorGuidance`, `total`, `returned`, `offset`, `truncated`, `subscription`,
  `withheldByScope`, `changeDetection`, `changes`.
- `nextSince`: timestamp of the last row, INCLUSIVE; "it is NOT what you page with";
  deduplicate on (`logicalEntryId`, `knownSince`).
- `nextCursor`: pass back as `cursor` after every page while `truncated` is true; `null` on an
  empty page (keep the previous cursor).
- Each row in `changes[]` is a full `Contrainte` plus `changeKind`
  (`FIRST_RECORDED` | `SUPERSEDED` | `RETRACTED`) and `changedFields`
  (array of `{field, before, after}` or null). `FIRST_RECORDED` means new to Relay X, not new
  in law. Rows carry `knownSince` but no `knowledge` block (that is history-only).
- 400 `invalid_cursor` if the token is not one they issued.
- Quota cost per page is not stated. Only batch items (1 unit each) and MCP requests
  (1 unit each) are stated explicitly.

## 3. GET /entries/{logicalEntryId}/history

- Path param `logicalEntryId` (uuid, copied verbatim). 400 `malformed_entry_id`.
- Response `ReponseHistorique` (required): `found` (const true), `logicalEntryId`,
  `versionCount`, `truncated`, `subscription`, `withheldByScope`, `changeDetection`,
  `versions`.
- Each `versions[]` item is a full `Contrainte` plus `changedFields` and `knowledge`
  (`FenetreDeConnaissance`: `knownFrom`, `knownUntil` (null = current knowledge),
  `isCurrent`, `retracted {at, reason}`, `supersededByVersionId`, `supersessionNature`
  (`RULE_CHANGED` | `WORDING_RESTATED` | `UNDETERMINED`), `supersessionMeans`, `coveredBy`).
- No paging parameters, but a `truncated` flag exists. What truncates it is not stated.
- 404 `unknown_entry` = "no version visible under your subscription", explicitly not
  "does not exist". Licence-withheld entries return 200 with `withheldByScope`.
- `changedFields` excludes the knowledge window, the derived `rules` block and the
  `nomenclature` enrichment.

## 4. Other contract points relevant to design

- `Contrainte` required: `logicalEntryId`, `territory`, `identifiers`, `literal`, `rules`,
  `productScopeStructured`, `history`, `validity`, `provenance`. Also `entryScope`
  (single vs group), `linkedSubstances` (capped 25 substances x 40 values,
  `linkedSubstancesTruncated`), `identifiers.casList/ecList/inciList` (split literals),
  `nomenclature` (enriched INCI: `inciEu`, `inciIecic`, `inciUs`, synonyms), `knownSince`.
- `identifiers` = what the act prints; `linkedSubstances` and `nomenclature` = Relay X
  enrichment. Relevant for matching and for citing.
- Lookup `view`: default `full` on GET; batch default `standard`. `standard` drops every
  `*Means` key and `literal.fullText`; `summary` is a different flat shape
  (`ContrainteResumee`), where `identifiers.inci` silently falls back to the enriched INCI.
- Lookup response: `searchMeans`, `scanCapped` (`total` is then a lower bound),
  `ingredientStatus.status` (`HAS_DATA`, `KNOWN_WITHOUT_DATA`, `UNKNOWN_IDENTIFIER`,
  `NOT_SEARCHED`), `upcoming` block (constraints not yet in force), `otherNameMatches`,
  `identifierResolution`, `identifierCaveats`.
- Absence states: `subscription` (`grantedZones`, `missingZones`, `thinlyCoveredZones`),
  `withheldByScope` (`count`, `reason`, sometimes `territories`), 403 `forbidden` with
  `grantedScopes`, 404 on history, `INSUFFICIENT_DATA` in market-summary, `absenceMeans` in
  coverage.
- Scopes: `read:public` (PUBLIC_DOMAIN, OFFICIAL_ACT texts); `read:licensed` adds LICENSED and
  RESTRICTED, contractual only. `UNQUALIFIED` texts are served to no one.
- Errors: 500 carries a class code (`P2024`, `P1001`) to decide retry.
- Free-text notes (`freeTextNotes`, `verificationNote`, `errataNote`) are in French.

## 5. Differences: PDF vs contract

PDF: `docs/relayx/Relay-X_Regulatory_Data_API_Europe.pdf`, RX-API-EU-01 v1.0, August 2026,
21 pages (gitignored, not committed). The PDF itself says it is hand-written, can lag behind
the service, and that openapi.json binds. Contract wins in every row below.

### 5a. Behaviour that changes the design

| # | Topic | PDF | Contract (2026-10-19) |
|---|---|---|---|
| 1 | /changes paging | "Always advance the cursor using the returned nextSince" (p.16, p.20). Params: since, legislator, territory, limit, offset. No `cursor` | page with opaque `nextCursor` passed back as `cursor`; `nextSince` is inclusive and "NOT what you page with"; dedupe on (`logicalEntryId`, `knownSince`) |
| 2 | /changes rows | example shows only `logicalEntryId`, `changeKind`, `territory` (marked "trimmed for length") | full `Contrainte` + `changeKind` + `changedFields` |
| 3 | /changes response | `since`, `nextSince`, `total`, `changes` | also `nextCursor`, `cursorGuidance`, `returned`, `offset`, `truncated`, `subscription`, `withheldByScope`, `changeDetection` |
| 4 | /history versions | example shows only `knowledge` + `changedFields` (trimmed) | each version is a full `Contrainte` + `changedFields` + `knowledge`; `knowledge` adds `retracted`, `supersededByVersionId`, `supersessionNature`, `coveredBy`; response adds `truncated` |
| 5 | Quota | "Per key and per minute", example `RateLimit-Limit: 60`, `RateLimit-Reset: 42` | per SUBSCRIPTION per minute, shared by up to 10 keys; `RateLimit-Reset` is a "Unix timestamp". Observed on 2026-10-19: `15000`, policy `15000;w=900`, Reset `900` then `793`. Three sources, three answers (Q7) |
| 6 | Name search | `inci` and `name` "are substring searches" (p.10) | `name` is a WHOLE-TERM match on Unicode word boundaries, "NOT as a substring"; `inci` goes via the index, then literal names in OR |
| 7 | Scopes | EU needs only `read:public`; everything on the EU is served under it | `read:public` and contractual `read:licensed`; `UNQUALIFIED` texts served to no one |
| 8 | Base URL | `https://app.relay-x.com/api/regulatory/v1` | `https://api.relay-x.com/api/regulatory/v1` (our .env, working) |

### 5b. Smaller differences

| # | Topic | PDF | Contract |
|---|---|---|---|
| 9 | Lookup identifiers | cas, ec, inci, name | adds `clpIndex`, `colourIndex`, `synonym` (also on market-summary) |
| 10 | Batch method | heading says `GET /substances/lookup:batch`, example is POST | POST only |
| 11 | Batch body | `items`, `view`; "sections and lang apply to every entry" | `items`, `territory`, `asOf`, `sections`, `limit`, `view`; no `lang` |
| 12 | Territory codes | EU and the 27 member-state codes | `EU`, `GB`, `US`, `US-CA`, `CN`, ... plus 28 commercial zones |
| 13 | Opinions attachment | "by CAS only, never by name" | by substance, resolved from CAS, EC or INCI |
| 14 | Allergens default territory | "your primary market" | `EU` |
| 15 | Payload size | full ~130 KB per substance; standard ~41 % | "147 KB per substance"; standard removes ~52 % |
| 16 | Unknown territory | 400 (lookup) | 400 on all routes since 2026-08-11 (was 200 empty on /changes, /texts, /coverage) |
| 17 | Errors | 400/401/403/404/429 | adds 500 with class code (`P2024`, `P1001`); 400 `invalid_cursor`, `malformed_entry_id`, `batch_view_too_heavy`, `batch_result_too_large` |
| 18 | Rate headers | `RateLimit-*`, `Retry-After` | also `X-RateLimit-*` aliases and `X-Key-Prefix` |
| 19 | Lookup response | `upcoming`, `searchMeans`, `reachedViaGroupEntry` | adds `scanCapped`, `ingredientStatus`, `otherNameMatches`, `baseForm`, `identifierResolution`, `identifierCaveats` |
| 20 | MCP | 10 tools, same key | same, plus: Bearer only, each request (handshake included) costs 1 unit, offsets clamp |

### 5c. PDF content not in the contract (useful for the extract design)

- Corpus figures (EU, measured 2026-08-11/19): 8,728 EU-covered substances; 8,647 with at least
  one EU constraint; 271 with no CAS, EC or INCI (collective entries); 14,183 EU entries.
  Our open-questions.md cites ~20,470 current constraints with no identifier; that figure is
  not in this PDF and its source should be checked.
- Identifier provenance: CAS 74.4 % printed in the text / 25.6 % completed from an inventory;
  EC 98.1 % / 1.9 %; INCI 16.0 % / 84.0 %.
- `asOf` does not restore superseded wordings: one consolidated version per act is held
  (p.4). Law-time replay is filtering, not true versioning.
- /changes example: `since=2026-07-01`, no territory filter, `total: 35211`.
- Six EU layers (1223/2009 annexes, CLP Annex VI, REACH XVII/XIV/SVHC, POPs, Article 15 as
  its own derived layer).

Observation, not explained: `RateLimit-Remaining` went 14999 then 14994 across our two calls
0.3 s apart. Either the free routes cost units, or another key on the same subscription was
active. Unvalidated.
