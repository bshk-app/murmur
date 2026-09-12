"""One-process OPUS runner. Omni Bench owns preparation, artifacts and scoring.
Never promotes models. dev is tuning; devtest is full heldout evaluation.
"""
from __future__ import annotations
import argparse, copy, fcntl, hashlib, importlib.metadata, importlib.util, json, os, platform, re, subprocess, time
from pathlib import Path
import ctranslate2
import sentencepiece as spm
from omni_bench.registry import RegistryResolver, canonical_digest
from omni_bench.registry.resolver import semantic_projection
from omni_bench.preparation.content import build_dataset_content_descriptor, canonical_jsonl, sha256_file
from omni_bench.preparation.foundation import ContentPinnedTextPreparationAdapter, FoundationPreparationRuntime
from omni_bench.textgen import datasets
from omni_bench.core.adapter import Capabilities, Generation
from omni_bench.runtime import FoundationProducer
from omni_bench.scoring import ScoringRuntime, TextScoringAdapter
from omni_bench.core.validate import validate_document
CORE=Path('/Volumes/DATA/omni-bench')
ROOT=Path(os.environ.get('OPUS_STUDY_ROOT','/Volumes/DATA/Murmur-models/opus-quality'))
HERE=Path(__file__).parent
HOST_SOURCE=Path(__file__).read_bytes()
HOST_SHA='sha256:'+hashlib.sha256(HOST_SOURCE).hexdigest()
PREP_ID='local.prepare.murmur.opus.flores.v1'
def load(p): return json.loads(Path(p).read_text())
def write(p,v):
 p=Path(p);p.parent.mkdir(parents=True,exist_ok=True)
 temporary=p.with_name(p.name+f'.tmp-{os.getpid()}');temporary.write_text(json.dumps(v,ensure_ascii=False,indent=2,allow_nan=False)+'\n');os.replace(temporary,p)
class Preparation(ContentPinnedTextPreparationAdapter):
 implementation_id=PREP_ID
 source_sha256=HOST_SHA
 def __init__(self,records): self.records=records
 def prepare(self,task,*,out_dir,resolver):
  return self._prepare_text(task,out_dir=out_dir,resolver=resolver,expected_parameters=task.task['preparation']['parameters'],expected_records=len(self.records),records=self.records)
def catalog(pair,split,limit):
 source,target=pair.split('-')
 records=list(datasets.load_flores_plus_translation(source=datasets.FLORES_PLUS_ALL_LANGUAGES[source]['code'],target=datasets.FLORES_PLUS_ALL_LANGUAGES[target]['code'],source_short=source,target_short=target,split=split,revision=datasets.FLORES_PLUS_REVISION,limit=limit,verify_pins=split=='devtest',prompt_style='raw_source'))
 if split=='devtest' and len(records)!=datasets.FLORES_PLUS_EXPECTED_RECORDS: raise ValueError('Heldout must be full devtest')
 snapshot=load(CORE/'fixtures/registry/registry.snapshot.json');content=snapshot['content']
 indexed={i['ref']['id']:i for section in content.values() for i in section}
 tid=f'local.murmur.opus.flores.{pair}.{split}.{len(records)}.v1'
 task=copy.deepcopy(indexed['textgen.synthetic.translation.en-de.v1']['definition'])
 params={'dataset':datasets.FLORES_PLUS_ID,'recipe':{'id':'murmur.opus.flores.raw','version':'1.0.0'},'pins':{'revision':datasets.FLORES_PLUS_REVISION,'source':source,'target':target,'split':split,'ordered_sample_ids':[r.id for r in records]}}
 references=[{'record_type':'reference','sample_id':r.id,'payload':r.reference} for r in records]
 descriptor=build_dataset_content_descriptor(ordered_sample_ids=[r.id for r in records],prepared_samples=[{'sample_id':r.id,'payload':{'prompt':r.prompt,'prefix_group':r.prefix_group}} for r in records],prepared_audio=None,references_bytes=canonical_jsonl(references),preparation_recipe=params['recipe'],dataset_pins=params['pins'])
 schema=load(CORE/'fixtures/registry/schemas/content-pinned-preparation.schema.json')
 task.update(definition_id=tid,lifecycle='experimental',construct={'name':tid,'tags':['translation','qualification',split]},benchmark_card_sha256=HOST_SHA,dataset_content_sha256=canonical_digest(descriptor),protocol_sha256=canonical_digest({'raw_source':True,'split':split,'reference_access':False}),preparation={'implementation':{'implementation_id':PREP_ID,'source_sha256':HOST_SHA},'parameters_schema_ref':{'uri':schema['$id'],'sha256':canonical_digest(schema)},'parameters':params,'recipe_version':'1.0.0'})
 ref={'id':tid,'sha256':canonical_digest(semantic_projection('task_packages',task))}
 content['task_packages'].append({'ref':ref,'definition':task});snapshot['content_sha256']=canonical_digest(content)
 resolver=RegistryResolver(snapshot,registry_schema=load(CORE/'schemas/registry.schema.json'),schemas=[load(p) for p in sorted((CORE/'fixtures/registry/schemas').glob('*.schema.json'))])
 resolved=resolver.resolve_task(ref);bundle=ROOT/'prepared'/snapshot['content_sha256'].split(':')[1][:12]/tid
 bundle.parent.mkdir(parents=True,exist_ok=True)
 preparation_lock=(bundle.parent/'preparation.lock').open('a');fcntl.flock(preparation_lock,fcntl.LOCK_EX)
 write(bundle.parent/'registry.snapshot.json',snapshot);write(bundle.parent/'content.json',descriptor)
 if not (bundle/'manifest.json').exists(): FoundationPreparationRuntime(resolver,[Preparation(records)]).prepare(resolved,bundle)
 return resolver,resolved,bundle

def baseline(pair):
 roots={'ru-en':Path('/Volumes/DATA/bergamot-arm64/models/ct2-tcbig-ruen-int8'),'en-ru':Path('/Volumes/DATA/bergamot-arm64/models/ct2-tcbig-enru-int8')}
 roots.update({p:Path('/Volumes/DATA/Murmur/Prototypes/iOS/build/TranslationModels')/('ct2-'+p.replace('-','')) for p in ['en-fi','fi-en','ru-fi','fi-ru']})
 source,target=pair.split('-');pairs=[pair] if pair in roots or 'en' in pair.split('-') else [source+'-en','en-'+target]
 return [roots.get(p,Path('/Volumes/DATA/Murmur/Prototypes/iOS/build/opus-eu/distribution')/p) for p in pairs]
def split_sentences(line):
 pattern=r'[.!?…]["\'\)\]»”’]*(?=[\x00-\x20]|$)'
 start=0
 for match in re.finditer(pattern,line):
  piece=line[start:match.end()]
  if any(ord(c)>32 for c in piece):yield piece
  start=match.end()
  while start<len(line) and ord(line[start])<=32:start+=1
 if any(ord(c)>32 for c in line[start:]):yield line[start:]
class Host:
 def __init__(self,roots,beam,compute,pair,normalization):
  self.beam=beam;self.calls=0;self.models=[];self.diagnostics=[];self.normalization=normalization
  self.normalizers=[None]*len(roots)
  if normalization=='sacremoses':
   from sacremoses import MosesPunctNormalizer
   self.normalizers=[MosesPunctNormalizer(lang=pair.split('-')[0] if i==0 else 'en',perl_parity=True) for i in range(len(roots))]
  for root in roots:
   tag=root/'target_tag.txt'
   override=None
   if (root/'provenance.json').exists():
    checkpoint=load(root/'provenance.json').get('checkpoint')
    if checkpoint:
     audit=load(HERE/'opus-candidates.json')
     route=next((r for r in audit['matrix'] if r['from']+'-'+r['to']==pair),None)
     candidate=next((c for c in route['candidates'] if c['checkpoint']==checkpoint),None) if route else None
     if candidate and len(roots)==1:override=candidate['target_tag']
   self.models.append((ctranslate2.Translator(str(root),device='cpu',compute_type=compute,inter_threads=1,intra_threads=1),spm.SentencePieceProcessor(model_file=str(root/'source.spm')),spm.SentencePieceProcessor(model_file=str(root/'target.spm')),override if override is not None else tag.read_text().strip() if tag.exists() else '',load(root/'config.json')))
 def capabilities(self):return Capabilities()
 def reset_cache(self):pass
 def generate(self,prompt,*,task):
  text=prompt.prompt;tokens=0;segments=[];changed_lines=0
  for leg_index,(translator,source,target,tag,config) in enumerate(self.models):
   tokens=0;output=[]
   for line in text.split('\n'):
    normalizer=self.normalizers[leg_index]
    if normalizer:
     normalized=normalizer.normalize(normalizer.remove_control_chars(normalizer.replace_unicode_punct(line)))
     normalized=re.sub(' +',' ',normalized).strip(' ');changed_lines+=int(normalized!=line);line=normalized
    batch=[]
    for sentence in split_sentences(line):
     pieces=source.encode(sentence,out_type=str)
     for offset in range(0,len(pieces),200):batch.append(([tag] if tag else [])+pieces[offset:offset+200])
    result=translator.translate_batch(batch,beam_size=self.beam,max_decoding_length=512,max_batch_size=8,return_end_token=True) if batch else []
    decoded=[]
    for input_tokens,r in zip(batch,result,strict=True):
     pieces=r.hypotheses[0];ended=bool(pieces and pieces[-1]==config.get('eos_token','</s>'))
     segments.append({'leg':leg_index,'source_tokens_before_backend_eos':len(input_tokens),'backend_adds_source_eos':config.get('add_source_eos',False),'returned_tokens_including_eos':len(pieces),'ended_with_eos':ended,'reached_cap_without_eos':not ended and len(pieces)>=512})
     content=pieces[:-1] if ended else pieces;tokens+=len(content);decoded.append(target.decode(content))
    output.append(' '.join(decoded))
   text='\n'.join(output)
  self.calls+=1;self.diagnostics.append({'normalization':self.normalization,'changed_lines':changed_lines,'sample_id':prompt.id,'request_index':self.calls,'segments':segments,'final_generated_tokens_excluding_eos':tokens})
  if self.calls%25==0:print('progress',self.calls,flush=True)
  return Generation(text=text,generated_tokens=tokens)
def main():
 parser=argparse.ArgumentParser();parser.add_argument('--pair',required=True);parser.add_argument('--split',choices=['dev','devtest'],default='dev');parser.add_argument('--limit',type=int,default=100);parser.add_argument('--beam',type=int,choices=[1,4,6,8],default=1);parser.add_argument('--compute',choices=['int8','float32'],default='int8');parser.add_argument('--model-dir',type=Path);parser.add_argument('--normalization',choices=['raw','sacremoses'],default='raw');parser.add_argument('--study-id',default='first20-v2');args=parser.parse_args()
 if args.split=='devtest' and args.limit!=100: raise ValueError('--limit only controls dev; do not supply it for heldout')
 roots=[args.model_dir] if args.model_dir else baseline(args.pair)
 for root in roots:
  if not (root/'model.bin').exists():raise FileNotFoundError(root)
 if args.model_dir:
  proof=load(args.model_dir/'provenance.json')
  if proof.get('quantization')!=args.compute:raise ValueError('Requested compute must match documented original conversion quantization')
  row=next(r for r in load(HERE/'opus-candidates.json')['matrix'] if r['from']+'-'+r['to']==args.pair)
  if not any(c['checkpoint']==proof.get('checkpoint') for c in row['candidates']):raise ValueError('Candidate has no audited direction membership')
 # float32 execution of an INT8 pack is not an unquantized checkpoint control.
 if args.compute=='float32' and not args.model_dir:raise ValueError('Use separately converted original float32 pack for quantization control')
 spec=importlib.util.spec_from_file_location('murmur_core_provenance',HERE/'core-provenance.py');module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
 core_state=module.capture(CORE,ROOT)
 normalization={'mode':args.normalization}
 if args.normalization=='sacremoses':
  import sacremoses,inspect
  normalization.update(version=importlib.metadata.version('sacremoses'),source_sha256=sha256_file(Path(inspect.getfile(sacremoses.MosesPunctNormalizer))),perl_parity=True,steps=['replace_unicode_punct','remove_control_chars','normalize per source language','collapse ASCII spaces and trim'],placement='each line before sentence splitting; repeated per pivot leg',original_2020_moses_parity='not-verified')
 artifacts={'normalization':normalization,'libraries':{name:importlib.metadata.version(name) for name in ['ctranslate2','sentencepiece','numpy','sacrebleu','jsonschema']},'ctranslate2_default_signature':ctranslate2.Translator.translate_batch.__doc__.split('\n')[0],'omni_source_state':core_state,'host':HOST_SHA,'omni_commit':subprocess.check_output(['git','-C',str(CORE),'rev-parse','HEAD'],text=True).strip(),'beam':args.beam,'compute':args.compute,'max_input_tokens_per_segment':200,'max_output_tokens_per_segment':512,'max_output_tokens_per_request':16384,'models':[{p.name:sha256_file(p) for p in sorted(root.iterdir()) if p.is_file()} for root in roots]}
 resolver,task,bundle=catalog(args.pair,args.split,None if args.split=='devtest' else args.limit)
 name=('candidate-'+args.model_dir.parent.name+'-'+args.model_dir.name) if args.model_dir else 'baseline'
 if args.normalization!='raw':name+='-'+args.normalization
 out=ROOT/'runs'/args.study_id/args.pair/args.split/f'{name}-{args.compute}-beam{args.beam}'
 out.mkdir(parents=True,exist_ok=True)
 run_lock=(out/'inference.lock').open('a');fcntl.flock(run_lock,fcntl.LOCK_EX)
 if (out/'result.json').exists() and load(out/'result.json')['status']=='complete':
  old=load(out/'provenance.json')
  if any(old.get(k)!=artifacts.get(k) for k in ['models','beam','compute','max_input_tokens_per_segment','max_output_tokens_per_segment','max_output_tokens_per_request']):raise FileExistsError('Existing output has different model/decode settings; choose a new study ID')
  print(f'REUSE completed identical model/decode run: {out}',flush=True);return
 write(out/'provenance.json',artifacts)
 (out/'host-source.py').write_bytes(HOST_SOURCE)
 manifest=load(bundle/'manifest.json');host=Host(roots,args.beam,args.compute,args.pair,args.normalization)
 identity={'model':{'base_model_id':f'local.murmur.opus/{args.pair}/{name}','artifact_sha256':canonical_digest(artifacts),'quantization':args.compute},'backend':{'id':'ctranslate2.cpu','version':ctranslate2.__version__},'hardware':{'soc':'Apple M1 Max','accelerator':None,'mem_gb':32},'os':{'name':'macOS','version':platform.mac_ver()[0]},'implementation':'python-omni-opus-qualification','definition_ref':task.task_ref,'interface_family_ref':task.task['interface_family_ref'],'measurement_profile_ref':task.task['measurement_profile_refs'][0],'dataset_content_sha256':task.task['dataset_content_sha256'],'protocol_sha256':task.task['protocol_sha256'],'run_profile':{'delivery':'batch','chunk_ms':None,'warmup_samples':1,'concurrency':1,'family_parameters':{'min_output_tokens':0,'max_output_tokens':16384,'temperature':0,'top_p':1,'seed':0}},'measurement_environment':{'clock':'monotonic','rss_sampling_ms':10,'environment_label':'Shared Mac CPU, one thread per host; up to3 study workers; contention makes timings exploratory; not iPhone qualification; beam in hashed model provenance'}}
 records=FoundationProducer(resolver).run(task,manifest=manifest,adapter=host,identity=identity,bundle_root=bundle,out_path=out/'run-artifact.jsonl')
 profile=task.scoring_profile['scorer'];scorer=TextScoringAdapter(profile['implementation_id'],profile['source_sha256'],mode='translation')
 result=ScoringRuntime([scorer],schemas=resolver.schemas).score(task,manifest=manifest,references=[json.loads(l) for l in (bundle/'references.jsonl').read_text().splitlines()],artifact_records=records,bundle_root=bundle)
 write(out/'result.json',result);write(out/'decoding-diagnostics.json',host.diagnostics);validate_document(result,'result');print(json.dumps({'status':result['status'],'counts':result['counts'],'observations':result['observations'],'path':str(out)},ensure_ascii=False),flush=True)
 if result['status']!='complete':raise RuntimeError('Incomplete comparison; not eligible for selection')
if __name__=='__main__':main()
