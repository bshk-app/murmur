import unittest
from compare_dilation import score


class WordRecoveryTests(unittest.TestCase):
    def fixture(self, words):
        return {'width':100, 'height':100, 'annotations':[
            {'utf8_string':word, 'bbox':[10+index*40,10,10,10]} for index, word in enumerate(words)]}

    def result(self, text, bounds=(0,0,1,1)):
        return {'blocks':[{'source':text, 'bounds':bounds}]}

    def test_repeated_reference_is_not_double_counted(self):
        measured = score(self.fixture(['ONE','ONE']), self.result('one'))
        self.assertEqual((measured['matched'],measured['spatial_matched']), (1,1))

    def test_correct_word_in_wrong_place_only_matches_bag(self):
        measured = score(self.fixture(['ONE']), self.result('ONE', (.8,.8,.1,.1)))
        self.assertEqual((measured['matched'],measured['spatial_matched']), (1,0))

    def test_illegible_and_extra_tokens(self):
        measured = score(self.fixture(['.', 'Hello']), self.result('hello noise'))
        self.assertEqual(measured['reference'], 1)
        self.assertEqual(measured['unmatched_tokens'], ['noise'])

    def test_empty_detection_preserves_missing_words(self):
        measured = score(self.fixture(['Hello']), {'blocks':[]})
        self.assertEqual(measured['missing_tokens'], ['hello'])
        self.assertEqual(measured['spatial_matched'], 0)


if __name__ == '__main__':
    unittest.main()
