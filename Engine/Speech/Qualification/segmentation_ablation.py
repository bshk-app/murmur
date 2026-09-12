"""Generate source-only ablations; score actual translations with stock Omni Bench.

Consumes real diagnostic attempt JSON files. No model inference, reference
construction, source rewriting or metric implementation is performed here.
"""
import argparse
import json
from pathlib import Path

CLOSERS = '\"\'”’»›」』)]}）】》'
TERMINALS = '.!?…。！？'


def sentence_terminal(text):
    end = text.rstrip()
    while end and end[-1] in CLOSERS:
        end = end[:-1].rstrip()
    return bool(end) and end[-1] in TERMINALS


def assemble(utterances, merge_sentences):
    ids = [u.get('id') for u in utterances]
    if not utterances or any(not isinstance(i, str) or not i for i in ids) or len(set(ids)) != len(ids):
        raise ValueError('nonempty unique string utterance IDs required')
    groups, pending = [], []
    for item in utterances:
        if not isinstance(item.get('text'), str):
            raise ValueError('verbatim source text required')
        start, end = item.get('startSample'), item.get('endSample')
        if type(start) is not int or type(end) is not int or not 0 <= start <= end:
            raise ValueError('valid source sample range required')
        pending.append(dict(item))
        if not merge_sentences or sentence_terminal(item['text']):
            groups.append(pending)
            pending = []
    if pending:
        groups.append(pending)
    result = []
    for index, group in enumerate(groups):
        text = ''
        for item in group:
            fragment = item['text']
            separator = ' ' if text and fragment and not text[-1].isspace() and not fragment[0].isspace() else ''
            text += separator + fragment
        result.append({'id': str(index), 'coveredIDs': [u['id'] for u in group],
                       'text': text, 'startSample': group[0]['startSample'], 'endSample': group[-1]['endSample'],
                       'fragments': group})
    assert [i for group in result for i in group['coveredIDs']] == ids
    return result


def prepare(row):
    if row.get('scenario') != 'dictation' or row.get('evidence_kind') != 'exploratory_device_observations':
        raise ValueError('real diagnostic speech attempt required')
    utterances = row.get('source_utterances')
    if not isinstance(utterances, list):
        raise ValueError('final source_utterances missing; rerun the updated device probe')
    return {'schema_version': 1, 'evidence_kind': 'source_only_ablation_inputs',
            'sample_id': row['sample_id'], 'source': row['source'], 'target': row['target'],
            'input_sha256': row.get('input_sha256'),
            'utterance': assemble(utterances, False), 'sentence': assemble(utterances, True),
            'quality_status': 'not_evaluated', 'target_references': None}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('attempts', type=Path, nargs='+')
    args = parser.parse_args()
    for path in args.attempts:
        result = prepare(json.loads(path.read_text()))
        print(json.dumps(result, ensure_ascii=False, sort_keys=True))


if __name__ == '__main__':
    main()
