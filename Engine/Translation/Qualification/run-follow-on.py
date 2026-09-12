"""Resumable first20 follow-on. No model promotion or native-parity claim.
Baseline-only may occupy2 slots after full baseline coverage exits; distinct
candidate conversions/inference remain one serial slot after initial8 queue.
"""
import argparse,json,os,subprocess,sys,time
from concurrent.futures import ThreadPoolExecutor,as_completed
from pathlib import Path
HERE=Path(__file__).parent;ROOT=Path('/Volumes/DATA/Murmur-models/opus-quality')
p=argparse.ArgumentParser();p.add_argument('--study-id',default='first20-v2');p.add_argument('--baseline-only',action='store_true');p.add_argument('--workers',type=int,choices=[1,2],default=1);p.add_argument('--wait-pid',type=int);p.add_argument('--pairs',help='Comma-separated subset; baseline-only defaults to all20, candidate mode to remaining12');a=p.parse_args()
if not a.baseline_only and a.workers!=1:raise ValueError('Distinct candidate conversion stays serial for disk safety')
if a.wait_pid:
 while True:
  try:os.kill(a.wait_pid,0)
  except ProcessLookupError:break
  time.sleep(5)
plan=json.loads((HERE/'first20-study-plan.json').read_text());indexed={r['pair']:r for r in plan['rows']}
pairs=a.pairs.split(',') if a.pairs else list(indexed) if a.baseline_only else plan['follow_on_order']
for pair in pairs:
 if pair not in indexed:raise ValueError('Direction is outside first20: '+pair)
def read(p):return json.loads(p.read_text())
def complete(p):
 try:return read(p)['status']=='complete'
 except (FileNotFoundError,json.JSONDecodeError):return False
def invoke(arguments,log,python=None):
 log.parent.mkdir(parents=True,exist_ok=True)
 with log.open('w') as f:r=subprocess.run([python or sys.executable,*map(str,arguments)],stdout=f,stderr=subprocess.STDOUT)
 if r.returncode:raise RuntimeError(f'Failed; retained artifacts at {log}')
def experiment(pair,beam,*,split='dev',model=None,normalization='raw',compute='int8'):
 name='candidate-'+model.parent.name+'-'+model.name if model else 'baseline'
 if normalization!='raw':name+='-'+normalization
 out=ROOT/'runs'/a.study_id/pair/split/f'{name}-{compute}-beam{beam}'
 if not complete(out/'result.json'):
  print('RUN',pair,split,name,beam,flush=True)
  args=[HERE/'run-text-study.py','--pair',pair,'--beam',beam,'--split',split,'--normalization',normalization,'--compute',compute,'--study-id',a.study_id]
  if model:args+=['--model-dir',model]
  python=str(ROOT/'normalization-env/bin/python') if normalization=='sacremoses' else None
  invoke(args,out/'follow-on.log',python)
 result=read(out/'result.json')
 quality=next(o['value']['value'] for o in result['observations'] if o['metric_ref']['id']=='quality.translation_chrf_pp.v1')
 return {'chrf':quality,'beam':beam,'normalization':normalization,'path':out}
def choose(pair,model=None):
 trials=[experiment(pair,b,model=model) for b in [1,4,6,8]]
 raw=max(trials,key=lambda x:(x['chrf'],-x['beam']))
 normalized=experiment(pair,raw['beam'],model=model,normalization='sacremoses')
 return normalized if normalized['chrf']>raw['chrf'] else raw

def selection(pair,label,value):
 folder=ROOT/'runs'/a.study_id/'selections';folder.mkdir(parents=True,exist_ok=True)
 (folder/f'{pair}-{label}.json').write_text(json.dumps({'pair':pair,'selection_split':'dev','heldout_split':'devtest','beam':value['beam'],'normalization':value['normalization'],'dev_chrf':value['chrf'],'status':'provisional-not-approved','native_cap_guard_requalification':'required','human_review':'pending'},indent=2)+'\n')
def review(pair,current,selected,label):
 if current==selected:return
 output=ROOT/'review'/a.study_id/(pair+'-'+label)
 invoke([HERE/'make-review-packet.py','--baseline',current,'--candidate',selected,'--output',output],output.parent/(output.name+'-generation.log'))
 invoke([HERE/'make-cap-review-packet.py',output],output.parent/(output.name+'-cap-generation.log'))
def baseline(pair):
 winner=choose(pair);selection(pair,'baseline',winner)
 current=experiment(pair,1,split='devtest')['path']
 confirmed=experiment(pair,winner['beam'],split='devtest',normalization=winner['normalization'])['path']
 review(pair,current,confirmed,f'baseline-{winner["normalization"]}-beam{winner["beam"]}')
 return current,confirmed

def candidate(pair):
 current,tuned=baseline(pair);spec=indexed[pair]['candidate']
 if spec is None:print('DOMAIN SKIP',pair,indexed[pair]['candidate_skip_reason'],flush=True);return
 work=ROOT/'models'/(spec['checkpoint'].split('/')[-1]+'-'+spec['revision'][:12]);model=work/'int8'
 if not (model/'provenance.json').exists():invoke([HERE/'prepare-candidate.py','--checkpoint',spec['checkpoint'],'--quantization','int8'],work/'prepare-follow-on-int8.log')
 winner=choose(pair,model);selection(pair,'candidate-'+work.name,winner)
 # Freeze selection before candidate heldout; no adaptation from heldout scores.
 (work/'dev-selection.json').write_text(json.dumps({'pair':pair,'candidate_beam':winner['beam'],'candidate_normalization':winner['normalization'],'selection_split':'dev','status':'provisional-no-promotion'},indent=2)+'\n')
 confirmed=experiment(pair,winner['beam'],split='devtest',model=model,normalization=winner['normalization'])['path']
 review(pair,current,confirmed,work.name)
 floating=work/'float32'
 if not (floating/'provenance.json').exists():invoke([HERE/'prepare-candidate.py','--checkpoint',spec['checkpoint'],'--quantization','float32'],work/'prepare-follow-on-float32.log')
 control=experiment(pair,winner['beam'],model=floating,normalization=winner['normalization'],compute='float32')
 results=[current,tuned,confirmed,control['path']]
 if control['chrf']>winner['chrf']:
  floating_heldout=experiment(pair,winner['beam'],split='devtest',model=floating,normalization=winner['normalization'],compute='float32')['path']
  results.append(floating_heldout);review(pair,current,floating_heldout,work.name+'-float32')
 (work/'cleanup-ready.json').write_text(json.dumps({'result_paths':[str(x/'result.json') for x in results]},indent=2)+'\n')
 invoke([HERE/'cleanup-study-intermediates.py',work],work/'cleanup-follow-on.log')
 print('DONE',pair,'no promotion; native/human gates pending',flush=True)
if a.baseline_only:
 with ThreadPoolExecutor(max_workers=a.workers) as pool:
  futures={pool.submit(baseline,pair):pair for pair in pairs}
  for future in as_completed(futures):
   future.result();print('BASELINE TUNING DONE',futures[future],flush=True)
else:
 for pair in pairs:candidate(pair)
