"""Summarize raw device observations. Not an Omni Bench Result or release approval.

Nearest-rank percentiles: sort N finite values, select ceil(p*N)-1 (p in 0..1).
No interpolation, warmup removal, missing-to-zero substitution, or quality scoring.
"""
import argparse
import hashlib
import json
import math
from collections import defaultdict
from pathlib import Path


def finite(value):
    return type(value) in (int, float) and math.isfinite(value) and value >= 0


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def percentile(values, p):
    if not values:
        return None
    if not all(finite(v) for v in values):
        raise ValueError('percentile inputs must be finite and nonnegative')
    return sorted(values)[max(0, math.ceil(p * len(values)) - 1)]


def stats(values):
    values = [v for v in values if finite(v)]
    return {'count': len(values), 'p50': percentile(values, .5), 'p95': percentile(values, .95)}


def canonical(value):
    return json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(',', ':'))


def group_contract(row):
    return {key: row.get(key) for key in ('source', 'target', 'scenario', 'speech_pipeline', 'timing_contract', 'device')}


def profile(row):
    return {'translation': row.get('translation_profile'), 'speech': row.get('speech_profile'),
            'speech_profile_id': row.get('speech_profile_id')}


def read_attempt(path, root):
    links = [{'path': str(path.relative_to(root)), 'sha256': sha(path)}]
    row = json.loads(path.read_text())
    problems = []
    if row.get('evidence_kind') != 'exploratory_device_observations' or not row.get('device'):
        problems.append('missing_device_provenance')
    if row.get('status') != 'succeeded':
        problems.append('incomplete_or_failed_attempt')
    if not finite(row.get('final_seconds')):
        problems.append('missing_final_seconds')
    if not isinstance(row.get('input_sha256'), str) or len(row['input_sha256']) != 64:
        problems.append('missing_sample_identity')
    if row.get('repeat_id') is None:
        problems.append('missing_repeat_identity')
    if not row.get('timing_contract') or not row.get('translation_profile'):
        problems.append('missing_profile_or_timing_contract')
    telemetry_path = path.with_name(path.stem + '-telemetry.jsonl')
    observations = []
    if telemetry_path.is_file():
        links.append({'path': str(telemetry_path.relative_to(root)), 'sha256': sha(telemetry_path)})
        try:
            observations = [json.loads(line) for line in telemetry_path.read_text().splitlines() if line.strip()]
        except (ValueError, UnicodeError):
            problems.append('malformed_telemetry')
        if not observations:
            problems.append('empty_telemetry')
    else:
        problems.append('missing_telemetry')
    footprints = [x.get('process_footprint_bytes') for x in observations]
    footprints = [v for v in footprints if finite(v)]
    warnings = [x.get('memory_warnings') for x in observations]
    warnings = [v for v in warnings if finite(v)]
    if not footprints or not warnings:
        problems.append('missing_footprint_or_warning_observations')
    observed = [x['speech'] for x in observations if isinstance(x.get('speech'), dict)]
    speech = row.get('speech_telemetry') or (observed[-1] if observed else {})
    preview = speech.get('firstPreviewSeconds')
    cold = row.get('cold_load_seconds')
    # Preparation may include downloads; MT per-leg load is not whole-pipeline cold load.
    if not finite(cold):
        cold = None
        problems.append('unavailable_complete_cold_load')
    if row.get('scenario') == 'dictation' and not finite(preview):
        problems.append('unavailable_preview')
    failure_counts = [s.get('correctionFailures') for s in observed] + [speech.get('correctionFailures')]
    failure_counts = [v for v in failure_counts if finite(v)]
    correction_failures = max(failure_counts) if failure_counts else None
    translation_failures = row.get('measurements', {}).get('translation_failures')
    if row.get('speech_pipeline') == 'concurrent' and not finite(translation_failures):
        problems.append('missing_translation_failure_observations')
    if finite(translation_failures) and translation_failures > 0:
        problems.append('translation_failures')
    if correction_failures and correction_failures > 0:
        problems.append('correction_failures')
    if warnings and max(warnings) > 0:
        problems.append('memory_warning')
    return {'row': row, 'links': links, 'problems': sorted(set(problems)),
            'final_seconds': row.get('final_seconds') if finite(row.get('final_seconds')) else None,
            'cold_load_seconds': cold, 'mt_model_load_seconds': row.get('model_load_seconds'),
            'first_preview_seconds': preview if finite(preview) else None,
            'peak_footprint': max(footprints) if footprints else None,
            'memory_warnings': max(warnings) if warnings else None,
            'correction_failures': correction_failures,
            'translation_failures': translation_failures if finite(translation_failures) else None}


def summarize(root):
    root = root.resolve()
    grouped = defaultdict(list)
    links = []
    errors = []
    provenance = None
    source_manifest = root / 'build-source.json'
    if source_manifest.is_file():
        try:
            provenance = json.loads(source_manifest.read_text()).get('source_sha256')
        except (OSError, ValueError, AttributeError):
            pass
    for path in sorted(root.glob('attempt-*.json')):
        try:
            attempt = read_attempt(path, root)
            if not isinstance(provenance, str) or len(provenance) != 64:
                attempt['problems'].append('missing_build_source_provenance')
            key = canonical({'contract': group_contract(attempt['row']), 'profile': profile(attempt['row'])})
            grouped[key].append(attempt)
            links.extend(attempt['links'])
        except (OSError, ValueError, TypeError, AttributeError) as error:
            errors.append({'path': path.name, 'sha256': sha(path), 'error': str(error)})
    groups = []
    for key, attempts in sorted(grouped.items()):
        group = json.loads(key)
        successful = [a for a in attempts if a['row'].get('status') == 'succeeded']
        group.update({'attempt_count': len(attempts), 'successful_attempt_count': len(successful),
                      'failed_or_incomplete_attempt_count': len(attempts) - len(successful),
                      'timings': {name: stats([a[name] for a in successful]) for name in
                                  ('final_seconds', 'cold_load_seconds', 'mt_model_load_seconds', 'first_preview_seconds')},
                      'observed_peak_process_footprint_bytes': max((a['peak_footprint'] for a in attempts if a['peak_footprint'] is not None), default=None),
                      'memory_warning_count': sum(a['memory_warnings'] for a in attempts) if all(a['memory_warnings'] is not None for a in attempts) else None,
                      'correction_failure_count': sum(a['correction_failures'] for a in attempts) if all(a['correction_failures'] is not None for a in attempts) else None,
                      'translation_failure_count': sum(a['translation_failures'] for a in attempts) if all(a['translation_failures'] is not None for a in attempts) else None,
                      'attempts': [{'path': a['links'][0]['path'], 'sample_id': a['row'].get('sample_id'),
                                    'input_sha256': a['row'].get('input_sha256'), 'repeat_id': a['row'].get('repeat_id'),
                                    'stress_cycle': a['row'].get('stress_cycle'), 'problems': a['problems'],
                                    'final_seconds': a['final_seconds']} for a in attempts],
                      'measurement_complete': all(not a['problems'] for a in attempts), 'release_gate_eligible': False})
        groups.append(group)
    for name in ('manifest.json', 'request.json', 'build-source.json'):
        path = root / name
        if path.is_file():
            links.append({'path': name, 'sha256': sha(path)})
    return {'schema_version': 1, 'artifact_kind': 'device_timing_summary_sidecar',
            'qualification_status': 'not_qualified', 'release_gate_eligible': False,
            'source_sha256': provenance, 'source_directory': str(root), 'percentile_method': 'nearest_rank_ceil_p_times_n_no_interpolation',
            'latency_contract': 'per-attempt service instantiation; final includes cold work; no subtraction of model-load time',
            'quality_metrics': None, 'groups': groups, 'artifacts': links, 'errors': errors}


def compare(baseline, candidate):
    results = []
    for left in baseline['groups']:
        for right in candidate['groups']:
            if left['contract'] != right['contract']:
                continue
            def identity(a):
                return (a['sample_id'], a['input_sha256'], a['repeat_id'], a['stress_cycle'])
            left_keys = [identity(a) for a in left['attempts']]
            right_keys = [identity(a) for a in right['attempts']]
            problems = []
            if set(left_keys) != set(right_keys) or len(set(left_keys)) != len(left_keys) or len(set(right_keys)) != len(right_keys):
                problems.append('unmatched_or_duplicate_sample_repeat_identity')
            by_sample = defaultdict(set)
            for a in left['attempts']:
                by_sample[(a['sample_id'], a['input_sha256'])].add(a['repeat_id'])
            if not by_sample or any(len(repeats) < 3 for repeats in by_sample.values()):
                problems.append('three_distinct_repeats_per_sample_required')
            if not left['measurement_complete'] or not right['measurement_complete']:
                problems.append('incomplete_measurements')
            ratios = None
            if not problems:
                base = left['timings']['final_seconds']['p95']
                cand = right['timings']['final_seconds']['p95']
                if finite(base) and base > 0 and finite(cand):
                    ratios = {'final_p95_candidate_over_baseline': cand / base}
                else:
                    problems.append('invalid_p95')
            results.append({'contract': left['contract'], 'baseline_profile': left['profile'],
                            'candidate_profile': right['profile'], 'matched': not problems,
                            'problems': problems, 'ratios': ratios, 'release_gate_eligible': False})
    return {'status': 'compared' if results else 'no_identical_timing_contracts', 'comparisons': results}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--compare', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    result = summarize(args.directory)
    if args.compare:
        other = summarize(args.compare)
        result['candidate_summary'] = other
        result['comparison'] = compare(result, other)
    text = json.dumps(result, sort_keys=True, ensure_ascii=False, indent=2) + '\n'
    if args.output:
        args.output.write_text(text)
    else:
        print(text, end='')


if __name__ == '__main__':
    main()
