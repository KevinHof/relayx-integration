# Plan F3: CosIng as reference for INCI quality and the INCI to CAS bridge

Status: SCHEDULED (2026-10-20). Waiting for Kevin to load CosIng into covalo-local-complete.
Fast-track F, after F1b; feeds F4 (mismatch classification after the F2 lookup).

## Purpose
Use CosIng as an external reference to (1) measure the quality of Covalo's INCI values,
(2) bridge Covalo INCI to CAS and EC where Covalo has none or a conflicting one, and
(3) measure how much that bridge adds to the step 1 replay match, in particular for
Cosmetics Annex II and Article 15, which print no INCI.

## Data source
A CosIng export loaded by Kevin. To be recorded at profiling: schema, table, export file
name, download date and SHA-256 of the export file.

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
- Q5 Referee flag: mark every Covalo INCI as CosIng-valid or not, for use in F4 (mismatch
  classification after the F2 lookup).
- Q6 Relay X side: do the INCI printed in Relay X entries and in its catalogue match CosIng
  INCI? List non-matches.

## Boundary
Comparing CosIng's annex references with Relay X annex membership is not part of F3; it
belongs to the legal accuracy track.

## Caveats to state in the results
- CosIng is a non-binding information database.
- The legal INCI list is the Glossary (Implementing Decision 2022/677), which carries no CAS.
- CosIng CAS values can be multiple or refer to related forms.

## Outputs
- results/<date>-f3-cosing-bridge.md
- sql/provisional/f3_cosing_bridge.sql
All figures labelled PROVISIONAL. Read-only SQL as relayx_app, TEMP objects only.

## Gates
1. Profile first (Q1) and stop for review: the normalisation rules for Q2 depend on what the
   data looks like.
2. Q2 to Q6 after Kevin's review of the profile.
