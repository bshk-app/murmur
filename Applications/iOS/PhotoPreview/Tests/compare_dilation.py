"""Paired real-simulator comparison on the existing deterministic TextOCR smoke set.

This measures word-recovery proxies, not official TextOCR accuracy or CER/WER.
"""
import collections
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import unicodedata

def tokens(text):
    return re.findall(r'\w+', unicodedata.normalize('NFC', text).casefold())

def score(row, result):
    truth = []
    for annotation in row['annotations']:
        if annotation['utf8_string'] == '.':
            continue
        x, y, w, h = annotation['bbox']
        center = ((x+w/2)/row['width'], (y+h/2)/row['height'])
        truth.extend((word, center) for word in tokens(annotation['utf8_string']))
    predicted = [(word, block['bounds']) for block in result['blocks'] for word in tokens(block['source'])]
    gt = collections.Counter(word for word, _ in truth)
    pr = collections.Counter(word for word, _ in predicted)
    # Maximum matching: each occurrence is counted once, and must be near its region.
    edges = []
    for word, (cx, cy) in truth:
        edges.append([i for i, (candidate, (x,y,w,h)) in enumerate(predicted)
                      if word == candidate and x-.01 <= cx <= x+w+.01 and y-.01 <= cy <= y+h+.01])
    owners = {}
    def match(index, seen):
        for candidate in edges[index]:
            if candidate in seen:
                continue
            seen.add(candidate)
            if candidate not in owners or match(owners[candidate], seen):
                owners[candidate] = index
                return True
        return False
    spatial = sum(match(i, set()) for i in range(len(truth)))
    return dict(reference=len(truth), predicted=len(predicted), matched=sum((gt & pr).values()),
                spatial_matched=spatial, missing_tokens=list((gt-pr).elements()),
                unmatched_tokens=list((pr-gt).elements()))

def main():
    root = Path(__file__).resolve().parents[4]
    data = root / 'Prototypes/OCRBenchmark/data'
    out = Path(sys.argv[1]).resolve()
    out.mkdir(parents=True, exist_ok=True)
    manifest = json.loads((data / 'manifest.json').read_text())
    runner = Path(__file__).with_name('scene-smoke.rb')

    rows = []
    for index, row in enumerate(manifest['images']):
        image = data / row['file']
        assert hashlib.sha256(image.read_bytes()).hexdigest() == row['sha256']
        # Alternate order to reduce systematic warm-cache timing bias. No speed claim.
        variants = ['baseline', 'no-dilation'] if index % 2 == 0 else ['no-dilation', 'baseline']
        for variant in variants:
            destination = out / f"{row['id']}-{variant}.json"
            env = os.environ.copy()
            for key in ['PHOTO_PROBE_MAX_PIXELS','OCR_PROBE_UNCLIP','OCR_PROBE_REDETECT','OCR_PROBE_DETECTOR']:
                env.pop(key, None)
            env['OCR_PROBE_DILATE'] = '0' if variant == 'no-dilation' else ''
            if destination.exists():
                destination.unlink()
            process = subprocess.run(['ruby', str(runner), str(image), 'en', 'fi', '__batch_probe__', str(destination)],
                                     env=env, capture_output=True, text=True, timeout=150)
            if process.returncode not in (0,1) or not destination.exists():
                raise RuntimeError(process.stdout + process.stderr)
            result = json.loads(destination.read_text())
            measured = dict(id=row['id'], stratum=row['stratum'], variant=variant,
                            seconds=result['seconds'], error=result['error'], **score(row, result))
            rows.append(measured)
            print(json.dumps({k:v for k,v in measured.items() if k not in ['missing_tokens','unmatched_tokens']}), flush=True)
            (out / 'comparison.json').write_text(json.dumps({'rows':rows}, ensure_ascii=False, indent=2))
    summary = {}
    for variant in ['baseline', 'no-dilation']:
        selected = [row for row in rows if row['variant'] == variant]
        totals = {key:sum(row[key] for row in selected) for key in ['reference','predicted','matched','spatial_matched']}
        totals['recall_proxy'] = totals['matched']/totals['reference']
        totals['precision_proxy'] = totals['matched']/totals['predicted'] if totals['predicted'] else 0
        totals['errors'] = [row['id'] for row in selected if row['error']]
        summary[variant] = totals
    report = {'method':'NFC/casefold Unicode word tokens, per-image multiset overlap; spatial variant requires reference center within predicted block plus 1% margin. Unmatched tokens mix OCR errors, illegible/unannotated text and false detections. Not official accuracy.',
              'manifest_sha256':hashlib.sha256((data/'manifest.json').read_bytes()).hexdigest(), 'summary':summary,'rows':rows}
    (out / 'comparison.json').write_text(json.dumps(report, ensure_ascii=False, indent=2))
    print(json.dumps(summary, indent=2), flush=True)


if __name__ == "__main__":
    main()
