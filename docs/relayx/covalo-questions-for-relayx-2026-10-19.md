# Covalo questions on the Relay X EU Regulatory Data API

Date: 2026-10-19
From: Kevin, Covalo (Data Product)
To: Relay X team

## Context

Covalo is integrating Relay X EU regulatory data into its ingredient data platform. We have:

- completed a full EU replay via `/changes?since=2000-01-01T00:00:00Z&territory=EU`, paged by `nextCursor` until `truncated: false`: 77 pages, 15,205 rows, 15,064 distinct `logicalEntryId` values, 15,058 current entries;
- cross-checked the replay against `/substances/lookup:batch` on a stratified sample of 210 identifiers: all 249 entries returned by lookup were present in the replay;
- compared the PDF documentation (RX-API-EU-01) with the served contract (`GET /api/regulatory/v1/openapi.json`, fetched 2026-10-19).

The questions below came up along the way. Questions 1 to 5 matter most for our pipeline design.

## How to answer

Please answer each question under its ID, using this format:

```
### Q01
Answer: <direct answer>
Source: <contract, internal knowledge, or to be checked>
Action: <none | documentation update planned | fix planned | needs discussion>
```

If a question rests on a misreading on our side, please say so and point to the relevant contract field or endpoint.

---

## A. Extraction and completeness

### Q01: /changes as full extract
**Observed:** Replaying `/changes` from 2000-01-01 for territory EU, paged by `nextCursor`, returned 15,205 rows; the row count matches the `total` reported on the first page.
**Question:** Is this the intended way to obtain the complete EU corpus visible to our key? Is anything withheld beyond what `withheldByScope` marks?

### Q02: Start of the knowledge log
**Observed:** Every entry in the replay is first recorded on or after `2026-08-01T00:30:42Z`.
**Question:** Was 2026-08-01 your initial load, so that `knownSince` reflects your ingestion date rather than the date of the law?

### Q03: Law history and asOf
**Observed:** The contract lists `asOf` on `/substances/lookup`, `/substances/lookup:batch` and `/substances/market-summary` only.
**Question:** Does the corpus include provisions repealed before 2026-08-01, or mainly law in force at build time? Is there a way to query law time on `/changes`, `/texts` or `/entries/{id}/history`?

### Q04: Full coverage of per-substance endpoints
**Observed:** `/substances/impurity-limits`, `/substances/screening` and `/substances/opinions` are keyed by substance. Our source list is about 16,000 substances.
**Question:** Is there a list or bulk route for these endpoints, or is per-substance lookup the intended way to get full coverage?

### Q05: Paging of entry history
**Observed:** `/entries/{id}/history` carries a `truncated` flag but no paging parameters.
**Question:** When is `truncated` set, and how do we retrieve the remaining versions?

## B. Data observations

### Q06: Feed ordering
**Observed:** Four EU entries (Annex III 24, 70, 75 and Annex VI 28) have a `SUPERSEDED` row at 2026-08-01 before their `FIRST_RECORDED` row at 2026-08-26.
`logicalEntryId` values:
- `36adaac2-b629-52b9-98b6-79e1c4b53fec`
- `12a04b9b-31b8-5762-a0ef-eea922a94c93`
- `81b9df22-e949-530c-b722-1c53893cfd4d`
- `9bc20320-a0fd-5730-9433-4459a57193a2`

**Question:** Which version is current for each of these, and is this ordering expected?

### Q07: Retracted-only entries
**Observed:** Six EU entries exist only as `RETRACTED` rows, without a `FIRST_RECORDED` event.
**Question:** Is this intended for rows retracted before first publication?

### Q08: Count of entries without identifiers
**Observed:** The `searchMeans` text says "20470 current constraints that carry no identifier at all". Our EU replay has 2,079 current entries without CAS, EC, INCI, CLP index or Colour Index.
**Question:** Which territories and which identifier fields does the 20,470 figure cover?

### Q09: Identifier catalogue
**Observed:** In our sample from the identifier catalogue (`identifiersonlyEU2.csv`, 14,207 rows), about a third of rows, and about two thirds of EC-only rows, return `KNOWN_WITHOUT_DATA` on EU lookup.
**Question:** What defines membership of the catalogue, how is it kept current, and is `KNOWN_WITHOUT_DATA` the expected result for these rows?

### Q10: Cosmetics relevance of EU layers
**Observed:** 1,834 of the 2,079 EU entries without identifiers come from the CITES wildlife-trade annexes.
**Question:** Is there a field or filter that marks which EU layers are relevant to cosmetics, or is scoping left to the consumer?

## C. Zones

### Q11: unavailableZones
**Observed:** `subscription.unavailableZones` is served in responses but is not in the contract schema.
**Question:** How does it differ from `missingZones`, and will it be added to the contract?

### Q12: Member-state territory codes
**Observed:** With a EUROPE subscription, `FRANCE` appears as a separate zone in `missingZones`.
**Question:** Do member-state codes (FR, DE, ...) return national provisions distinct from `EU`, or the EU entries again?

## D. Quota and limits

### Q13: Applicable rate limit
**Observed:** With our key: `RateLimit-Limit: 60`, 1 unit per `/changes` page, `RateLimit-Reset` as a Unix timestamp. The `RateLimit-Policy: 15000;w=900` header appears on the keyless routes. The PDF states 60 requests per minute per key; the contract describes the quota per subscription per minute.
**Question:** Can you confirm which limit applies to our key, and whether it is counted per key or per subscription?

### Q14: lookup:batch limits and unit accounting
**Observed:** `lookup:batch` rejects requests where items x `limit` exceeds 2,500 (`batch_result_too_large`); this is not in the contract. `RateLimit-Remaining` on batch responses appears to lag the actual charge: we saw a mid-batch truncation after the previous response showed 22 units left.
**Question:** Could the 2,500 cap be documented? How should we count units for batch calls?

## E. Documentation and use

### Q15: Alignment of PDF and contract
**Observed:** Main differences between the PDF and the served contract: cursor paging on `/changes`, the row content of `/changes` and `/history`, the quota, `name` matching (substring in the PDF, whole-term in the contract), and the base URL.
**Question:** Can the PDF be aligned with the served contract? We can share our full list of differences.
