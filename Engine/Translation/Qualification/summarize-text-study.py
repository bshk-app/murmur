"""Summarize emitted Omni results without reimplementing any scoring metric."""
import argparse,json
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--study-id',default='first20-v2');a=p.parse_args()
root=Path('/Volumes/DATA/Murmur-models/opus-quality/runs')/a.study_id
rows=[]
for result_path in sorted(root.glob('*/*/*/result.json')):
 result=json.loads(result_path.read_text());pair,split,setting=result_path.parts[-4:-1]
 observations={o['metric_ref']['id']:o for o in result['observations']}
 def value(key,field='value'):
  o=observations.get(key,{})
  return o.get('value',{}).get(field) if o.get('status')=='measured' else None
 rows.append({'pair':pair,'split':split,'setting':setting,'status':result['status'],'samples':result['counts']['n_total'],'errors':result['counts']['n_error'],'chrf_pp':value('quality.translation_chrf_pp.v1'),'bleu':value('quality.translation_bleu.v1'),'latency_p50_s':value('latency.request_completion_s.v1','p50'),'peak_process_rss_gb':value('resources.peak_process_rss_gb.v1'),'result_path':str(result_path),'production_qualified':False})
baseline_directions=sorted({r['pair'] for r in rows if r['split']=='devtest' and r['setting']=='baseline-int8-beam1' and r['status']=='complete' and r['samples']==1012 and r['errors']==0})
(root/'summary.json').write_text(json.dumps({'study_id':a.study_id,'baseline_heldout_coverage':{'completed_directions':baseline_directions,'count':len(baseline_directions),'required_count':20},'runs':rows,'limitations':['Mac CPU prequalification only; iPhone budget not evaluated.','dev results tune settings; only full devtest is heldout.','No blinded human review, domain strata review or promotion.']},indent=2)+'\n')
report=['# OPUS text experiment progress','','Mac CPU prequalification only. Dev tunes settings; full devtest is heldout. No profile is production-qualified.','','| Pair | Split | Setting | N/errors | chrF++ | BLEU | p50 seconds |','|---|---|---|---:|---:|---:|---:|']
for r in rows:
 fmt=lambda x:f'{x:.3f}' if isinstance(x,(float,int)) else 'unavailable'
 report.append(f"| {r['pair']} | {r['split']} | {r['setting']} | {r['samples']}/{r['errors']} | {fmt(r['chrf_pp'])} | {fmt(r['bleu'])} | {fmt(r['latency_p50_s'])} |")
(root/'PROGRESS.md').write_text('\n'.join(report)+'\n')
print(f'{len(baseline_directions)}/20 current baseline heldout directions; {len(rows)} emitted runs; {sum(r["split"]=="devtest" for r in rows)} heldout runs. {root}/PROGRESS.md')
