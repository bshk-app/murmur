"""Complete first20 current-baseline heldout coverage with2 parallel hosts.
The direct-candidate queue occupies the third permitted CPU inference slot.
Each host has1 CT2 thread. Shared-machine CPU timing is exploratory.
"""
import argparse,json,subprocess,sys
from concurrent.futures import ThreadPoolExecutor,as_completed
from itertools import permutations
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--study-id',default='first20-v2');p.add_argument('--workers',type=int,choices=[1,2],default=2);p.add_argument('--skip',default='de-fi');a=p.parse_args()
root=Path('/Volumes/DATA/Murmur-models/opus-quality');runner=Path(__file__).with_name('run-text-study.py')
def run(pair):
 out=root/'runs'/a.study_id/pair/'devtest/baseline-int8-beam1'
 if (out/'result.json').exists() and json.loads((out/'result.json').read_text())['status']=='complete':return 'REUSE '+pair
 out.mkdir(parents=True,exist_ok=True)
 print('START',pair,flush=True)
 # Separate scheduler log avoids clobbering a candidate queue's launch log.
 with (out/'baseline-coverage.log').open('w') as log:r=subprocess.run([sys.executable,str(runner),'--pair',pair,'--split','devtest','--beam','1','--study-id',a.study_id],stdout=log,stderr=subprocess.STDOUT)
 if r.returncode:return 'FAILED '+pair+' '+str(out/'baseline-coverage.log')
 return 'DONE '+pair
pairs=['-'.join(p) for p in permutations(['de','en','fi','fr','ru'],2) if '-'.join(p) not in a.skip.split(',')]
with ThreadPoolExecutor(max_workers=a.workers) as pool:
 for future in as_completed([pool.submit(run,pair) for pair in pairs]):print(future.result(),flush=True)
