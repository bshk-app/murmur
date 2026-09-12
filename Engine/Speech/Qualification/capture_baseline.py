"""Capture source provenance only; deliberately does not claim measured quality."""
import hashlib
import json
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
FILES = [
    'Engine/Core/Sources/MurmurCore/SpeechModelChoice.swift',
    'Engine/Speech/Sources/MurmurSpeech/PhoneStreamingSession.swift',
    'Engine/Speech/Sources/MurmurSpeech/GigaAMCorrector.swift',
    'Engine/Speech/Sources/MurmurSpeech/PhoneIndependentCorrector.swift',
    'Engine/Speech/Sources/MurmurSpeech/PhoneMLXCorrector.swift',
]


def capture():
    sources = {}
    for name in FILES:
        raw = (ROOT / name).read_bytes()
        sources[name] = {'sha256': hashlib.sha256(raw).hexdigest(),
                         'declared_pins': dict(re.findall(r'static let (\w*(?:[Rr]epo|[Rr]evision)\w*) = "([^"]+)"', raw.decode()))}
    return {'schema_version': 1, 'evidence_kind': 'source_snapshot_only',
            'commit': subprocess.check_output(['git', '-C', str(ROOT), 'rev-parse', 'HEAD'], text=True).strip(),
            'working_tree_diff_sha256': hashlib.sha256(subprocess.check_output(['git', '-C', str(ROOT), 'diff', 'HEAD', '--', *FILES])).hexdigest(),
            'sources': sources,
            'measured_quality': None, 'measured_device_performance': None}

if __name__ == '__main__':
    print(json.dumps(capture(), indent=2, sort_keys=True))
