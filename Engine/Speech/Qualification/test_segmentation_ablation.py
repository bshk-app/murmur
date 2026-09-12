import unittest
from segmentation_ablation import assemble, prepare


class AssemblyTests(unittest.TestCase):
    def source(self, texts):
        return [{'id': str(2**63 + i), 'text': t, 'startSample': i * 16000, 'endSample': (i + 1) * 16000} for i, t in enumerate(texts)]

    def test_preserves_all_ids_order_and_verbatim_fragments(self):
        source = self.source(['Я передам', '  документы завтра.  ', 'А затем', ' проверю'])
        for merge in (False, True):
            groups = assemble(source, merge)
            self.assertEqual([i for g in groups for i in g['coveredIDs']], [s['id'] for s in source])
            self.assertEqual([s for g in groups for s in g['fragments']], source)
        self.assertEqual([g['text'] for g in assemble(source, True)], ['Я передам  документы завтра.  ', 'А затем проверю'])

    def test_unicode_quotes_and_trailing_incomplete(self):
        source = self.source(['Hän sanoi:', '”Huomenna!”', '次は', '「完了。」', 'ещё не'])
        self.assertEqual([g['text'] for g in assemble(source, True)], ['Hän sanoi: ”Huomenna!”', '次は 「完了。」', 'ещё не'])

    def test_rejects_duplicate_or_numeric_ids(self):
        source = self.source(['a', 'b'])
        source[1]['id'] = source[0]['id']
        with self.assertRaises(ValueError): assemble(source, True)
        source[1]['id'] = 42
        with self.assertRaises(ValueError): assemble(source, False)

    def test_no_silent_loss_of_empty_fragment(self):
        source = self.source(['', 'One.', '', 'unfinished'])
        groups = assemble(source, True)
        self.assertEqual(sum(len(g['coveredIDs']) for g in groups), 4)
        self.assertEqual([s for g in groups for s in g['fragments']], source)

    def test_missing_real_source_rejected(self):
        with self.assertRaises(ValueError): prepare({'scenario': 'dictation', 'evidence_kind': 'synthetic'})
        with self.assertRaises(ValueError): prepare({'scenario': 'dictation', 'evidence_kind': 'exploratory_device_observations'})

if __name__ == '__main__': unittest.main()
