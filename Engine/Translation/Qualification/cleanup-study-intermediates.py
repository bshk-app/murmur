"""Reclaim only this study's reproducible intermediates after completed experiments.
Retains INT8 phone candidate, provenance and all inference/scoring artifacts.
"""
import argparse,json,subprocess
from pathlib import Path
ROOT=Path('/Volumes/DATA/Murmur-models/opus-quality/models').resolve()
p=argparse.ArgumentParser();p.add_argument('model_root',type=Path);a=p.parse_args();work=a.model_root.resolve()
if work.parent!=ROOT or not (work/'dev-selection.json').exists() or not (work/'int8/provenance.json').exists():raise ValueError('Not a completed study-created model root')
if not (work/'cleanup-ready.json').exists():raise ValueError('Runner has not recorded completed heldout and float runs')
for record in json.loads((work/'cleanup-ready.json').read_text())['result_paths']:
 if json.loads(Path(record).read_text())['status']!='complete':raise ValueError('Experiment incomplete')
if (work/'float32/provenance.json').exists():(work/'float32-provenance.json').write_bytes((work/'float32/provenance.json').read_bytes())
for name in ['source','source.zip','float32']:
 target=work/name
 if not target.exists():continue
 if not target.resolve().is_relative_to(work):raise ValueError('Refusing external path')
 # safe-rm skill mandates preview; inspect successful output before exact same target.
 preview=subprocess.run(['/Users/akira/.agents/skills/safe-rm/scripts/safe-rm.sh',str(target)],capture_output=True,text=True,check=True)
 print(preview.stdout,flush=True)
 if str(target) not in preview.stdout:raise ValueError('Deletion preview did not identify expected path')
 subprocess.run(['/Users/akira/.agents/skills/safe-rm/scripts/safe-rm.sh','--force',str(target)],check=True)
