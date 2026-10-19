"""
Relay X to Covalo identifier matching prototype.

Flattens Relay X's substances[].constraintsUnion[] JSON structure into one row
per regulatory entry, builds identifier lookup indices from Covalo's CosIng-style
CSV, and computes an independent match rate per identifier type (CAS, EC, CLP
index, INCI). Independent means each identifier type is checked on its own
merits rather than a first-match-wins cascade, so coverage and match rate per
type are both visible instead of the higher-priority type shadowing the rest.

Two parsing quirks this handles, found by inspecting mismatches directly:
  1. Covalo's CSV mixes '/' and '|' as separators within the same cell
     (e.g. "OLD NAME / NEW NAME | ALT NAME"). A naive split on one separator
     leaves the other embedded in the token, so both are split on together.
  2. Relay X group entries sometimes give multi-value CAS/EC as a bracket-
     indexed string ("123-45-6 [1] 789-01-2 [2]") with no casList/ecList to
     fall back on. The bracket markers are stripped and the remainder split
     on slashes or whitespace, since CAS/EC numbers never contain whitespace.

Update the two file paths below to point at the full pull once the API
interface is built; the flattening and matching logic does not change.
"""
import json, csv, re
from collections import Counter, defaultdict

PLACEHOLDER = {'-', '', 'N/A', 'NA'}

def norm(s):
    if not s:
        return None
    s = s.strip().upper()
    return s if s not in PLACEHOLDER else None

def split_covalo_field(s):
    """Covalo fields mix both '/' and '|' as separators within the same cell."""
    if not s:
        return []
    parts = re.split(r'[|/]', s)
    return [p.strip() for p in parts if p.strip() and p.strip() not in PLACEHOLDER]

def split_relayx_multi(s):
    """RelayX raw multi-value strings: seen '/'-separated and '[n]'-bracket-indexed forms."""
    if not s or s.strip() in PLACEHOLDER:
        return []
    s2 = re.sub(r'\[\d+\]', '', s)  # strip bracket index markers
    parts = re.split(r'[/\s]+', s2)  # CAS/EC numbers never contain internal whitespace
    return [p.strip() for p in parts if p.strip() and p.strip() not in PLACEHOLDER]

# ---------- Load and flatten Relay X sample ----------
with open('demo-api-EU-2026-08-19.json') as f:
    data = json.load(f)

rows = []
for s in data['substances']:
    sub = s['substance']
    for e in s['constraintsUnion']:
        ids = e.get('identifiers', {}) or {}
        nom = e.get('nomenclature', {}) or {}

        cas_candidates = set(ids.get('casList') or [])
        cas_candidates.update(split_relayx_multi(ids.get('cas')))
        if sub.get('cas'):
            cas_candidates.add(sub['cas'])
        cas_candidates.discard(None)

        ec_candidates = set(ids.get('ecList') or [])
        ec_candidates.update(split_relayx_multi(ids.get('ec')))
        ec_candidates.discard(None)

        inci_candidates = set()
        for v in [ids.get('inci'), nom.get('inciEu'), nom.get('inciIecic'), nom.get('inciUs')]:
            n = norm(v)
            if n:
                inci_candidates.add(n)
        for v in (nom.get('synonyms') or []):
            n = norm(v)
            if n:
                inci_candidates.add(n)
        if ids.get('inciList'):
            for v in ids['inciList']:
                n = norm(v)
                if n:
                    inci_candidates.add(n)
        n = norm(sub.get('inci'))
        if n:
            inci_candidates.add(n)

        rows.append({
            'logicalEntryId': e.get('logicalEntryId'),
            'substance_inci': sub.get('inci'),
            'substance_cas': sub.get('cas'),
            'category': sub.get('category'),
            'entryScope': e.get('entryScope'),
            'annexType': e.get('annexType'),
            'clpIndex': norm(ids.get('clpIndex')),
            'cas_candidates': cas_candidates,
            'ec_candidates': ec_candidates,
            'inci_candidates': inci_candidates,
        })

total = len(rows)
print(f'Flattened {total} constraint-entry rows from {len(data["substances"])} substances.')

# ---------- Load and index Covalo CSV ----------
with open('identifiersonlyEU2.csv', encoding='utf-8-sig') as f:
    reader = csv.DictReader(f)
    covalo_rows = list(reader)

cas_index = defaultdict(set)
ec_index = defaultdict(set)
clp_index = defaultdict(set)
inci_index = defaultdict(set)

for i, r in enumerate(covalo_rows):
    for c in split_covalo_field(r['CAS number']):
        cas_index[c].add(i)
    for c in split_covalo_field(r['EC number']):
        ec_index[c].add(i)
    for c in split_covalo_field(r['CLP index number']):
        clp_index[c].add(i)
    for c in split_covalo_field(r['INCI name']):
        inci_index[norm(c)].add(i)
    for c in split_covalo_field(r['INCI name (US)']):
        inci_index[norm(c)].add(i)

print(f'Indexed {len(covalo_rows)} Covalo rows: {len(cas_index)} unique CAS, {len(ec_index)} unique EC, {len(clp_index)} unique CLP, {len(inci_index)} unique INCI tokens.')

def independent_stats(cands_key, index, is_clp=False):
    have, matched = 0, 0
    for row in rows:
        if is_clp:
            val = row['clpIndex']
            present = bool(val)
            hit = present and val in index
        else:
            cands = row[cands_key]
            present = bool(cands)
            hit = present and bool(cands & index.keys())
        if present:
            have += 1
            if hit:
                matched += 1
    return have, matched

print()
print('=== Independent match rate by identifier type (corrected parsing) ===')
for label, key, idx, is_clp in [
    ('CAS', 'cas_candidates', cas_index, False),
    ('EC', 'ec_candidates', ec_index, False),
    ('CLP', None, clp_index, True),
    ('INCI', 'inci_candidates', inci_index, False),
]:
    have, matched = independent_stats(key, idx, is_clp)
    pct_coverage = 100*have/total
    pct_match = 100*matched/have if have else 0
    print(f'  {label:5s}: present in {have:3d}/{total} rows ({pct_coverage:5.1f}% coverage) -> of those, {matched:3d} matched ({pct_match:5.1f}%)')

print()
print('--- Remaining EC mismatches after fix ---')
for row in rows:
    if row['ec_candidates'] and not (row['ec_candidates'] & ec_index.keys()):
        print(f"  substance={row['substance_inci']!r} cas={row['substance_cas']!r} ec_candidates={row['ec_candidates']} scope={row['entryScope']} annexType={row['annexType']}")

print()
print('--- Remaining INCI mismatches after fix ---')
for row in rows:
    if row['inci_candidates'] and not (row['inci_candidates'] & inci_index.keys()):
        print(f"  substance={row['substance_inci']!r} cas={row['substance_cas']!r} inci_candidates={row['inci_candidates']}")
