import copy
import hashlib
import json
import tempfile
import unittest
from unittest.mock import patch
from pathlib import Path
from gate import CHECKS, DIRECTIONS, SCENARIOS, STRATA, QUALITY_METRICS, inspect_result, verify


class GateTests(unittest.TestCase):
    def setUp(self):
        # Small synthetic unit fixtures only; production gate has no override.
        fixture_count = patch('gate.FLORES_DEVTEST_COUNT', 100)
        fixture_count.start()
        self.addCleanup(fixture_count.stop)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        # Test-only evidence, never shipped as a qualification result.
        raw = b'unit test artifact'
        (self.root / 'artifact').write_bytes(raw)
        self.ref = {'path': 'artifact', 'sha256': hashlib.sha256(raw).hexdigest()}
        self.bundle = {'schema_version': 2, 'evidence_kind': 'measured', 'device': 'iPhone16,1', 'simulator': False,
                       'selection_sample_ids': ['selection'], 'heldout_sample_ids': ['heldout']}
        self.bundle.update({k: self.ref for k in ('source', 'omni_registry', 'omni_schemas', 'baseline_manifest', 'candidate_manifest')})
        self.bundle['directions'] = []
        for pair in sorted(DIRECTIONS):
            entry = {'direction': pair, 'quality_result': self.ref, 'human_review': self.ref,
                     'diagnostic_review': self.ref, 'blind_bilingual': True, 'blind_sample_count': 100,
                     'reviewer_id': 'test-reviewer', 'quality_decision': 'improved_without_stratum_regression',
                     'flores_split': 'devtest', 'flores_full_available_split': True,
                     'metrics': {m: {'baseline': 1, 'candidate': 1} for m in ('chrf++', 'bleu', 'wer', 'cer')},
                     'speech_strata': sorted(STRATA), 'device_runs': [],
                     'stress': {'artifact': self.ref, 'duration_s': 1800, 'memory_warnings': 0, 'crashes': 0, 'queue_growth': 0},
                     'passed_lifecycle_checks': sorted(CHECKS), 'lifecycle_artifact': self.ref}
            for scenario in SCENARIOS:
                for repeat in range(3):
                    entry['device_runs'].append({'scenario': scenario, 'repeat_id': repeat,
                        'artifact': self.ref, 'baseline_sample_sha256': 'a' * 64, 'candidate_sample_sha256': 'a' * 64,
                        'baseline_manifest_sha256': self.ref['sha256'], 'candidate_manifest_sha256': self.ref['sha256'],
                        'evidence_kind': 'measured', 'device': 'iPhone16,1',
                        'baseline': {'final_p95_s': 1, 'peak_process_bytes': 100, 'preview_p95_s': 1, 'final_median_s': 1, 'cold_load_s': 1},
                        'candidate': {'final_p95_s': 2, 'peak_process_bytes': 120, 'preview_p95_s': 1.1, 'final_median_s': 1, 'cold_load_s': 1}})
            self.bundle['directions'].append(entry)

        # Synthetic stock-shaped Omni records, explicitly test-only.
        def write(name, value, lines=False):
            raw = ('\n'.join(json.dumps(r) for r in value) + '\n') if lines else json.dumps(value)
            (self.root / name).write_text(raw)
            return {'path': name, 'sha256': hashlib.sha256(raw.encode()).hexdigest()}
        ids = [f'heldout-{i}' for i in range(100)]
        self.bundle['heldout_sample_ids'] = ids
        manifests = {arm: {'source_artifact_sha256': self.ref['sha256'], 'expectations': {}} for arm in ('baseline', 'candidate')}
        for entry in self.bundle['directions']:
            pair = entry['direction']
            entry['quality_results'] = {}
            arm_identities = {}
            for arm in ('baseline', 'candidate'):
                entry['quality_results'][arm] = {}
                expected = {}
                for family in ('mt', 'asr'):
                    definition = {'id': pair + '.' + family + '.devtest', 'sha256': 'sha256:' + 'd' * 64}
                    identity = {'model': {'base_model_id': arm, 'artifact_sha256': 'sha256:' + ('a' if arm == 'baseline' else 'b') * 64},
                        'definition_ref': definition, 'dataset_content_sha256': 'sha256:' + 'c' * 64, 'protocol_sha256': 'sha256:' + 'd' * 64}
                    pinned = {'identity': identity, 'identity_key': 'sha256:' + ('a' if arm == 'baseline' else 'b') * 64,
                        'definition_ref': definition, 'registry_ref': {'content_sha256': 'sha256:' + 'e' * 64}, 'sample_ids': ids}
                    expected[family] = pinned
                    header = {k: v for k, v in pinned.items() if k != 'sample_ids'}
                    header.update(record_type='run_header', schema_version='0.6.0', expected_sample_count=100)
                    counts = {'n_total': 100, 'n_ok': 100, 'n_error': 0}
                    records = [header] + [{'record_type': 'sample', 'sample_id': sid, 'status': 'ok', 'error': None, 'evidence': {'text': arm + sid}} for sid in ids] + [
                        {'record_type': 'run_footer', 'counts': counts, 'family_completion_evidence': {'all_streams_exhausted': True}}]
                    run = write(pair + arm + family + '.jsonl', records, lines=True)
                    result = {k: v for k, v in pinned.items() if k != 'sample_ids'}
                    result.update(document_type='result', schema_version='0.6.0', status='complete', counts=counts,
                        run_artifact_sha256='sha256:' + run['sha256'], observations=[{'metric_ref': {'id': metric}, 'status': 'measured',
                        'value': {'kind': 'scalar', 'value': 1, 'n': 100}} for metric in QUALITY_METRICS[family].values()])
                    entry['quality_results'][arm][family] = {'result': write(pair + arm + family + '.json', result), 'run': run}
                manifests[arm]['expectations'][pair] = expected
                arm_identities[arm + '_identity'] = expected['mt']['identity']
            rows = []
            assignments = []
            for sid in ids:
                row = {'review_id': sid, 'sample_id': sid, 'overall_preference': 'tie', 'reviewer_name': 'TEST ONLY', 'reviewed_at': '2026-09-11', 'source': 'test source', 'reference': 'test reference', 'A': 'baseline' + sid, 'B': 'candidate' + sid}
                row.update({side + '_' + category + '_error': 'no' for side in ('A', 'B') for category in ('negation', 'numbers', 'names', 'omission', 'meaning')})
                rows.append(row)
                assignments.append({'review_id': sid, 'A': 'baseline', 'B': 'candidate'})
            entry['human_review'] = write(pair + '.review.json', {'direction': pair, 'status': 'completed', 'completed_reviews': 100, 'rows': rows})
            entry['review_assignment_key'] = write(pair + '.key.json', dict(arm_identities, direction=pair, assignments=assignments))
        for arm, manifest in manifests.items():
            self.bundle[arm + '_manifest'] = write(arm + '.manifest.json', manifest)
        for entry in self.bundle['directions']:
            for run in entry['device_runs']:
                for arm in ('baseline', 'candidate'):
                    run[arm + '_manifest_sha256'] = self.bundle[arm + '_manifest']['sha256']

    def change_json(self, ref, change):
        path = self.root / ref['path']
        value = json.loads(path.read_text())
        change(value)
        raw = json.dumps(value).encode()
        path.write_bytes(raw)
        ref['sha256'] = hashlib.sha256(raw).hexdigest()

    def test_rejects_hash_valid_failed_partial_wrong_identity_results(self):
        original = copy.deepcopy(self.bundle)
        mutations = [lambda r: r.update(status='failed'),
                     lambda r: r['counts'].update(n_error=1),
                     lambda r: r['identity']['model'].update(base_model_id='wrong-arm'),
                     lambda r: r['identity'].update(dataset_content_sha256='sha256:' + 'f' * 64),
                     lambda r: r['observations'][0].update(status='unavailable'),
                     lambda r: r['observations'][0]['value'].update(n=99),
                     lambda r: r['observations'][0]['value'].update(value=9)]
        ref = self.bundle['directions'][0]['quality_results']['candidate']['mt']['result']
        raw = (self.root / ref['path']).read_bytes()
        for mutate in mutations:
            self.bundle = copy.deepcopy(original)
            ref = self.bundle['directions'][0]['quality_results']['candidate']['mt']['result']
            (self.root / ref['path']).write_bytes(raw)
            self.change_json(ref, mutate)
            self.assertTrue(verify(self.bundle, self.root))

    def test_run_link_and_duplicate_sample_semantics(self):
        entry = self.bundle['directions'][0]
        refs = entry['quality_results']['baseline']['mt']
        path = self.root / refs['run']['path']
        records = [json.loads(line) for line in path.read_text().splitlines()]
        records[2]['sample_id'] = records[1]['sample_id']
        raw = ('\n'.join(json.dumps(r) for r in records) + '\n').encode()
        path.write_bytes(raw)
        refs['run']['sha256'] = hashlib.sha256(raw).hexdigest()
        self.change_json(refs['result'], lambda r: r.update(run_artifact_sha256='sha256:' + refs['run']['sha256']))
        self.assertTrue(verify(self.bundle, self.root))

    def test_blank_or_duplicate_human_rows_rejected(self):
        ref = self.bundle['directions'][0]['human_review']
        self.change_json(ref, lambda r: r['rows'][0].update(overall_preference='', reviewer_name=''))
        self.assertTrue(verify(self.bundle, self.root))

    def test_arbitrary_quality_bytes_no_longer_pass(self):
        self.bundle['directions'][0]['quality_results']['baseline']['mt']['result'] = self.ref
        self.assertTrue(verify(self.bundle, self.root))

    def test_missing_asr_result_or_expected_identity_rejected(self):
        del self.bundle['directions'][0]['quality_results']['candidate']['asr']
        self.assertTrue(verify(self.bundle, self.root))

    def test_human_text_must_match_blinded_run(self):
        ref = self.bundle['directions'][0]['human_review']
        self.change_json(ref, lambda r: r['rows'][0].update(A='different translation'))
        self.assertTrue(verify(self.bundle, self.root))

    def test_duplicate_completed_review_rows_rejected(self):
        ref = self.bundle['directions'][0]['human_review']
        self.change_json(ref, lambda r: r['rows'].__setitem__(1, r['rows'][0]))
        self.assertTrue(verify(self.bundle, self.root))

    def test_production_gate_rejects_complete_100_row_subset(self):
        with patch('gate.FLORES_DEVTEST_COUNT', 1012):
            errors = verify(self.bundle, self.root)
        self.assertTrue(any('full 1012-sample FLORES devtest required' in error for error in errors))

    def test_dev_result_rejected_even_with_matching_pinned_identity(self):
        entry = self.bundle['directions'][0]
        refs = entry['quality_results']['baseline']['mt']
        result = json.loads((self.root / refs['result']['path']).read_text())
        records = [json.loads(line) for line in (self.root / refs['run']['path']).read_text().splitlines()]
        expected = json.loads((self.root / self.bundle['baseline_manifest']['path']).read_text())['expectations'][entry['direction']]['mt']
        for value in (result, records[0], expected):
            value['definition_ref']['id'] = 'test.flores.dev.100.v1'
            value['identity']['definition_ref']['id'] = 'test.flores.dev.100.v1'
        with self.assertRaisesRegex(ValueError, 'FLORES devtest'):
            inspect_result(result, records, expected, 'mt')

    def test_complete_contract_and_inclusive_limits(self):
        self.assertEqual(verify(self.bundle, self.root), [])

    def test_missing_synthetic_and_simulator_evidence(self):
        for key, value in [('evidence_kind', 'synthetic'), ('simulator', True), ('device', 'Mac'), ('directions', [])]:
            bundle = copy.deepcopy(self.bundle)
            bundle[key] = value
            self.assertTrue(verify(bundle, self.root), key)

    def test_unmatched_samples_and_budget(self):
        for field, value in [('candidate_sample_sha256', 'different'), ('candidate_manifest_sha256', 'b' * 64), ('evidence_kind', 'synthetic')]:
            bundle = copy.deepcopy(self.bundle)
            bundle['directions'][0]['device_runs'][0][field] = value
            self.assertTrue(verify(bundle, self.root))
        for value in (2.01, float('nan'), float('inf'), -1, True):
            bundle = copy.deepcopy(self.bundle)
            bundle['directions'][0]['device_runs'][0]['candidate']['final_p95_s'] = value
            self.assertTrue(verify(bundle, self.root))

    def test_artifact_tampering_and_path_escape(self):
        self.bundle['source'] = {'path': '../outside', 'sha256': 'bad'}
        self.assertTrue(verify(self.bundle, self.root))
        self.bundle['source'] = self.ref
        (self.root / 'artifact').write_text('tampered')
        self.assertTrue(verify(self.bundle, self.root))

    def test_retained_baseline_requires_identical_profile_artifacts(self):
        self.bundle['directions'][0] = {'direction': sorted(DIRECTIONS)[0],
            'quality_decision': 'retained_baseline', 'baseline_profile': self.ref, 'selected_profile': self.ref}
        self.assertEqual(verify(self.bundle, self.root), [])
        changed = b'changed complete pipeline'
        (self.root / 'changed').write_bytes(changed)
        self.bundle['directions'][0]['selected_profile'] = {'path': 'changed', 'sha256': hashlib.sha256(changed).hexdigest()}
        self.assertTrue(verify(self.bundle, self.root))
        del self.bundle['directions'][0]['selected_profile']
        self.assertTrue(verify(self.bundle, self.root))

    def test_overlap_review_stress_and_duplicates(self):
        for mutate in [
            lambda b: b.update(heldout_sample_ids=['selection']),
            lambda b: b['directions'][0].update(blind_sample_count=99),
            lambda b: b['directions'][0]['stress'].update(duration_s=1799),
            lambda b: b['directions'][0]['stress'].update(memory_warnings=1),
            lambda b: b['directions'][0].update(speech_strata=['reading']),
            lambda b: b['directions'].__setitem__(0, b['directions'][1]),
        ]:
            bundle = copy.deepcopy(self.bundle)
            mutate(bundle)
            self.assertTrue(verify(bundle, self.root))

if __name__ == '__main__':
    unittest.main()
