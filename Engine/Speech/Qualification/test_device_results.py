import json
import tempfile
import unittest
from pathlib import Path
from device_results import summarize, compare, percentile


class DeviceResultsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.left, self.right = self.root / 'left', self.root / 'right'
        self.left.mkdir(); self.right.mkdir()
        for root in (self.left, self.right):
            (root / 'build-source.json').write_text(json.dumps({'source_sha256': 'a' * 64}))
            for i in range(3):
                row = {'sample_id': 'real-fixture', 'input_sha256': 'b' * 64, 'repeat_id': i, 'stress_cycle': 0,
                       'source': 'en', 'target': 'de', 'scenario': 'text', 'device': 'iPhone16,1',
                       'evidence_kind': 'exploratory_device_observations', 'status': 'succeeded',
                       'translation_profile': {'test': 'profile'}, 'timing_contract': 'same',
                       'final_seconds': i + 1, 'cold_load_seconds': .2}
                (root / f'attempt-{i:06d}.json').write_text(json.dumps(row))
                (root / f'attempt-{i:06d}-telemetry.jsonl').write_text(json.dumps({'process_footprint_bytes': 100 + i, 'memory_warnings': 0}) + '\n')

    def edit(self, **changes):
        path = self.right / 'attempt-000000.json'
        row = json.loads(path.read_text()); row.update(changes); path.write_text(json.dumps(row))

    def test_nearest_rank_and_matched_comparison(self):
        self.assertEqual(percentile([4, 1, 3, 2], .5), 2)
        self.assertEqual(percentile([4, 1, 3, 2], .95), 4)
        self.assertIsNone(percentile([], .95))
        summary = summarize(self.left)
        self.assertEqual(summary['groups'][0]['timings']['final_seconds']['p95'], 3)
        result = compare(summary, summarize(self.right))['comparisons'][0]
        self.assertTrue(result['matched'])
        self.assertFalse(result['release_gate_eligible'])
        self.assertEqual(result['ratios']['final_p95_candidate_over_baseline'], 1)
        self.assertTrue(all(len(ref['sha256']) == 64 for ref in summary['artifacts']))

    def test_incomplete_attempt_excluded_and_not_matchable(self):
        self.edit(status='started', final_seconds=None)
        summary = summarize(self.right)
        self.assertEqual(summary['groups'][0]['failed_or_incomplete_attempt_count'], 1)
        self.assertEqual(summary['groups'][0]['timings']['final_seconds']['count'], 2)
        self.assertFalse(compare(summarize(self.left), summary)['comparisons'][0]['matched'])

    def test_nonmatching_sample_identity(self):
        self.edit(input_sha256='c' * 64)
        result = compare(summarize(self.left), summarize(self.right))['comparisons'][0]
        self.assertIn('unmatched_or_duplicate_sample_repeat_identity', result['problems'])
        self.assertIsNone(result['ratios'])

    def test_contracts_not_mixed(self):
        for path in self.right.glob('attempt-*.json'):
            row = json.loads(path.read_text()); row.update(speech_pipeline='sequential', timing_contract='batch_not_streaming')
            path.write_text(json.dumps(row))
        self.assertEqual(compare(summarize(self.left), summarize(self.right))['status'], 'no_identical_timing_contracts')

    def test_missing_telemetry_cold_and_failures(self):
        (self.right / 'attempt-000000-telemetry.jsonl').unlink()
        self.edit(status='failed', cold_load_seconds=None)
        group = summarize(self.right)['groups'][0]
        self.assertIsNone(group['memory_warning_count'])
        self.assertFalse(group['measurement_complete'])
        self.assertIn('missing_telemetry', group['attempts'][0]['problems'])
        self.assertIn('unavailable_complete_cold_load', group['attempts'][0]['problems'])

    def test_duplicate_repeat_and_missing_provenance(self):
        self.edit(repeat_id=1)
        (self.right / 'build-source.json').unlink()
        comparison = compare(summarize(self.left), summarize(self.right))['comparisons'][0]
        self.assertFalse(comparison['matched'])
        self.assertIn('incomplete_measurements', comparison['problems'])

if __name__ == '__main__': unittest.main()
