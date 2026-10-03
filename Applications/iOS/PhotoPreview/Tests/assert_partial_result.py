"""Regression assertion for the real cd3f9f7c7ccf7552 no-dilation probe result."""
import json
import sys

result = json.load(open(sys.argv[1]))
blocks = result['blocks']
assert result['didOCR'] is True
assert len(blocks) == 21, 'Unexpected fixture transcription; inspect before changing expectations'
assert result.get('failedBlocks') == 1, 'The failed paragraph must be marked explicitly'
assert result['translatedBlocks'] == 20, 'Later blocks must continue after the failed paragraph'
assert blocks[8]['failed'] and not blocks[8]['translation']
assert all(block['translation'] and not block['failed'] for block in blocks[9:])
assert all(block.get('failed') or block['translation'] for block in blocks)
print('PASS: one marked failure, all 12 subsequent blocks translated')
