"""Detached one-off study supervisor; no app changes, promotion or publication.
Adopts existing process groups and resumes only after the entire group drains.
This is an ongoing batch job, not a recurring scheduled task.
"""
import argparse,datetime,fcntl,json,os,signal,subprocess,sys,time
from pathlib import Path
HERE=Path(__file__).parent;ROOT=Path('/Volumes/DATA/Murmur-models/opus-quality');STUDY='first20-v2'
p=argparse.ArgumentParser();p.add_argument('--candidate-pgid',type=int,required=True);p.add_argument('--baseline-pgid',type=int,required=True);a=p.parse_args()
signal.signal(signal.SIGHUP,signal.SIG_IGN)
lock=(ROOT/'supervisor.lock').open('a')
try:fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
except BlockingIOError:raise SystemExit('A study supervisor is already running')
(ROOT/'supervisor.pid').write_text(str(os.getpid())+'\n')
plan=json.loads((HERE/'first20-study-plan.json').read_text());indexed={r['pair']:r for r in plan['rows']}
def read(p):
 try:return json.loads(p.read_text())
 except (OSError,json.JSONDecodeError):return None
def complete(p):
 r=read(p);return bool(r and r.get('status')=='complete' and r.get('counts',{}).get('n_error')==0)
def alive(group):
 if not group:return False
 try:os.killpg(group,0);return True
 except ProcessLookupError:return False
 except PermissionError:return None

def baseline_done():
 for pair in indexed:
  selected=read(ROOT/'runs'/STUDY/'selections'/f'{pair}-baseline.json')
  if not selected:return False
  suffix='-sacremoses' if selected['normalization']=='sacremoses' else ''
  if not complete(ROOT/'runs'/STUDY/pair/'devtest'/f'baseline{suffix}-int8-beam{selected["beam"]}'/'result.json'):return False
 return True

def initial_done():
 for pair in plan['initial_pairs']:
  c=indexed[pair]['candidate'];key=c['checkpoint'].split('/')[-1]+'-'+c['revision'][:12]
  ready=read(ROOT/'models'/key/'cleanup-ready.json');paths=ready.get('result_paths',[]) if ready else []
  if not paths or not all('/'+STUDY+'/'+pair+'/' in p and complete(Path(p)) for p in paths):return False
 return True

def remaining_done():
 for pair in plan['follow_on_order']:
  c=indexed[pair]['candidate']
  if c is None:
   s=read(ROOT/'runs'/STUDY/'selections'/f'{pair}-baseline.json')
   if not s:return False
   suffix='-sacremoses' if s['normalization']=='sacremoses' else ''
   if not complete(ROOT/'runs'/STUDY/pair/'devtest'/f'baseline{suffix}-int8-beam{s["beam"]}'/'result.json'):return False
   continue
  key=c['checkpoint'].split('/')[-1]+'-'+c['revision'][:12]
  s=read(ROOT/'runs'/STUDY/'selections'/f'{pair}-candidate-{key}.json')
  if not s:return False
  suffix='-sacremoses' if s['normalization']=='sacremoses' else '';beam=s['beam']
  base=ROOT/'runs'/STUDY/pair
  integer=base/'devtest'/f'candidate-{key}-int8{suffix}-int8-beam{beam}'/'result.json'
  floating=base/'dev'/f'candidate-{key}-float32{suffix}-float32-beam{beam}'/'result.json'
  if not complete(integer) or not complete(floating):return False
  score=next(o['value']['value'] for o in read(floating)['observations'] if o['metric_ref']['id']=='quality.translation_chrf_pp.v1')
  if score>s['dev_chrf'] and not complete(base/'devtest'/f'candidate-{key}-float32{suffix}-float32-beam{beam}'/'result.json'):return False
 return True

def spawn(arguments,name):
 log=(ROOT/(name+'.log')).open('a')
 process=subprocess.Popen([sys.executable,*map(str,arguments)],stdin=subprocess.DEVNULL,stdout=log,stderr=subprocess.STDOUT,start_new_session=True,close_fds=True)
 log.close();return process
baseline={'pgid':a.baseline_pgid,'state':'adopted','attempts':0}
candidate={'pgid':a.candidate_pgid,'state':'adopted','attempts':0,'stage':'initial-eight'}
children=[];last_refresh=0
while True:
 for lane,done,args,label in [
  (baseline,baseline_done,[HERE/'run-follow-on.py','--baseline-only','--workers','2'],'baseline-supervised'),
  (candidate,initial_done if candidate['stage']=='initial-eight' else remaining_done,[HERE/'run-candidates.py'] if candidate['stage']=='initial-eight' else [HERE/'run-follow-on.py'],'candidate-supervised')]:
  if lane['state']=='attention-required':continue
  running=alive(lane['pgid'])
  if running is None:
   lane.update(state='attention-required',error='Cannot inspect the adopted process group; refusing to start a possibly duplicate worker')
   continue
  if running:continue
  if done():
   if lane is candidate and candidate['stage']=='initial-eight':
    candidate.update(stage='remaining-twelve',pgid=None,state='pending',attempts=0)
   else:lane.update(pgid=None,state='complete')
   continue
  if lane['state']=='complete':continue
  if lane['attempts']>=1:lane.update(pgid=None,state='attention-required');continue
  child=spawn(args,label);children.append(child);lane.update(pgid=child.pid,state='running',attempts=lane['attempts']+1)
 terminal=baseline['state'] in ['complete','attention-required'] and candidate['state'] in ['complete','attention-required']
 if time.monotonic()-last_refresh>=30 or terminal:
  with (ROOT/'report-supervisor.log').open('a') as log:
   subprocess.run([sys.executable,str(HERE/'summarize-text-study.py'),'--study-id',STUDY],stdout=log,stderr=subprocess.STDOUT)
   subprocess.run(['/opt/homebrew/bin/node',str(HERE/'first20-coverage.mjs'),STUDY],stdout=log,stderr=subprocess.STDOUT)
   for packet in (ROOT/'review'/STUDY).glob('*/packet.json'):
    if not (packet.parent/'cap-cases.json').exists():subprocess.run([sys.executable,str(HERE/'make-cap-review-packet.py'),str(packet.parent)],stdout=log,stderr=subprocess.STDOUT)
  status={'updated_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'supervisor_pid':os.getpid(),'baseline_tuning':baseline,'candidate_study':candidate,'promotion':'disabled; native and human gates pending'}
  temporary=ROOT/'supervisor-status.tmp';temporary.write_text(json.dumps(status,indent=2)+'\n');os.replace(temporary,ROOT/'supervisor-status.json');last_refresh=time.monotonic()
 for child in children:child.poll()
 if terminal:break
 time.sleep(5)
