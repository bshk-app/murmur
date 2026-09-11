# /// script
# requires-python = ">=3.12"
# dependencies = ["ctranslate2==4.8.2", "numpy", "sentencepiece", "pyyaml"]
# ///
"""Convert the pinned EU source selection; verify and smoke-test every direction."""
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
import gc, hashlib, json, shutil, time, urllib.request, zipfile
import ctranslate2
import sentencepiece as spm

REPO = Path(__file__).resolve().parents[3]
SOURCES = json.loads((REPO / "Engine/Translation/Catalog/eu-opus-sources.json").read_text())
ROOT = REPO / "Prototypes/iOS/build/opus-eu"
OUT = ROOT / "distribution"

def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024*1024), b""): h.update(chunk)
    return h.hexdigest()

def verified(folder, spec):
    try:
        info = json.loads((folder / "provenance.json").read_text())
        if info["target_tag"] != spec["target_tag"] or info["source_url"] != spec["source_url"]: return False
        return all((folder/name).stat().st_size == meta["bytes"] and digest(folder/name) == meta["sha256"] for name,meta in info["files"].items())
    except (OSError, ValueError, KeyError): return False

def process(rows):
    if all(verified(OUT / f'{r["from"]}-{r["to"]}', r) for r in rows):
        print("Reverified " + ",".join(r["pair"] for r in rows), flush=True)
        return
    url = rows[0]["source_url"]
    key = hashlib.sha256(url.encode()).hexdigest()[:16]
    work = ROOT / "work" / key
    work.mkdir(parents=True, exist_ok=True)
    archive = work / "source.zip"
    if not archive.exists() or not zipfile.is_zipfile(archive):
        for attempt in range(3):
            try:
                print("Downloading " + rows[0]["checkpoint"], flush=True)
                with urllib.request.urlopen(url, timeout=120) as src, archive.open("wb") as dst: shutil.copyfileobj(src,dst,1024*1024)
                if not zipfile.is_zipfile(archive): raise ValueError("Invalid archive")
                break
            except Exception:
                if attempt == 2: raise
                time.sleep(2)
    source_sha = digest(archive)
    unpacked = work / "source"
    unpacked.mkdir(exist_ok=True)
    with zipfile.ZipFile(archive) as package:
        for m in package.infolist():
            if not (unpacked/m.filename).resolve().is_relative_to(unpacked.resolve()): raise ValueError("Unsafe archive path")
        package.extractall(unpacked)
    configs = list(unpacked.rglob("decoder.yml"))
    if len(configs) != 1: raise ValueError(f"Decoder config count {len(configs)}")
    source = configs[0].parent
    converted = work / "converted"
    if converted.exists(): shutil.rmtree(converted)
    print("Converting " + rows[0]["checkpoint"], flush=True)
    ctranslate2.converters.OpusMTConverter(str(source)).convert(str(converted), quantization="int8")
    for name in ["source.spm", "target.spm"]:
        files = list(source.rglob(name))
        if len(files)!=1: raise ValueError(f"Missing {name}: {[p.name for p in source.iterdir()]}")
        shutil.copyfile(files[0],converted/name)
    srcsp = spm.SentencePieceProcessor(model_file=str(converted/"source.spm"))
    tgtsp = spm.SentencePieceProcessor(model_file=str(converted/"target.spm"))
    engine = ctranslate2.Translator(str(converted),device="cpu",compute_type="int8",inter_threads=1,intra_threads=1)
    for row in rows:
        destination = OUT / f'{row["from"]}-{row["to"]}'
        destination.mkdir(parents=True, exist_ok=True)
        tag = row["target_tag"]
        if tag and not any(tag in json.loads(p.read_text()) for p in converted.glob("*vocabulary.json")): raise ValueError(f"Missing vocabulary tag {tag}")
        pieces = srcsp.encode(row["sample_input"],out_type=str)
        if tag: pieces.insert(0,tag)
        result = engine.translate_batch([pieces],beam_size=1,max_decoding_length=128)[0].hypotheses[0]
        output = tgtsp.decode([x for x in result if not x.startswith(">>")])
        if not output.strip() or output == row["sample_input"] or len(output)>max(180,3*len(row["sample_input"])): raise ValueError(f"Invalid translation: {row['pair']} {output}")
        for file in converted.iterdir():
            if file.is_file(): shutil.copyfile(file,destination/file.name)
        if tag: (destination/"target_tag.txt").write_text(tag+"\n")
        meta = {**row,"source_sha256":source_sha,"attribution":"Helsinki-NLP / OPUS-MT", "source_license":"CC-BY-4.0 (original OPUS/Tatoeba weights)","converter":"ctranslate2 4.8.2", "quantization":"int8","sample_output":output,
            "files":{p.name:{"sha256":digest(p),"bytes":p.stat().st_size} for p in destination.iterdir() if p.is_file() and p.name!='provenance.json'}}
        (destination/"provenance.json").write_text(json.dumps(meta,ensure_ascii=False,indent=2)+"\n")
        print(f"PASS {row['pair']}: {output}",flush=True)
    del engine
    gc.collect()
    # Only this script's scratch directory; provenance retains the source hash.
    shutil.rmtree(work)

if __name__ == '__main__':
    OUT.mkdir(parents=True,exist_ok=True)
    grouped = {}
    for row in SOURCES: grouped.setdefault(row['source_url'],[]).append(row)
    failures = []
    with ThreadPoolExecutor(max_workers=2) as pool:
        jobs={pool.submit(process,rows):rows for rows in grouped.values()}
        for job in as_completed(jobs):
            try: job.result()
            except Exception as error:
                pairs=','.join(r['pair'] for r in jobs[job]); failures.append({'pairs':pairs,'error':str(error)})
                print(f'FAIL {pairs}: {error}',flush=True)
    (ROOT/'failures.json').write_text(json.dumps(failures,indent=2))
    if failures: raise SystemExit(1)
    print(f'Verified {len(SOURCES)} EU/UK directions.',flush=True)
