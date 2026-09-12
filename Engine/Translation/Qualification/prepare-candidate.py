"""Prepare one pinned-card OPUS archive as INT8 or genuine float32 CT2.
Archive checksum is captured independently: card revision does not pin archive bytes.
Writes only new study packages; reserves >=2 GiB free space. No publication.
"""
import argparse,fcntl,hashlib,json,shutil,urllib.request,zipfile
from pathlib import Path
import ctranslate2
import yaml
ROOT=Path('/Volumes/DATA/Murmur-models/opus-quality')
def digest(p):
 h=hashlib.sha256()
 with p.open('rb') as f:
  for b in iter(lambda:f.read(1048576),b''):h.update(b)
 return h.hexdigest()
p=argparse.ArgumentParser();p.add_argument('--checkpoint',required=True);p.add_argument('--quantization',choices=['int8','float32'],required=True);p.add_argument('--source-dir',type=Path);a=p.parse_args()
ROOT.mkdir(parents=True,exist_ok=True)
conversion_lock=(ROOT/'conversion.lock').open('a');fcntl.flock(conversion_lock,fcntl.LOCK_EX)
data=json.loads(Path(__file__).with_name('opus-candidates.json').read_text());m=next(x for x in data['models'] if x['checkpoint']==a.checkpoint)
if 'bible' in a.checkpoint:raise ValueError('Bible-domain candidates require separate domain review')
key=a.checkpoint.split('/')[-1]+'-'+m['revision'][:12];work=ROOT/'models'/key;dest=work/a.quantization
if dest.exists():raise FileExistsError(f'Preserving existing output: {dest}')
existing=list((work/'source').rglob('decoder.yml')) if (work/'source').exists() else []
if a.source_dir is None and len(existing)==1 and (work/'int8/provenance.json').exists():a.source_dir=existing[0].parent
required_gib=3 if a.source_dir else 4
if shutil.disk_usage(ROOT).free < required_gib*1024**3:raise RuntimeError(f'Need >={required_gib} GiB free before source preparation/conversion; keep 2 GiB reserve')
work.mkdir(parents=True,exist_ok=True)
# Capture checkpoint default controls even when conversion consumes original archive.
metadata={}
for name in ['config.json','generation_config.json','tokenizer_config.json']:
 try:
  with urllib.request.urlopen(f'https://huggingface.co/{m["checkpoint"]}/raw/{m["revision"]}/{name}') as r:metadata[name]=json.load(r)
 except urllib.error.HTTPError as e:
  if e.code!=404:raise
(work/'checkpoint-controls.json').write_text(json.dumps(metadata,indent=2)+'\n')
archive_sha=None
if a.source_dir:source=a.source_dir
else:
 if not m['original_archive']:raise ValueError('No original archive in card; requires separate Transformers preparation')
 archive=work/'source.zip'
 if not archive.exists():
  with urllib.request.urlopen(m['original_archive']) as response,archive.open('xb') as output:
   while block:=response.read(1048576):
    if shutil.disk_usage(ROOT).free < 3*1024**3:raise RuntimeError('Stopped download before disk reserve exhausted')
    output.write(block)
 archive_sha=digest(archive)
 if (work/'int8/provenance.json').exists():
  expected=json.loads((work/'int8/provenance.json').read_text())['archive_sha256']
  if expected and expected!=archive_sha:raise ValueError('Original archive changed from captured checksum')
 unpacked=work/'source'
 with zipfile.ZipFile(archive) as z:
  if sum(i.file_size for i in z.infolist())+2*1024**3>shutil.disk_usage(ROOT).free:raise RuntimeError('Insufficient space for extraction with reserve')
  for item in z.infolist():
   if not (unpacked/item.filename).resolve().is_relative_to(unpacked.resolve()):raise ValueError('Unsafe archive member')
  z.extractall(unpacked)
 configs=list(unpacked.rglob('decoder.yml'))
 if len(configs)!=1:raise ValueError('Expected exactly one decoder.yml')
 source=configs[0].parent
if shutil.disk_usage(ROOT).free < 3*1024**3:raise RuntimeError('Need 3 GiB free before conversion')
source_hashes={str(f.relative_to(source)):digest(f) for f in sorted(source.rglob('*')) if f.is_file()}
if (work/'int8/provenance.json').exists():
 previous=json.loads((work/'int8/provenance.json').read_text())
 if source_hashes!=previous['source_files']:raise ValueError('Original source files differ from INT8 control')
 archive_sha=previous['archive_sha256']
for source_name in ['LICENSE','README.md','preprocess.sh','postprocess.sh']:
 if (source/source_name).exists():shutil.copyfile(source/source_name,work/('source-'+source_name))
source_license=(source/'LICENSE').read_text().splitlines()[0] if (source/'LICENSE').exists() else None
decoder_controls=yaml.safe_load((source/'decoder.yml').read_text())
(work/'original-decoder.json').write_text(json.dumps(decoder_controls,indent=2)+'\n')
ctranslate2.converters.OpusMTConverter(str(source)).convert(str(dest),quantization=a.quantization)
for name in ['source.spm','target.spm']:
 matches=list(source.rglob(name))
 if len(matches)!=1:raise ValueError(f'Expected exactly one {name}')
 shutil.copyfile(matches[0],dest/name)
provenance={'checkpoint':m['checkpoint'],'card_revision':m['revision'],'archive_url':m['original_archive'],'archive_sha256':archive_sha,'source_directory':str(source),'source_files':source_hashes,'original_decoder_controls':decoder_controls,'converter':'ctranslate2-'+ctranslate2.__version__,'quantization':a.quantization,'model_card_license':m['license'],'source_license_first_line':source_license,'target_tags':'per direction from audited catalog; no package-global tag','files':{f.name:digest(f) for f in sorted(dest.iterdir()) if f.is_file()},'status':'converted-not-quality-qualified'}
(dest/'provenance.json').write_text(json.dumps(provenance,indent=2)+'\n');print(dest)
