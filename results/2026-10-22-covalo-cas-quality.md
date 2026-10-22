# 2026-10-22 Covalo CAS quality (PROVISIONAL)

Local only, read-only as relayx_app, TEMP objects only, no API calls.
`python -m relayx.provisional_report sql/provisional/covalo_cas_quality.sql --setup sql/provisional/f1_matching_assessment.sql --timeout 1800`
(sections a1 to a6). F2 figures from run 20261022T075923Z_covalo_lookup_eu only.

## Rules (F1, unchanged)
- Products: covalo.product not trashed, enabled, company not trashed. Raw CAS element = one string
  element of `product.identifiers -> 'cas'`.
- Parsing: en dash, em dash, U+2010, U+2011 and minus become "-", spaces around hyphens are removed;
  token = every `\d{2,7}-\d{2}-\d` not touching other digits. Leading zeros are kept as printed.
  Residual = what is left after removing tokens, `[n]` markers, separators (whitespace ; , / | & + . ( ) -)
  and the words and, or, oder, und, et. Classes: single (1 token, no residual), multi-value (2+
  tokens, no residual), residue (tokens plus residual), unparsed (no token). Check digit verified;
  failing tokens stay parsed values (not queried in F2).
- INCI = F1 value (trim, collapse whitespace, upper case).
- A4 comparison: INCI on both sides normalised by upper case, collapsed whitespace, trim, and
  apostrophe variants (’ ‘ ` ´ ʼ) replaced by '. A Covalo CAS-INCI pair (both on the same product)
  agrees for a source if its INCI equals any inciEu, inciUs, inciIecic, inci or inciList that the
  source serves for that CAS; conflict if the source serves INCI for the CAS but none equal; no
  reference otherwise. Sources, never merged:
  - replay: replay 20261019T143522Z_eu entries; CAS from F1 rx_id (printed and enriched); INCI
    from the same entry's five fields;
  - lookup: F2 CAS items; INCI from the returned constraints' five fields. Covers only CAS with
    returned constraints (HAS_DATA);
  - caveat: F2 INCI items whose identifierCaveats note reads "Your identifier designates, in our
    substance index, a substance with a single CAS number (X)." with no other CAS in the note;
    pair (X, queried INCI). No structured field carries the CAS; it is taken from this template only.
  - Group rule: replay entries with entryScope GROUP or GENERIC_CLASS and lookup constraints with
    reachedViaGroupEntry true (or those scopes) are excluded from agree and conflict and reported
    separately. There is no `nature` GROUP (nature is LITERAL_ENTRY or DERIVED_BY_LAW); entryScope
    is the group marker.
- A5 source: `covalo.product.company` to `covalo.company.name`, active products.

## A1 Completeness
| Group | Products | With CAS element | With parsable CAS | Parsable |
|---|---|---|---|---|
| All active | 116,938 | 33,929 | 33,427 | 28.6 % |
| INGREDIENTS | 112,649 | 33,929 | 33,427 | 29.7 % |
| FORMULATIONS / SERVICES | 3,924 / 365 | 0 | 0 | 0 % |
| PERSONALCARE | 105,801 | 30,186 | 29,837 | 28.2 % |
| FOOD | 6,745 | 2,959 | 2,834 | 42.0 % |
| HOMECARE | 4,074 | 784 | 756 | 18.6 % |
| LUBRICANTS / CERAMICS | 317 / 1 | 0 | 0 | 0 % |
| Ingredients in personal care | 101,535 | 30,186 | 29,837 | 29.4 % |
Elements and values: 46,747 raw elements, 8,505 distinct raw strings, 6,766 distinct parsed values.

## A2 Format
| Class | Raw elements | Distinct raw strings | Products |
|---|---|---|---|
| Single | 43,968 | 6,636 | 31,527 |
| Multi-value | 2,055 | 1,490 | 2,049 |
| Residue | 157 | 135 | 154 |
| Unparsed | 567 | 244 | 556 |

- Multi-value by separator (text right after the first number): "/" 931, "," 597, ";" 226, "&" 174,
  "(" 84, whitespace only 13, "-" 8, "oder" 8, "and" 4, "or" 2, "|" 2, "+" 2, other 4.
- Unparsed, 20 most frequent (products): MIXTURE 95, mixture 90, ISOMER MIXTURE 26, Proprietary 18,
  Odiferous 14, Mixture 11, 68647-73-41 9, 2236902 8, 9003-01-04 6, 112-02-07 5,
  "68647-73-41 / 85085-48-92" 5, 2230756 4, 61789-9-1 4, N/A 4, empty string 3, -- 3, – 3,
  2233340 3, 2236839 3, 26838-05-01 3. Digits-only strings and two-digit check groups are not
  CAS-shaped under the F1 pattern.
- Residue, most frequent: ":" 9, "CAS No:" 7, "(generic)" 7, full-width "＆" 7, "[für Australien
  (AICS) …]" 6, a mangled number "773218-5" 6.
- Check-digit failures: 278 raw elements, 227 distinct values, 275 products; 151 products have
  only failing values.
- Normalisation needed (raw elements / distinct strings / products): leading zero in a token
  317 / 219 / 317 (kept by F1, not normalised); leading or trailing whitespace 125 / 104 / 106;
  space next to a hyphen 88 / 65 / 67; non-standard hyphen character 62 / 44 / 41.

## A3 Internal consistency (CAS and INCI on the same product)
Pairs combine every CAS with every INCI of a product, so products listing several ingredients
pair each CAS with all of them.
- (a) Distinct INCI per CAS (4,156 CAS with an INCI on the same product): 1: 1,618; 2: 473;
  3 to 5: 755; 6 to 10: 520; 11 to 50: 653; more than 50: 137. Most: 7732-18-5 1,415 INCI on
  1,415 products (WATER 857, AQUA 422, GLYCERIN 354); 56-81-5 711; 107-88-0 555; 122-99-6 423;
  70445-33-9 307; 57-55-6 249; 532-32-1 236; 24634-61-5 219; 5343-92-0 217; 6920-22-5 217;
  504-63-2 207; 13463-67-7 204 (TITANIUM DIOXIDE 334, CI 77891 147, SYNTHETIC FLUORPHLOGOPITE 107);
  77-92-9 193; 1117-86-8 191; 8001-21-6 191; 11138-66-2 186; 67762-27-0 181; 9067-32-7 169;
  73398-61-5 167; 8002-43-5 161. Full list with examples: section a3b.
- (b) Distinct CAS per INCI: 1: 2,502; 2: 817; 3 to 5: 1,168; 6 to 10: 751; 11 to 50: 656;
  more than 50: 93. Most: WATER 853 CAS (7732-18-5 857, 56-81-5 236, 107-88-0 165); AQUA 580;
  GLYCERIN 544; BUTYLENE GLYCOL 431; PHENOXYETHANOL 316; CITRIC ACID 239; ETHYLHEXYLGLYCERIN 228;
  TOCOPHEROL 227 (59-02-9 69, 1406-66-2 52, 8001-21-6 44); PROPYLENE GLYCOL 203; SODIUM BENZOATE
  189. Full list: section a3d.
- (c) Products by number of parsed CAS: 1: 26,340; 2: 3,663; 3: 1,616; 4 to 5: 1,130; 6 to 10:
  561; more than 10: 117. Of the 7,087 with two or more, 1,818 get them from one multi-value
  element and 5,269 from several elements.

## A4 Agreement with Relay X (reference, not legal reference; F3 repeats this with CosIng)
39,534 distinct Covalo CAS-INCI pairs (101,002 product links, 4,156 CAS, 16,566 products);
24,628 distinct pairs (62.3 %) have a reference in at least one source.

| Source | Agree | Conflict | No reference |
|---|---|---|---|
| replay, pair links | 4,685 | 23,869 | 72,448 |
| lookup, pair links | 3,974 | 20,579 | 76,449 |
| caveat, pair links | 13,809 | 44,931 | 42,262 |
| replay, products | 3,515 (21.2 %) | 1,688 (10.2 %) | 11,363 (68.6 %) |
| lookup, products | 3,154 (19.0 %) | 1,489 (9.0 %) | 11,923 (72.0 %) |
| caveat, products | 9,158 (55.3 %) | 1,662 (10.0 %) | 5,746 (34.7 %) |
| replay, 1 CAS and 1 INCI products | 945 | 586 | 8,291 |
| lookup, 1 CAS and 1 INCI products | 882 | 384 | 8,556 |
| caveat, 1 CAS and 1 INCI products | 4,562 | 970 | 4,290 |
Product level: agree if any pair agrees, conflict if none agrees and one conflicts. The lookup
route covers only CAS that returned constraints (HAS_DATA). The caveat reference consists only of
INCI that Covalo itself carries (F2 queried Covalo values).

- Group references, excluded above: pair links whose CAS has only a group reference: replay 3,240
  (710 with the INCI named by the group entry), lookup 7,096 (1,287).
- Caveat source: 3,239 of 13,912 INCI items carry a caveat with a CAS-shaped number; 3,164 match
  the single-CAS template, each with exactly one distinct CAS, and are used. Notes of other
  wording with CAS numbers (on 451 items, e.g. name-containment removals) are not used. Ten
  examples as served are in section a4h, e.g. NEOPENTYL GLYCOL DICAPRATE: "Your identifier
  designates, in our substance index, a substance with a single CAS number (27841-06-1). Entries
  that print 27841-06-1 without printing your identifier (typically chemical inventories) were
  included, marked `matchedBy: ["substanceIndex"]`. When a substance record carries several CAS
  numbers, no number is chosen for you." Others: CAMELLIA OLEIFERA SEED OIL 225233-97-6, METHYL
  GLUCETH-10 68239-42-9, CALOPHYLLUM TACAMAHACA SEED OIL 223748-12-7, VIOLA TRICOLOR EXTRACT
  84012-42-0, HEXYLDECANOIC ACID 25354-97-6, FOLIC ACID 59-30-3, OLETH-24 9004-98-2, HESPERIDIN
  METHYL CHALCONE 24292-52-2, FAGUS SYLVATICA BUD EXTRACT 85251-65-6 (same wording).
- 20 conflict examples (Covalo INCI, products, INCI the source serves for the CAS):
  replay and lookup alike: 7732-18-5 with AQUA 422, GLYCERIN 354, BUTYLENE GLYCOL 303,
  PHENOXYETHANOL 157, ETHYLHEXYLGLYCERIN 129 (served: WATER); 8001-21-6 with HELIANTHUS ANNUUS
  SEED OIL 215 (served: HELIANTHUS ANNUUS SPROUT EXTRACT); 122-99-6 with WATER 144 (served:
  PHENOXYETHANOL, 2-PHENOXYETHANOL); 24634-61-5 with POTASSIUM SORBATE 121 (served: SORBIC ACID,
  HEXA-2,4-DIENOIC ACID AND ITS SALTS); 13463-67-7 with SYNTHETIC FLUORPHLOGOPITE 107 (served:
  TITANIUM DIOXIDE, CI 77891 in the replay). Lookup only: 13463-67-7 with CI 77891 147 (lookup
  serves TITANIUM DIOXIDE only). Replay only: 70445-33-9 with WATER 102 (served:
  ETHYLHEXYLGLYCERIN). The conflicts mix several-ingredient products, synonyms the rule does not
  equate (AQUA, CI 77891) and salt or plant-part differences. Full list: section a4f.

## A5 By source (20 companies with the most active products)
| Company | Products | Parsable CAS | Unparsed (of with element) | Check fail (of parsable) | A4 conflict replay / lookup | CAS values UNKNOWN |
|---|---|---|---|---|---|---|
| Diffusions Aromatiques | 2,668 | 75.0 % | 0.1 % | 0.3 % | n/a | 55.9 % of 1,137 |
| Vigon | 2,612 | 85.5 % | 5.1 % | 0.0 % | 0.0 / 0.0 % | 58.5 % of 875 |
| A & E Connock | 2,249 | 0.0 % | | | | |
| The Innovation Company | 2,134 | 0.1 % | 0.0 % | 0.0 % | 0.0 / 0.0 % | 25.0 % of 4 |
| Bela Vizago | 2,123 | 20.5 % | 1.4 % | 0.9 % | 49.2 / 49.2 % | 40.5 % of 466 |
| Lluch Essence | 2,063 | 97.0 % | 0.0 % | 0.0 % | n/a | 66.5 % of 1,454 |
| Earth Supplied Products | 1,567 | 0.0 % | | | | |
| Aston Chemicals | 1,562 | 0.0 % | | | | |
| Evonik | 1,450 | 6.1 % | 0.0 % | 0.0 % | 36.0 / 30.4 % | 25.0 % of 88 |
| Sina BT | 1,431 | 0.0 % | | | | |
| Kobo | 1,406 | 44.5 % | 0.0 % | 0.5 % | 9.1 / 9.8 % | 29.5 % of 226 |
| Indukern | 1,330 | 94.2 % | 0.0 % | 0.1 % | n/a | 60.0 % of 937 |
| Moellhausen | 1,262 | 0.0 % | | | | |
| PerfumersWorld | 1,240 | 66.9 % | 2.1 % | 0.4 % | n/a | 50.3 % of 534 |
| Croda | 1,185 | 6.8 % | 0.0 % | 3.7 % | 15.2 / 15.2 % | 28.1 % of 99 |
| Advanced Biotech | 1,111 | 82.5 % | 0.3 % | 1.1 % | n/a | 59.2 % of 578 |
| Arda Natura | 1,068 | 0.0 % | | | | |
| Prodotti Gianni | 1,054 | 0.0 % | | | | |
| Ranson | 993 | 0.0 % | | | | |
| BASF | 940 | 56.3 % | 0.0 % | 1.3 % | 15.7 / 9.5 % | 27.6 % of 495 |
Conflict share = products in conflict among products with agree or conflict for that source;
n/a = no product with a reference (no INCI on the same products). UNKNOWN share = distinct CAS
values of the company queried in F2 with UNKNOWN_IDENTIFIER.

## A6 Leading number of the distinct CAS queried in F2
| Bin | HAS_DATA | KNOWN_WITHOUT_DATA | UNKNOWN_IDENTIFIER |
|---|---|---|---|
| below 8000 | 562 (54.7 %), 6,325 products | 652 (32.0 %), 5,823 | 921 (26.5 %), 3,615 |
| 8000 to 8099 | 71 (6.9 %), 2,301 | 74 (3.6 %), 1,333 | 200 (5.8 %), 2,690 |
| 8100 to 8999 | 0 | 0 | 0 |
| 9000 to 9999 | 10 (1.0 %), 210 | 97 (4.8 %), 1,443 | 43 (1.2 %), 257 |
| 10000 to 67999 | 164 (16.0 %), 1,463 | 435 (21.3 %), 3,629 | 829 (23.9 %), 2,782 |
| 68000 to 99999 | 164 (16.0 %), 1,427 | 556 (27.3 %), 4,053 | 747 (21.5 %), 3,505 |
| 100000 and above | 57 (5.5 %), 205 | 224 (11.0 %), 1,085 | 733 (21.1 %), 1,924 |
| Total | 1,028 | 2,038 | 3,473 |
Products = distinct products carrying a CAS of that bin and status.

## Open points
- A4 synonyms (AQUA / WATER, CI numbers / chemical names) are not equated by the agreed rule;
  F3 repeats the comparison against CosIng.
