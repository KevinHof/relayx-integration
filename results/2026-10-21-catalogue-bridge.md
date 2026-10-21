# 2026-10-21 Relay X catalogue as INCI to CAS bridge (PROVISIONAL)

Local only, read-only as relayx_app, TEMP objects only, no API calls.
`python -m relayx.provisional_report sql/provisional/catalogue_bridge.sql --setup sql/provisional/f1_matching_assessment.sql`
Rules are in the SQL header. Population: the 1,791 distinct Covalo INCI found in the
catalogue (step 1). Bridge: CAS and EC of the catalogue rows that carry the INCI, matched
against identifiers of current replay entries (printed and enriched, as in step 1).

## The 1,791, by class (exclusive)
| Class | Distinct INCI | Product links | With catalogue CAS or EC |
|---|---|---|---|
| Reaches a current entry by name (step 1) | 970 | 30,568 | 931 |
| Only through catalogue CAS or EC | 8 | 258 | 8 |
| None | 813 | 25,383 | 813 |

Of the 970 found by name, the bridge would also reach an entry for 927.

"Only through CAS or EC" (8 INCI), by annex or list of the reached entries (an INCI can
reach several): Annex III 8, CLP Annex VI Table 3 2, Annex II 1, Annex V 1, Article 15(2) 1,
REACH Annex XVII 1, REACH Candidate List 1, Toxic category 2 1. All 8 reach entries through
printed identifiers, via both CAS and EC.

Quality of these 8 bridges: every one comes from a catalogue row that carries 14 to 66 INCI
names; the row hands all its CAS and EC to each of its INCI. Two are evidently false:
CARBOMER (row with 26 INCI of amines and borates; reaches 32 entries, including Annex II,
through borate and amine CAS and EC 215-540-4) and OLEAMIDE DEA (row with 14 amide INCI). The
other six are lemon and orange INCI reaching Annex III through lemon or orange oil CAS
(8008-56-8, 84929-31-7, 8008-57-9); plausible, not validated. The gain below is therefore an
upper bound.

Catalogue rows with several INCI names: 1,125 of the 4,247 rows that carry INCI (up to 66
per row); 549 of the 1,237 rows behind the 1,791.

"None" (813 INCI), by catalogue regulatory layer: all 813 sit only on rows of layer "ECHA"
(the catalogue's largest layer, 5,564 rows), and all carry CAS or EC; none of those
identifiers is on a current EU entry.

## Share of all Covalo INCI
| Unit | Total | By name | Added by the bridge | By name or bridge |
|---|---|---|---|---|
| Distinct INCI | 13,912 | 973 (7.0 %) | 8 | 981 (7.1 %) |
| Products with INCI | 53,062 | 19,140 (36.1 %) | 187 | 19,327 (36.4 %) |

Of the 187 products added, 152 reach no current entry through their own CAS, EC or name
either. By bridged INCI: CARBOMER 153, OLEAMIDE DEA 6 (both false bridges, 159 products),
CITRUS AURANTIUM DULCIS OIL 16, CITRUS LIMON PEEL POWDER 9, CITRUS MEDICA LIMONUM FRUIT
EXTRACT 3 (plausible, 28 products). Without the two false bridges the product gain is 28
(36.1 % to 36.1 %).

## CosIng comparison
Not measured: the CosIng bridge (F3 Q3 and Q4) has not been run; F3 is at the Q1 profile and
waits for review. Skipped.

## Reading
The catalogue adds almost nothing as a bridge: the Covalo INCI it knows either already reach
an entry by name (970) or belong to ECHA-layer rows without EU entries (813). The 8 additions
come from bundled multi-INCI rows and include false bridges.

## Open points
- Treat multi-INCI catalogue rows as unusable for bridging, or bridge only from rows with one
  INCI (would remove all 8 here).
- Compare with the CosIng bridge once F3 Q3 and Q4 have run.
