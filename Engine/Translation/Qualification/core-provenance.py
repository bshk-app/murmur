"""Capture actual locally installed Omni sources, including pre-existing edits."""
import hashlib,json,subprocess,zipfile
from pathlib import Path

def capture(core:Path,root:Path):
 files=sorted({core/'python/pyproject.toml',core/'python/uv.lock'}|set((core/'python/src/omni_bench').rglob('*.py'))|set((core/'schemas').glob('*.json'))|set((core/'fixtures/registry').rglob('*.json')))
 hashes={str(p.relative_to(core)):'sha256:'+hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
 digest=hashlib.sha256(json.dumps(hashes,sort_keys=True,separators=(',',':')).encode()).hexdigest()
 folder=root/'core-snapshots'/digest;folder.mkdir(parents=True,exist_ok=True)
 if not (folder/'sources.zip').exists():
  with zipfile.ZipFile(folder/'sources.zip','x') as archive:
   for p in files:
    info=zipfile.ZipInfo(str(p.relative_to(core)),date_time=(1980,1,1,0,0,0));info.compress_type=zipfile.ZIP_DEFLATED;archive.writestr(info,p.read_bytes())
  (folder/'manifest.json').write_text(json.dumps(hashes,sort_keys=True,indent=2)+'\n')
 return {'git_commit':subprocess.check_output(['git','-C',str(core),'rev-parse','HEAD'],text=True).strip(),'source_manifest_sha256':'sha256:'+digest,'snapshot':str(folder)}
