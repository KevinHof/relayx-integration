# Cosmetics relevance of Relay X EU content

Status: PROPOSED (2026-10-20). Kevin decides the scope after review.
Basis: results/2026-10-20-atlas-datapack.md, section 5 (entry counts per annex in section 2).

Classes: core cosmetics; indirectly relevant; marginal; not relevant.

| Annex or list | Proposed class | Reason |
|---|---|---|
| Cosmetics Annex II | Core cosmetics | Prohibited substances list of Regulation 1223/2009 |
| Cosmetics Annex III | Core cosmetics | Restricted substances with limits and conditions; source of the allergen list |
| Cosmetics Annex IV, V, VI | Core cosmetics | Positive lists for colorants, preservatives, UV filters |
| Article 15(1), 15(2) | Core cosmetics | CMR prohibitions of the Cosmetics Regulation, derived by Relay X from CLP classifications |
| Allergens (/allergens) | Core cosmetics | Labelling duty under Article 19(1)(g), derived from Annex III |
| CLP Annex VI Table 3 | Indirectly relevant | Not a cosmetic rule; its CMR classifications trigger Article 15 |
| REACH Annex XVII | Indirectly relevant | Restrictions; some entries apply to cosmetics (e.g. D4/D5 in wash-off, microplastics), most do not |
| REACH Annex XIV | Indirectly relevant | Authorisation affects use and supply of the substance in the EU, not cosmetic products directly |
| REACH Candidate List (SVHC) | Indirectly relevant | No use limit; supply-chain information duties and a signal of future restriction |
| REACH CMR 1A, 1B, Mutagens, Toxic 1, Toxic 2 | Not relevant for cosmetic products (proposed 2026-10-20, kept in raw) | Annex XVII entries 28 to 30 exclude cosmetic products; see finding 1 below |
| POPs Regulation and Annex I, part A | Indirectly relevant | Prohibitions apply to all products, cosmetics included, for few substances |
| CITES 32026R1383 (11 annexes) | Marginal | Trade permit regime for species; relevant only for sourcing botanical or animal ingredients |
| CITES 32025R0006 import suspensions | Marginal | Same as above, import-specific; scope PARTIAL |
| REACH Exemptions | Not relevant | Registration carve-outs, not use limits; produces noise in matching (e.g. water) |
| REACH Annex V | Not relevant | Exemptions from registration; same reason |
| 86 texts without entries | Follow their amended act | Provenance for amendment chains only; the 23 mislinked Cosmetics amendments belong with core |

## Findings
1. Checked 2026-10-20. Entries 28 to 30, paragraph 2(b): paragraph 1 does not apply to
   cosmetic products as defined by Directive 76/768/EEC (source: ECHA consolidated conditions
   of restriction for entries 28 to 30; to be verified against consolidated text CELEX
   02006R1907). In addition, Article 67(2) REACH: Annex XVII does not apply to the use of
   substances in cosmetic products with regard to restrictions addressing risks to human
   health within the scope of the cosmetics legislation. Proposed consequence: the REACH CMR
   appendix entries (CMR 1A, CMR 1B, Mutagens, Toxic 1, Toxic 2; 1,941 entries) move to 'not
   relevant for cosmetic products', kept in raw. REACH Annex XVII stays 'indirectly relevant'
   on the ground that environment-based restrictions (e.g. D4/D5 in wash-off, microplastics)
   apply to cosmetics; health-based ones do not (Article 67(2)).

   Redundancy check (PROVISIONAL, sql/provisional/cmr_appendix_redundancy.sql): the 1,941
   current CMR appendix entries print 1,235 distinct substances (1,223 by CAS, 12 by EC where
   the entry prints no CAS); 53 entries print neither CAS nor EC and are not counted. Matched
   on printed CAS (else EC) against current entries:

   | Coverage of the CMR appendix substances | Substances |
   |---|---|
   | Also in Article 15(1) or 15(2) | 1,225 |
   | In CLP Annex VI Table 3 only | 0 |
   | Neither | 10 |

   By appendix (a substance can sit in several): CMR 1A 326 / 1 neither, CMR 1B 845 / 6,
   Mutagens 430 / 1, Toxic 1 20 / 0, Toxic 2 274 / 4 (Article 15 / neither).

   The 10 "neither" substances (CAS, EC, name as printed, appendix):
   - 27741-01-3, 289-339-5, Hydrocarbures en C4; gaz de pétrole, CMR 1A
   - 25376-45-8, 246-910-3, Diaminotoluène, produit technique (mélange), CMR 1B
   - 612-83-9, 210-323-0, Sels de 3,3′-dichlorobenzidine, CMR 1B
   - 64969-34-2, 265-293-1, same entry, CMR 1B
   - 74332-73-3, 277-822-3, same entry, CMR 1B
   - 736665-18-6, 277-567-8, Résidus d'extrait alcalin d'huile de goudron (houille), CMR 1B
   - 7789-12-0, 234-190-3, "Dichlorure de sodium, dihydrate" as printed (the CAS is sodium
     dichromate dihydrate; name not verified), CMR 1B, Mutagens, Toxic 2
   - 106325-08-0, 406-850-2, (2RS,3RS)-3-(2-Chlorophényl)-2-(4-fluorophényl)-...oxirane, Toxic 2
   - 119738-06-6, 414-200-4, Propionate de (+/–) tétrahydrofurfuryle (R)-2-[4-(6-chloroquinoxaline-2-yloxy)...], Toxic 2
   - 42925-80-4, 205-017-9, Ester dipentylique de l'acide 1,2-benzène-dicarboxylique, Toxic 2

   Reading: almost every CMR appendix substance is already covered by a Cosmetics Article 15
   entry, so moving the appendices out of scope loses at most these 10 printed keys; they are
   not checked against other annexes or by name.
