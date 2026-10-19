"""
Stage 1 of the two-table Relay X preprocessing model: the entries table.

Grain: one row per unique logicalEntryId, Relay X's own deduplication key for
a single regulatory record (one legal provision). This is the lowest
granularity the source data supports; a logicalEntryId's rules/cases are a
single bundled provision, not independently matchable facts, and no field
below that level is a stable, addressable unit.

Why dedup on logicalEntryId at all: substances[].constraintsUnion arrays are
each a per-substance union of an INCI-path and CAS-path query, not deduped
across substances. When one legal provision covers several substances (a
GROUP entry, or the same SINGLE entry reached by both a substance and its
salt), that logicalEntryId shows up once per substance query. In this sample,
189 (substance, entry) rows collapse to 180 unique logicalEntryId values.

Verified empirically (not assumed) before deduping: for every logicalEntryId
that repeats, the only field that ever differs between occurrences is
`reachedViaGroupEntry`. That field describes whether *this particular
substance query* reached the entry via a group lookup, so it is a property
of the (substance, entry) relationship, not of the entry itself. It is
excluded here and belongs in the substance-entry bridge table (stage 2).

Everything else that varies per substance (which substance query reached
this entry, and that substance's own top-level inci/cas) is deliberately
left out of this table too, for the same reason: it is bridge-table content,
not entry content. Keeping it out of stage 1 is what lets stage 2 measure
match rate against the entry's own data before any query-context fallback
is added.
"""
import json


def flatten_entry(e: dict) -> dict:
    ids = e.get('identifiers') or {}
    nom = e.get('nomenclature') or {}
    text = e.get('text') or {}
    literal = e.get('literal') or {}
    validity = e.get('validity') or {}
    provenance = e.get('provenance') or {}
    history = e.get('history') or {}
    introduced_by = history.get('introducedBy') or {}
    legislator = text.get('legislator') or {}

    def j(v):
        return json.dumps(v, ensure_ascii=False) if v not in (None, [], {}) else None

    return {
        'logicalEntryId': e.get('logicalEntryId'),
        'entryRef': e.get('entryRef'),
        'annexRef': e.get('annexRef'),
        'annexRefEn': e.get('annexRefEn'),
        'annexType': e.get('annexType'),
        'entryScope': e.get('entryScope'),
        'entryRefNote': e.get('entryRefNote'),
        'entryRefKind': e.get('entryRefKind'),
        'territory': e.get('territory'),
        'productStatus': e.get('productStatus'),
        'nature': e.get('nature'),
        'derivationLegalBasis': e.get('derivationLegalBasis'),
        # identifiers, as asserted by this entry itself
        'id_name': ids.get('name'),
        'id_nameEn': ids.get('nameEn'),
        'id_nameLocal': ids.get('nameLocal'),
        'id_cas': ids.get('cas'),
        'id_ec': ids.get('ec'),
        'id_clpIndex': ids.get('clpIndex'),
        'id_inci': ids.get('inci'),
        'id_colourIndex': ids.get('colourIndex'),
        'id_casList': j(ids.get('casList')),
        'id_ecList': j(ids.get('ecList')),
        'id_inciList': j(ids.get('inciList')),
        # nomenclature
        'nom_inciEu': nom.get('inciEu'),
        'nom_inciUs': nom.get('inciUs'),
        'nom_inciIecic': nom.get('inciIecic'),
        'nom_labelMixed': nom.get('labelMixed'),
        'nom_labelMixedParenthetical': nom.get('labelMixedParenthetical'),
        'nom_colourIndex': nom.get('colourIndex'),
        'nom_chemicalName': nom.get('chemicalName'),
        'nom_synonyms': j(nom.get('synonyms')),
        # legal source reference
        'text_officialRef': text.get('officialRef'),
        'text_celexNumber': text.get('celexNumber'),
        'text_title': text.get('title'),
        'text_legislatorCode': legislator.get('code'),
        'text_legislatorName': legislator.get('name'),
        'text_publicationDate': text.get('publicationDate'),
        'text_applicationDate': text.get('applicationDate'),
        'text_consolidatedVersion': text.get('consolidatedVersion'),
        'text_sourceUrl': text.get('sourceUrl'),
        'text_sourceUrlKind': text.get('sourceUrlKind'),
        # quoted literal excerpt
        'literal_concentration_original': (literal.get('concentration') or {}).get('original'),
        'literal_conditions_original': (literal.get('conditions') or {}).get('original'),
        'literal_warnings_original': (literal.get('warnings') or {}).get('original'),
        'literal_productScope_original': (literal.get('productScope') or {}).get('original'),
        'literal_language': literal.get('language'),
        'literal_provenance': literal.get('provenance'),
        # validity window
        'validity_placingOnMarketFrom': validity.get('placingOnMarketFrom'),
        'validity_placingOnMarketUntil': validity.get('placingOnMarketUntil'),
        'validity_makingAvailableFrom': validity.get('makingAvailableFrom'),
        'validity_makingAvailableUntil': validity.get('makingAvailableUntil'),
        'validity_precision': validity.get('precision'),
        # provenance / trust
        'provenance_origin': provenance.get('origin'),
        'provenance_verificationLevel': provenance.get('verificationLevel'),
        'provenance_sourceLocator': provenance.get('sourceLocator'),
        'provenance_verificationNote': provenance.get('verificationNote'),
        'provenance_errataNote': provenance.get('errataNote'),
        'provenance_dateVerification': provenance.get('dateVerification'),
        # history
        'history_introducedBy_officialRef': introduced_by.get('officialRef'),
        'history_introducedBy_title': introduced_by.get('title'),
        'history_introducedBy_publicationDate': introduced_by.get('publicationDate'),
        'history_introducedByIsContainingDocument': history.get('introducedByIsContainingDocument'),
        # rule payload: kept as JSON, not needed for identifier matching but
        # needed intact for the later rule-ingestion phase
        'rulesTruncated': e.get('rulesTruncated'),
        'rules_json': j(e.get('rules')),
        'cases_json': j(e.get('cases')),
        'productScopeStructured_json': j(e.get('productScopeStructured')),
        'productScopeBranches_json': j(e.get('productScopeBranches')),
        'regulatoryFootnotes_json': j(e.get('regulatoryFootnotes')),
        'derivedFrom_json': j(e.get('derivedFrom')),
        'knownSince': e.get('knownSince'),
    }


def build_entries_table(relayx_json_path: str) -> list[dict]:
    with open(relayx_json_path) as f:
        data = json.load(f)

    entries_by_id: dict[str, dict] = {}
    raw_occurrences = 0
    for s in data['substances']:
        for e in s['constraintsUnion']:
            raw_occurrences += 1
            lid = e['logicalEntryId']
            if lid not in entries_by_id:
                entries_by_id[lid] = flatten_entry(e)
            # else: already captured; content is identical except for
            # reachedViaGroupEntry, which is intentionally not stored here

    print(f'Substances in file: {len(data["substances"])}')
    print(f'(substance, entry) occurrences: {raw_occurrences}')
    print(f'Unique entries after dedup on logicalEntryId: {len(entries_by_id)}')
    return list(entries_by_id.values())


if __name__ == '__main__':
    import csv

    entries = build_entries_table('demo-api-EU-2026-08-19.json')
    fieldnames = list(entries[0].keys())
    with open('/mnt/user-data/outputs/relayx_entries_table.csv', 'w', newline='', encoding='utf-8') as f:
        w = csv.DictWriter(f, fieldnames=fieldnames)
        w.writeheader()
        w.writerows(entries)
    print(f'Wrote {len(entries)} rows to relayx_entries_table.csv')
