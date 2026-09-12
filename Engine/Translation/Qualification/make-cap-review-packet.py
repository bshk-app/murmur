"""Supplement fixed100 review with all additional recorded decoder-cap cases.
No semantic error is inferred from a cap flag, and no human review is fabricated.
"""
import argparse,csv,hashlib,json
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('packet_dir',type=Path);a=p.parse_args();folder=a.packet_dir
root=Path('/Volumes/DATA/Murmur-models/opus-quality')
key=json.loads((folder.parent/'assignment-keys'/(folder.name+'.json')).read_text())
fixed=json.loads((folder/'packet.json').read_text());selected={r['sample_id'] for r in fixed['rows']}
if (folder/'cap-cases.json').exists() or (folder/'cap-cases.csv').exists():print('Preserved existing supplemental review');raise SystemExit(0)
base_dir,candidate_dir=Path(key['baseline_path']),Path(key['candidate_path'])
def records(d):return [json.loads(l) for l in (d/'run-artifact.jsonl').read_text().splitlines()]
baseline_records,candidate_records=records(base_dir),records(candidate_dir)
header=baseline_records[0];task_id=header['definition_ref']['id'];bundle=None
for path in sorted((root/'prepared').glob(f'*/{task_id}/manifest.json')):
 manifest=json.loads(path.read_text())
 if manifest['dataset_content_sha256']==header['identity']['dataset_content_sha256']:bundle=path.parent;break
if bundle is None:raise FileNotFoundError('Missing content-pinned manifest')
source={r['sample_id']:r['payload']['prompt'] for r in manifest['samples']};refs={r['sample_id']:r['payload']['text'] for r in map(json.loads,(bundle/'references.jsonl').read_text().splitlines())}
base={r['sample_id']:r['evidence']['text'] for r in baseline_records if r['record_type']=='sample' and r['status']=='ok'};candidate={r['sample_id']:r['evidence']['text'] for r in candidate_records if r['record_type']=='sample' and r['status']=='ok'}
flags=set()
for d in [base_dir,candidate_dir]:
 if not (d/'decoding-diagnostics.json').exists():continue
 for row in json.loads((d/'decoding-diagnostics.json').read_text()):
  if any(s['reached_cap_without_eos'] for s in row['segments']):flags.add(row.get('sample_id') or manifest['samples'][row['request_index']-1]['sample_id'])
rows=[];assignments=[]
for index,sid in enumerate(sorted(flags),1):
 swap=hashlib.sha256((key['randomization_seed']+':assign:'+sid).encode()).digest()[0]%2==1
 row={'review_id':f"{key['direction']}-cap-{index:03}",'sample_id':sid,'also_in_fixed_packet':sid in selected,'reason':'At least one decoder segment reached its token cap without EOS; assess completeness and repetition.','source':source[sid],'reference':refs[sid],'A':candidate[sid] if swap else base[sid],'B':base[sid] if swap else candidate[sid]}
 for side in ['A','B']:
  for category in ['negation','numbers','names','omission','meaning']:row[f'{side}_{category}_error']=''
 row.update(overall_preference='',notes='',reviewer_name='',reviewed_at='');rows.append(row);assignments.append({'review_id':row['review_id'],'A':'candidate' if swap else 'baseline','B':'baseline' if swap else 'candidate'})
(folder/'cap-cases.json').write_text(json.dumps({'status':'awaiting-human-review' if rows else 'no-cap-cases','completed_reviews':0,'fixed_packet_overlap':len(flags&selected),'interpretation':'Supplemental failure-path review, not an unbiased sample. Python retained legacy capped output; native guard requires separate requalification.','rows':rows},ensure_ascii=False,indent=2)+'\n')
if rows:
 with (folder/'cap-cases.csv').open('w',newline='') as f:
  writer=csv.DictWriter(f,fieldnames=list(rows[0]));writer.writeheader()
  for row in rows:writer.writerow({k:("'"+v if isinstance(v,str) and v.lstrip().startswith(('=','+','-','@')) else v) for k,v in row.items()})
(folder.parent/'assignment-keys'/(folder.name+'-cap-cases.json')).write_text(json.dumps({'assignments':assignments},indent=2)+'\n')
print(f'{len(rows)} additional cap cases, all unreviewed; fixed100 packet unchanged.')
