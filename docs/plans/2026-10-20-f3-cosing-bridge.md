# Plan F3: CosIng as reference for INCI quality and the INCI to CAS bridge

Status: Q1 profiled 2026-10-21 (results/2026-10-21-f3-cosing-profile.md); Q2 to Q6 wait
for Kevin's review of the profile.
Fast-track F, after F1b; feeds F4 (mismatch classification after the F2 lookup).

## Purpose
Use CosIng as an external reference to (1) measure the quality of Covalo's INCI values,
(2) bridge Covalo INCI to CAS and EC where Covalo has none or a conflicting one, and
(3) measure how much that bridge adds to the step 1 replay match, in particular for
Cosmetics Annex II and Article 15, which print no INCI.

## Data source
- Source: CosIng Ingredients-Fragrance Inventory export, Wayback Machine capture. An older
  snapshot obtained through the Internet Archive, not the current CosIng.
- Capture URL: PENDING (Kevin will provide).
- Capture timestamp (capture date): PENDING (Kevin will provide).
- Table: kevin.cosing_ingredients, loaded by Kevin through DBeaver from a CSV; 28,712 rows,
  readable by relayx_app (checked 2026-10-21). Columns: cosing_ref_no (integer), inci_name,
  inn_name, ph_eur_name, cas_no, ec_no, chem_iupac_name, restriction, function, update_date
  (all text).
- Source file: data/cosing/cosing_clean.csv (data/reference/cosing/ is empty), 5,859,404
  bytes, SHA-256 6cb1a58cc94d640e7cf2354c4a4b607d177362198587c5f8b39c12db3c6441d4. UTF-8,
  comma-delimited, no lines before the header, no export date stated in the file. Whether
  it was cleaned after capture: not recalled (Kevin, 2026-10-21); Kevin considers it
  accurate.
- Reconciliation (2026-10-21, `python -m relayx.cosing_reconcile`): 28,712 rows in file and
  table, columns map one to one, same reference numbers, 0 differing values in any column.
- Snapshot date: the capture date (PENDING); lower bound from the latest `update_date` in
  the file: 2020-12-15.

## Query parameter
The bridge queries take the CosIng table name as a parameter (default
kevin.cosing_ingredients), so a current export can replace the snapshot later without
rewriting them.

## Questions
- Q1 Quality of CosIng as a reference: rows, distinct INCI, share of rows with CAS and with
  EC, multi-value and check-digit-failing CAS and EC, duplicate INCI, update dates.
- Q2 Covalo INCI quality: share of Covalo's distinct INCI, and of products, that match a
  CosIng INCI (a) exactly, (b) after normalisation, (c) after splitting multi-INCI strings,
  (d) not at all. Categories of non-matches with examples (spelling, trade names, mixtures,
  other).
- Q3 Bridge: for matched Covalo INCI, whether CosIng has CAS or EC; agreement with Covalo's
  own CAS on the same products (agree, conflict, gain where Covalo has none, neither).
- Q4 Coverage effect: rerun the step 1 replay match with CosIng-derived CAS and EC added.
  Report the gain in products and in distinct INCI found, per annex or list and per scope
  class, with Cosmetics Annex II and Article 15 shown separately, since they print no INCI.
- Q5 Referee flag: mark every Covalo INCI "found / not found in CosIng snapshot of
  <capture date>" (never "valid / invalid INCI"), for use in F4 (mismatch classification
  after the F2 lookup).
- Q6 Relay X side: do the INCI printed in Relay X entries and in its catalogue match CosIng
  INCI? List non-matches.

## Boundary
Comparing CosIng's annex references with Relay X annex membership is not part of F3; it
belongs to the legal accuracy track.

## Caveats to state in the results
- CosIng is a non-binding information database.
- The current legal INCI list is the Glossary of common ingredient names, Commission
  Implementing Decision (EU) 2025/1175, which carries no CAS.
- CosIng CAS values can be multiple or refer to related forms.
- The data is a Wayback Machine snapshot, not the current CosIng: an INCI absent from the
  snapshot may have been added to CosIng or the Glossary after the capture date.
- The Q5 referee flag is worded "found / not found in CosIng snapshot of <capture date>",
  never "valid / invalid INCI".
- Q6 non-matches may reflect Relay X entries newer than the snapshot.

## Outputs
- results/<date>-f3-cosing-bridge.md
- sql/provisional/f3_cosing_bridge.sql
All figures labelled PROVISIONAL. Read-only SQL as relayx_app, TEMP objects only.

## Gates
1. Profile first (Q1) and stop for review: the normalisation rules for Q2 depend on what the
   data looks like.
2. Q2 to Q6 after Kevin's review of the profile.
