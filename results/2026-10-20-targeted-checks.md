# 2026-10-20 Targeted checks: opinions, impurity limits, IFRA screening

`python -m relayx.targeted_checks run opinions|impurity|ifra`, territory EU, seed 20261020.
All calls 200, loaded into `relayx_raw.api_response` (load checks ok). Units: 145 requested
(approved about 140): one lookup batch was truncated by the quota and its 5 unevaluated items
were re-sent automatically.

| Check | Run id | Calls | Units |
|---|---|---|---|
| Impurity limits | 20261020T080517Z_check_impurity_eu | 20 | 20 |
| IFRA screening | 20261020T080520Z_check_ifra_eu | 20 | 20 |
| Opinions | 20261020T080523Z_check_opinions_eu | 53 | 105 |

## a. Opinions: lookup context vs /substances/opinions (50 substances by CAS)
Sample deviation: no entry in Annexes III to VI mentions the SCCS; only Article 15 entries do
(standard derogation text). The sample was therefore split: 25 from Article 15 (criterion
as given) and 25 from Annexes III, V and VI (where SCCS opinions are expected). One substance
per distinct single CAS, current entries only.

| Stratum | Queried | Lookup HAS_DATA | With opinions | Distinct opinions | Sets equal |
|---|---|---|---|---|---|
| Article 15 | 25 | 25 | 2 | 3 (SCCS 2, WHO_IPCS 1) | 25 of 25 |
| Annexes III, V, VI | 25 | 25 | 10 | 22 (SCCS 9, WHO_IPCS 7, CIR 6) | 25 of 25 |

- Lookup's `substanceContext.scientificOpinions` and the endpoint return the same opinions
  (compared on body and reference) for all 50 substances; with the pilot, 52 of 52.
- Lookup repeats rows: one CIR opinion appears twice and one SCCS opinion (SCCS/1631/21)
  three times in the context of the same substance; the endpoint has no duplicates.
- Bodies seen: SCCS, WHO_IPCS, CIR. No PUBMED or OTHER.
- Consequence (Kevin's rule): opinions come from lookup; the separate full opinions run is
  dropped. Deduplicate on (body, reference) when reading lookup.

## b. Impurity limits (20 known contaminants by CAS)
All 20 `substanceKnown: true`; 10 return limits, 10 return none.

| With limits | Markets | Regimes |
|---|---|---|
| lead, cadmium, mercury, antimony (2 each) | EU, DE | PROHIBITION_TRACE_UNAVOIDABLE, GUIDANCE_LIMIT |
| arsenic (4) | EU, DE | also COLORANT_PURITY_LIMIT |
| nickel (1) | EU | PROHIBITION_TRACE_UNAVOIDABLE |
| formaldehyde (1) | EU | LABELING_TRIGGER |
| acrylamide (2) | EU | MANDATORY_LIMIT |
| asbestos (1) | EU | NON_DETECTABLE |
| benzo[a]pyrene (2) | EU | COLORANT_PURITY_LIMIT |

No limit: chromium(VI), 1,4-dioxane, methanol, NDMA, NDEA, NDELA, benzene, ethylene oxide,
diethylene glycol, dichloromethane. DE rows (German guidance values) are served under the
EUROPE subscription. The dataset is small and contaminant-specific: the pilot found 0 of 100
catalogue substances, this list 10 of 20.

## c. Screening: IFRA (20 fragrance allergens from /allergens, by CAS)
`IFRA_STANDARDS` appears for 12 of 20 allergens. Listing content: name "IFRA Standards,
regulated fragrance ingredients", `listedRef` (e.g. "Amendment 29"), link to ifrafragrance.org,
`values: null`, `redistributionRight: RESTRICTED`: membership only, no limits, as the
contract states. Other codes in the same calls: ECHA_DOSSIER_EVALUATION 9, ECHA_CLH_PROCESS 7,
ECHA_SUBSTANCE_EVALUATION 3, IARC_MONOGRAPHS 2, ECHA_EU_POSITIVE_LIST 1. 4 allergens have no
listing (3 botanical extracts, 1 synthetic). `PFAS_EPA_TSCA` not seen (no PFAS in the sample).
The absence of IFRA in the 100-substance pilot was a sample effect.

## Open points
- Impurity limits: a targeted list run (known contaminants and colorant impurities) instead
  of a full sweep; wait for RX-14.
- RX-21 narrowed: IFRA_STANDARDS is served; the question remains for the undocumented
  ECHA and IARC codes and the full code list.
