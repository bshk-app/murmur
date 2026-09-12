"""Serial resumable schedule: no concurrent inference, no model promotion."""
import argparse,json,subprocess,sys
from itertools import permutations
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--phase',choices=['baseline-dev','tuning','baseline-heldout'],default='baseline-dev');p.add_argument('--study-id',default='first20-v2');a=p.parse_args()
root=Path('/Volumes/DATA/Murmur-models/opus-quality');runner=Path(__file__).with_name('run-text-study.py')
for source,target in permutations(['de','en','fi','fr','ru'],2):
 pair=source+'-'+target
 for beam in ([1] if a.phase!='tuning' else [4,8]):
  split='devtest' if a.phase=='baseline-heldout' else 'dev'
  out=root/'runs'/a.study_id/pair/split/f'baseline-int8-beam{beam}'
  if (out/'result.json').exists() and json.loads((out/'result.json').read_text())['status']=='complete':print('REUSE',pair,split,beam,flush=True);continue
  out.mkdir(parents=True,exist_ok=True)
  print('START',pair,split,beam,flush=True)
  with (out/'run.log').open('w') as log:
   r=subprocess.run([sys.executable,str(runner),'--pair',pair,'--split',split,'--beam',str(beam),'--study-id',a.study_id],stdout=log,stderr=subprocess.STDOUT)
  if r.returncode:raise RuntimeError(f'Failed: {out}/run.log')
  print('DONE',pair,split,beam,flush=True)
