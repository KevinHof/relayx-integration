# Relay X reference documents

Previous copies are kept; a newer file never replaces an older one.

| File | SHA-256 | Source |
|---|---|---|
| Relay-X_Regulatory_Data_API_Europe.pdf | 864c5fe2e2e85a43980c65b494d8c83f0f3bbe87d48c0979d917ad7ec555d6ce | Hand-written guide, first version |
| Relay-X_Regulatory_Data_API_Europe_v1.1.pdf | 60a8e003674d19073efdfe71ed2179ff63478ed7cfa5ca1d0ab71d7ad2db707a | Guide v1.1, received 2026-10-21 from Pierre (Slack) |
| openapi-2026-10-19.json | 773dbe63bd5b08653a2498a7826a10a109f078a2c388d1b9568196e491d4dada | Served contract, GET /api/regulatory/v1/openapi.json, 2026-10-19 |
| openapi-2026-10-22.json | 964c94cea5c308398e65a6af36b6135529e919c3d43d356f0e39205727efee39 | Served contract, same route, fetched 2026-10-22 07:31:55 UTC, unauthenticated, HTTP 200, 219,455 bytes, ETag W/"3593f-30ZUfNyrGCq1cEE/uG9oVbhOzUY" |

The served contract is binding; the PDF guides are hand-written and can lag behind it.
Both contract copies state `info.version` 1.0.0, so the version number does not identify a
contract change; compare files by hash.
