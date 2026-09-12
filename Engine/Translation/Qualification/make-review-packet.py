"""Create blinded, unreviewed 100-item packets from complete heldout runs.
Assignment key is written separately and must not be given to reviewers.
"""
import argparse,csv,hashlib,json,secrets
from pathlib import Path
ROOT=Path('/Volumes/DATA/Murmur-models/opus-quality')
p=argparse.ArgumentParser();p.add_argument('--baseline',required=True,type=Path);p.add_argument('--candidate',required=True,type=Path);p.add_argument('--output',required=True,type=Path);a=p.parse_args()
def read_run(folder):
 result=json.loads((folder/'result.json').read_text())
 if result['status']!='complete' or result['counts']['n_total']!=1012 or result['counts']['n_error']!=0:raise ValueError('Require complete error-free full1012 heldout runs')
 records=[json.loads(l) for l in (folder/'run-artifact.jsonl').read_text().splitlines()]
 header=records[0]
 if '.devtest.' not in header['definition_ref']['id']:raise ValueError('Review packets require heldout devtest')
 return header,{r['sample_id']:r['evidence']['text'] for r in records if r['record_type']=='sample' and r['status']=='ok'}
base_header,base=read_run(a.baseline);candidate_header,candidate=read_run(a.candidate)
if base_header['identity']['dataset_content_sha256']!=candidate_header['identity']['dataset_content_sha256'] or base.keys()!=candidate.keys():raise ValueError('Runs do not share exact dataset/sample IDs')
task_id=base_header['definition_ref']['id'];bundle=None
for manifest_path in sorted((ROOT/'prepared').glob(f'*/{task_id}/manifest.json')):
 manifest=json.loads(manifest_path.read_text())
 if manifest['dataset_content_sha256']==base_header['identity']['dataset_content_sha256']:bundle=manifest_path.parent;break
if bundle is None:raise FileNotFoundError('No matching pinned preparation bundle')
source={r['sample_id']:r['payload']['prompt'] for r in manifest['samples']}
references={r['sample_id']:r['payload']['text'] for r in map(json.loads,(bundle/'references.jsonl').read_text().splitlines())}
pair=a.baseline.parts[-3]
seed=f'murmur-opus-blind-v1:{pair}:{base_header["identity"]["dataset_content_sha256"]}'
selected=sorted(base,key=lambda sid:hashlib.sha256((seed+':select:'+sid).encode()).hexdigest())[:100]
key=a.output.parent/'assignment-keys';key.mkdir(parents=True,exist_ok=True)
key_path=key/(a.output.name+'.json')
if key_path.exists():
 previous=json.loads(key_path.read_text())
 if previous['baseline_identity']!=base_header['identity'] or previous['candidate_identity']!=candidate_header['identity']:raise ValueError('Existing packet binds different profiles; choose a new output directory')
 if (a.output/'packet.json').exists() and (a.output/'packet.csv').exists():
  print(f'Preserved existing review packet and any human annotations: {a.output}');raise SystemExit(0)
 randomization_seed=previous['randomization_seed']
else:
 if (a.output/'packet.json').exists() or (a.output/'packet.csv').exists():raise FileExistsError('Packet without assignment key exists; refusing to overwrite review data')
 randomization_seed=secrets.token_hex(32)
rows=[];assignments=[]
for index,sid in enumerate(selected,1):
 swap=hashlib.sha256((randomization_seed+':assign:'+sid).encode()).digest()[0]%2==1
 row={'review_id':f'{pair}-{index:03}','sample_id':sid,'source':source[sid],'reference':references[sid],'A':candidate[sid] if swap else base[sid],'B':base[sid] if swap else candidate[sid]}
 for side in ['A','B']:
  for category in ['negation','numbers','names','omission','meaning']:row[f'{side}_{category}_error']=''
 row.update(overall_preference='',notes='',reviewer_name='',reviewed_at='')
 rows.append(row);assignments.append({'review_id':row['review_id'],'A':'candidate' if swap else 'baseline','B':'baseline' if swap else 'candidate'})
a.output.mkdir(parents=True,exist_ok=True)
(a.output/'packet.json').write_text(json.dumps({'direction':pair,'status':'awaiting-human-review','completed_reviews':0,'instructions':'Compare A and B against source and reference. Enter yes/no/uncertain for each error category, A/B/tie/uncertain for preference, reviewer name and date. An empty row is not a review.','rows':rows},ensure_ascii=False,indent=2)+'\n')
with (a.output/'packet.csv').open('w',newline='') as file:
 writer=csv.DictWriter(file,fieldnames=list(rows[0]));writer.writeheader()
 for row in rows:writer.writerow({key:("'"+value if isinstance(value,str) and value.lstrip().startswith(('=','+','-','@')) else value) for key,value in row.items()})
key_path.write_text(json.dumps({'randomization_seed':randomization_seed,'direction':pair,'baseline_identity':base_header['identity'],'candidate_identity':candidate_header['identity'],'baseline_path':str(a.baseline),'candidate_path':str(a.candidate),'assignments':assignments},indent=2)+'\n')
print(f'Created100 unreviewed blinded items at {a.output}; assignment key separately at {key}. No human approval recorded.')
