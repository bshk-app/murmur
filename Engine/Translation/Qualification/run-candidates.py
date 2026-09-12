"""Serial direct-route study. Dev chooses provisional contenders; heldout never tunes.
No result changes app defaults. Human review/iPhone remain independent gates.
"""
import argparse,json,os,subprocess,sys,time
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--wait-pid',type=int);p.add_argument('--study-id',default='first20-v2');a=p.parse_args()
root=Path('/Volumes/DATA/Murmur-models/opus-quality');here=Path(__file__).parent
if a.wait_pid:
 while True:
  try:os.kill(a.wait_pid,0)
  except ProcessLookupError:break
  time.sleep(5)
def run(args,log,python=None):
 log.parent.mkdir(parents=True,exist_ok=True)
 with log.open('w') as f:r=subprocess.run([python or sys.executable,*map(str,args)],stdout=f,stderr=subprocess.STDOUT)
 if r.returncode:raise RuntimeError(f'Failed: {log}')
def experiment(pair,beam,split='dev',model=None,compute='int8',normalization='raw'):
 name='candidate-'+model.parent.name+'-'+model.name if model else 'baseline'
 if normalization!='raw':name+='-'+normalization
 out=root/'runs'/a.study_id/pair/split/f'{name}-{compute}-beam{beam}'
 if not (out/'result.json').exists() or json.loads((out/'result.json').read_text())['status']!='complete':
  print('RUN',pair,beam,split,name,compute,flush=True)
  args=[here/'run-text-study.py','--pair',pair,'--beam',beam,'--split',split,'--compute',compute,'--study-id',a.study_id]
  if model:args+=['--model-dir',model]
  args+=['--normalization',normalization]
  python=str(root/'normalization-env/bin/python') if normalization=='sacremoses' else None
  run(args,out/'run.log',python=python)
 result=json.loads((out/'result.json').read_text());quality=next(o['value']['value'] for o in result['observations'] if o['metric_ref']['id']=='quality.translation_chrf_pp.v1')
 return quality,out
plan=[('de-fi','de-fi'),('fi-de','fi-de'),('de-fr','de-fr'),('fr-de','fr-de'),('de-ru','tc-big-de-zle'),('ru-de','tc-big-zle-de'),('fr-ru','tc-big-fr-zle'),('ru-fr','tc-big-zle-fr')]
audit=json.loads((here/'opus-candidates.json').read_text())
for pair,short in plan:
 checkpoint='Helsinki-NLP/opus-mt-'+short;m=next(x for x in audit['models'] if x['checkpoint']==checkpoint)
 work=root/'models'/(checkpoint.split('/')[-1]+'-'+m['revision'][:12]);model=work/'int8'
 ready=work/'cleanup-ready.json'
 if ready.exists():
  paths=json.loads(ready.read_text()).get('result_paths',[])
  if paths and all('/'+a.study_id+'/'+pair+'/' in p and Path(p).exists() and json.loads(Path(p).read_text())['status']=='complete' for p in paths):
   print('REUSE COMPLETED DIRECTION',pair,flush=True);continue
 if not (model/'provenance.json').exists():
  print('PREPARE',checkpoint,flush=True)
  run([here/'prepare-candidate.py','--checkpoint',checkpoint,'--quantization','int8'],work/'prepare-int8.log')
 baseline=[(experiment(pair,b)[0],b) for b in [1,4,6,8]]
 candidates=[(experiment(pair,b,model=model)[0],b) for b in [1,4,6,8]]
 baseline_beam=max(baseline,key=lambda x:(x[0],-x[1]))[1];candidate_beam=max(candidates,key=lambda x:(x[0],-x[1]))[1]
 normalized_quality,_=experiment(pair,candidate_beam,model=model,normalization='sacremoses')
 candidate_normalization='sacremoses' if normalized_quality>max(candidates)[0] else 'raw'
 # Immutable provisional choice is written before candidate heldout execution.
 selection={'pair':pair,'selection_split':'dev','heldout_split':'devtest','baseline_beam':baseline_beam,'candidate_beam':candidate_beam,'candidate_checkpoint':checkpoint,'candidate_normalization':candidate_normalization,'normalization_choice_basis':'dev only at selected raw beam; ties prefer raw','status':'provisional-no-promotion','human_review':'pending','iphone':'pending'}
 (work/'dev-selection.json').write_text(json.dumps(selection,indent=2)+'\n')
 _,current_heldout=experiment(pair,1,split='devtest')
 _,baseline_heldout=experiment(pair,baseline_beam,split='devtest');_,candidate_heldout=experiment(pair,candidate_beam,split='devtest',model=model,normalization=candidate_normalization)
 review=root/'review'/a.study_id/(pair+'-'+work.name)
 run([here/'make-review-packet.py','--baseline',current_heldout,'--candidate',candidate_heldout,'--output',review],work/'review-packet.log')
 # Genuine original-weight float control; execute only after space preflight in preparer.
 floating=work/'float32'
 if not (floating/'provenance.json').exists():run([here/'prepare-candidate.py','--checkpoint',checkpoint,'--quantization','float32'],work/'prepare-float32.log')
 _,float_tuning=experiment(pair,candidate_beam,model=floating,compute='float32',normalization=candidate_normalization)
 (work/'cleanup-ready.json').write_text(json.dumps({'result_paths':[str(p/'result.json') for p in [current_heldout,baseline_heldout,candidate_heldout,float_tuning]]},indent=2)+'\n')
 run([here/'cleanup-study-intermediates.py',work],work/'cleanup.log')
 print('DONE',pair,'heldout and float tuning completed; no promotion',flush=True)
