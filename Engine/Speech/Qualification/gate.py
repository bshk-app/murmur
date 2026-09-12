"""Offline release evidence verifier. No inference or replacement of Omni Bench scoring.

All artifact paths are relative to the evidence directory. An accepted bundle is
an audit prerequisite, never cryptographic proof that host declarations are true.
"""
import argparse
import hashlib
import json
import math
import re
from pathlib import Path

# Schema2 first20 release gate: pinned full available FLORES+ devtest.
# No CLI/environment override; a different corpus requires a reviewed schema change.
FLORES_DEVTEST_COUNT = 1012

LANGUAGES = ('ru', 'en', 'fi', 'de', 'fr')
DIRECTIONS = {f'{a}-{b}' for a in LANGUAGES for b in LANGUAGES if a != b}
SCENARIOS = {'dictation', 'text', 'pages'}
STRATA = {'reading', 'spontaneous', 'noise', 'long'}
CHECKS = {'offline', 'cancel', 'language_change', 'reload', 'corrupt_package', 'unload', 'rollback'}


QUALITY_METRICS = {'mt': {'chrf++': 'quality.translation_chrf_pp.v1', 'bleu': 'quality.translation_bleu.v1'},
                   'asr': {'wer': 'quality.wer_norm.v1', 'cer': 'quality.cer.v1'}}


def inspect_result(result, records, expected, family):
    """Check stock Omni Result/run consistency; never recompute a quality metric."""
    if result.get('document_type') != 'result' or result.get('schema_version') != '0.6.0' or result.get('status') != 'complete':
        raise ValueError('complete Result0.6 required')
    if not records or records[0].get('record_type') != 'run_header' or records[-1].get('record_type') != 'run_footer':
        raise ValueError('run header/footer required')
    header, footer = records[0], records[-1]
    if header.get('schema_version') != '0.6.0':
        raise ValueError('run schema mismatch')
    for key in ('identity', 'identity_key', 'definition_ref', 'registry_ref'):
        if not expected.get(key) or result.get(key) != expected[key] or header.get(key) != expected[key]:
            raise ValueError('pinned ' + key + ' mismatch')
    identity = result['identity']
    if identity.get('definition_ref') != result['definition_ref']:
        raise ValueError('identity definition mismatch')
    ids = expected.get('sample_ids', [])
    if not ids or not all(isinstance(s, str) and s for s in ids) or len(set(ids)) != len(ids):
        raise ValueError('unique pinned heldout IDs required')
    count = len(ids)
    if family == 'mt' and (count != FLORES_DEVTEST_COUNT or
                           'devtest' not in result['definition_ref'].get('id', '').split('.')):
        raise ValueError('full 1012-sample FLORES devtest required')
    counts = {'n_total': count, 'n_ok': count, 'n_error': 0}
    if result.get('counts') != counts or footer.get('counts') != counts or header.get('expected_sample_count') != count:
        raise ValueError('incomplete or failed samples')
    if footer.get('family_completion_evidence', {}).get('all_streams_exhausted') is not True:
        raise ValueError('unexhausted run')
    samples = records[1:-1]
    if len(samples) != count or any(r.get('record_type') != 'sample' or r.get('status') != 'ok' or r.get('error') is not None for r in samples):
        raise ValueError('unsuccessful sample records')
    actual_ids = [r.get('sample_id') for r in samples]
    if len(set(actual_ids)) != count or set(actual_ids) != set(ids):
        raise ValueError('heldout sample mismatch')
    values = {}
    for name, metric_id in QUALITY_METRICS[family].items():
        observations = [o for o in result.get('observations', []) if o.get('metric_ref', {}).get('id') == metric_id]
        if len(observations) != 1:
            raise ValueError('missing/duplicate ' + name)
        observation = observations[0]
        value = observation.get('value', {})
        scalar = value.get('value')
        if (observation.get('status') != 'measured' or value.get('kind') != 'scalar' or value.get('n') != count or
                type(scalar) not in (int, float) or not math.isfinite(scalar) or scalar < 0):
            raise ValueError('invalid measured ' + name)
        values[name] = scalar
    return values


def inspect_review(review, key, pair, expectations, outputs):
    if review.get('direction') != pair or review.get('status') != 'completed' or key.get('direction') != pair:
        raise ValueError('completed directional review required')
    for arm in ('baseline', 'candidate'):
        if key.get(arm + '_identity') != expectations[arm]['mt']['identity']:
            raise ValueError('review identity mismatch')
    rows, assignments = review.get('rows', []), key.get('assignments', [])
    if len(rows) < 100 or review.get('completed_reviews') != len(rows):
        raise ValueError('100 completed reviews required')
    if len({r.get('review_id') for r in rows}) != len(rows) or len({r.get('sample_id') for r in rows}) != len(rows):
        raise ValueError('duplicate review rows')
    mapping = {a.get('review_id'): a for a in assignments}
    if len(mapping) != len(assignments) or set(mapping) != {r.get('review_id') for r in rows}:
        raise ValueError('review assignment mismatch')
    heldout = set(expectations['baseline']['mt']['sample_ids'])
    for row in rows:
        if not row.get('review_id') or row.get('sample_id') not in heldout:
            raise ValueError('review outside heldout samples')
        assignment = mapping[row['review_id']]
        if {assignment.get('A'), assignment.get('B')} != {'baseline', 'candidate'}:
            raise ValueError('invalid blind assignment')
        for field in ('source', 'reference', 'A', 'B'):
            if not isinstance(row.get(field), str) or not row[field].strip():
                raise ValueError('empty review text')
        for side in ('A', 'B'):
            if row[side] != outputs[assignment[side]].get(row['sample_id']):
                raise ValueError('review text differs from linked run')
        if row.get('overall_preference') not in ('A', 'B', 'tie', 'uncertain'):
            raise ValueError('unfilled preference')
        if any(not isinstance(row.get(k), str) or not row[k].strip() for k in ('reviewer_name', 'reviewed_at')):
            raise ValueError('reviewer/date required')
        for side in ('A', 'B'):
            for category in ('negation', 'numbers', 'names', 'omission', 'meaning'):
                if row.get(side + '_' + category + '_error') not in ('yes', 'no', 'uncertain'):
                    raise ValueError('unfilled error annotation')
    return len(rows)


def verify(bundle, root):
    errors = []
    def require(value, label):
        if not value:
            errors.append(label)
    def artifact(ref, label):
        if not isinstance(ref, dict):
            errors.append(label + ': missing artifact')
            return
        path = (root / ref.get('path', '')).resolve()
        if not path.is_relative_to(root.resolve()) or not path.is_file():
            errors.append(label + ': missing or escaping artifact')
            return
        require(hashlib.sha256(path.read_bytes()).hexdigest() == ref.get('sha256'), label + ': hash mismatch')
        return path
    def digest(value):
        return isinstance(value, str) and re.fullmatch(r'[0-9a-f]{64}', value) is not None
    def number(value):
        return type(value) in (int, float) and math.isfinite(value) and value >= 0
    require(bundle.get('schema_version') == 2, 'schema_version')
    require(bundle.get('evidence_kind') == 'measured', 'measured evidence required')
    require(bundle.get('device') == 'iPhone16,1', 'physical iPhone 15 Pro required')
    require(bundle.get('simulator') is False, 'simulator must be false')
    for key in ('source', 'omni_registry', 'omni_schemas', 'baseline_manifest', 'candidate_manifest'):
        artifact(bundle.get(key), key)
    selection = set(bundle.get('selection_sample_ids', []))
    heldout = set(bundle.get('heldout_sample_ids', []))
    require(bool(selection) and bool(heldout) and not selection & heldout, 'disjoint nonempty selection/heldout samples')
    entries = bundle.get('directions', [])
    require(len(entries) == 20 and {x.get('direction') for x in entries} == DIRECTIONS, 'all 20 unique directions required')
    for entry in entries:
        pair = entry.get('direction', '?')
        if entry.get('quality_decision') == 'retained_baseline':
            baseline = entry.get('baseline_profile')
            selected = entry.get('selected_profile')
            artifact(baseline, pair + ': retained baseline profile')
            artifact(selected, pair + ': retained selected profile')
            baseline_hash = baseline.get('sha256') if isinstance(baseline, dict) else None
            selected_hash = selected.get('sha256') if isinstance(selected, dict) else None
            require(digest(baseline_hash) and baseline_hash == selected_hash,
                    pair + ': retained baseline must have identical complete pipeline profile')
            continue
        try:
            expectations = {}
            outputs = {}
            for arm in ('baseline', 'candidate'):
                manifest = json.loads(artifact(bundle.get(arm + '_manifest'), arm + ' manifest').read_text())
                if manifest.get('source_artifact_sha256') != bundle['source']['sha256']:
                    raise ValueError('manifest source link mismatch')
                expectations[arm] = manifest['expectations'][pair]
                for family in ('mt', 'asr'):
                    expected = expectations[arm][family]
                    if not set(expected['sample_ids']).issubset(heldout) or set(expected['sample_ids']) & selection:
                        raise ValueError('unpinned/selection quality samples')
                    refs = entry['quality_results'][arm][family]
                    result = json.loads(artifact(refs['result'], pair + ':' + arm + ':' + family).read_text())
                    run_path = artifact(refs['run'], pair + ':' + arm + ':' + family + ':run')
                    if result.get('run_artifact_sha256') != 'sha256:' + refs['run']['sha256']:
                        raise ValueError('result run link mismatch')
                    records = [json.loads(line) for line in run_path.read_text().splitlines()]
                    if family == 'mt':
                        outputs[arm] = {r['sample_id']: r.get('evidence', {}).get('text') for r in records[1:-1]}
                    values = inspect_result(result, records, expected, family)
                    for metric, value in values.items():
                        if entry.get('metrics', {}).get(metric, {}).get(arm) != value:
                            raise ValueError('declared metric differs from Omni observation: ' + metric)
            for family in ('mt', 'asr'):
                base, candidate = expectations['baseline'][family], expectations['candidate'][family]
                if base['sample_ids'] != candidate['sample_ids'] or base['definition_ref'] != candidate['definition_ref']:
                    raise ValueError('arms have different samples/definition')
                for field in ('dataset_content_sha256', 'protocol_sha256'):
                    if not base['identity'].get(field) or base['identity'][field] != candidate['identity'].get(field):
                        raise ValueError('arms have different dataset/protocol')
            review = json.loads(artifact(entry.get('human_review'), pair + ': blind review').read_text())
            key = json.loads(artifact(entry.get('review_assignment_key'), pair + ': blind key').read_text())
            count = inspect_review(review, key, pair, expectations, outputs)
            if count != entry.get('blind_sample_count'):
                raise ValueError('declared review count mismatch')
        except (OSError, ValueError, TypeError, KeyError, AttributeError) as error:
            errors.append(pair + ': invalid linked quality evidence: ' + str(error))
        artifact(entry.get('diagnostic_review'), pair + ': omissions/repeats/language/numbers/negation review')
        require(entry.get('blind_bilingual') is True and entry.get('blind_sample_count', 0) >= 100, pair + ': 100 blind bilingual samples required')
        require(entry.get('reviewer_id') and entry.get('quality_decision') == 'improved_without_stratum_regression', pair + ': documented quality acceptance required')
        require(entry.get('flores_split') == 'devtest' and entry.get('flores_full_available_split') is True, pair + ': full available FLORES devtest required')
        for metric in ('chrf++', 'bleu', 'wer', 'cer'):
            values = entry.get('metrics', {}).get(metric, {})
            require(all(number(values.get(arm)) for arm in ('baseline', 'candidate')), pair + ': invalid ' + metric)
        require(set(entry.get('speech_strata', [])) == STRATA, pair + ': missing speech strata')
        runs = entry.get('device_runs', [])
        for scenario in SCENARIOS:
            matched = [r for r in runs if r.get('scenario') == scenario]
            require(len(matched) >= 3 and len({r.get('repeat_id') for r in matched}) == len(matched), pair + ': three distinct ' + scenario + ' repeats required')
            for run in matched:
                label = pair + ':' + scenario + ':' + str(run.get('repeat_id'))
                artifact(run.get('artifact'), label)
                require(run.get('baseline_sample_sha256') == run.get('candidate_sample_sha256') and digest(run.get('baseline_sample_sha256')), label + ': unmatched samples')
                for arm in ('baseline', 'candidate'):
                    require(run.get(arm + '_manifest_sha256') == bundle.get(arm + '_manifest', {}).get('sha256') and digest(run.get(arm + '_manifest_sha256')), label + ': unmatched ' + arm + ' profile')
                require(run.get('evidence_kind') == 'measured' and run.get('device') == 'iPhone16,1', label + ': wrong provenance')
                for metric, limit in [('final_p95_s', 2), ('peak_process_bytes', 1.2)] + ([('preview_p95_s', 1.1)] if scenario == 'dictation' else []):
                    base, candidate = run.get('baseline', {}).get(metric), run.get('candidate', {}).get(metric)
                    require(number(base) and number(candidate) and base > 0 and candidate <= limit * base, label + ': budget ' + metric)
                for arm in ('baseline', 'candidate'):
                    require(all(number(run.get(arm, {}).get(m)) for m in ('final_median_s', 'cold_load_s')), label + ': missing timing ' + arm)
        stress = entry.get('stress', {})
        artifact(stress.get('artifact'), pair + ': stress')
        require(number(stress.get('duration_s')) and stress.get('duration_s', 0) >= 1800, pair + ': 30 minute stress required')
        require(all(stress.get(k) == 0 for k in ('memory_warnings', 'crashes', 'queue_growth')), pair + ': stress failure/missing measurement')
        require(set(entry.get('passed_lifecycle_checks', [])) == CHECKS, pair + ': lifecycle checks')
        artifact(entry.get('lifecycle_artifact'), pair + ': lifecycle')
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('evidence', type=Path)
    args = parser.parse_args()
    try:
        errors = verify(json.loads(args.evidence.read_text()), args.evidence.parent)
    except (OSError, ValueError, TypeError, KeyError, AttributeError) as error:
        errors = ['invalid evidence: ' + str(error)]
    print(json.dumps({'eligible': not errors, 'errors': errors}, indent=2))
    raise SystemExit(bool(errors))

if __name__ == '__main__':
    main()
