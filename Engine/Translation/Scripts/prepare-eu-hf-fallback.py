# /// script
# requires-python = ">=3.12"
# dependencies = ["ctranslate2==4.8.2", "numpy", "sentencepiece", "torch==2.8.0", "transformers==4.57.6", "sacremoses"]
# ///
"""Recover upstream archives unavailable to the Marian converter using pinned HF copies."""
from pathlib import Path
import hashlib, json, shutil, urllib.request
import ctranslate2
import sentencepiece as spm
from huggingface_hub import snapshot_download

REPO = Path(__file__).resolve().parents[3]
ROOT = REPO / "Prototypes/iOS/build/opus-eu"
OUT = ROOT / "distribution"
rows = json.loads((REPO / "Engine/Translation/Catalog/eu-opus-sources.json").read_text())

def digest(path):
    h=hashlib.sha256()
    with path.open('rb') as f:
        for data in iter(lambda:f.read(1024*1024),b''):h.update(data)
    return h.hexdigest()

# Other failed checkpoints can be named explicitly when rerunning this script.
import sys
models=sys.argv[1:] or ['Helsinki-NLP/opus-mt-en-ga','Helsinki-NLP/opus-mt-ga-en','Helsinki-NLP/opus-mt-en-zls']
for model in models:
    selected=[r for r in rows if r['checkpoint']==model]
    if not selected: raise ValueError(model)
    revision=selected[0].get('hf_revision')
    if not revision: raise ValueError('Pin hf_revision in eu-opus-sources.json before converting '+model)
    print('Downloading pinned HF checkpoint '+model+'@'+revision,flush=True)
    local=Path(snapshot_download(model,revision=revision,allow_patterns=['config.json','pytorch_model.bin','*.spm','vocab.json','tokenizer_config.json','generation_config.json']))
    work=ROOT/'hf-work'/model.split('/')[-1]
    work.parent.mkdir(parents=True,exist_ok=True)
    ctranslate2.converters.TransformersConverter(str(local)).convert(str(work),quantization='int8',force=True)
    # Native MurMur passes raw SentencePiece pieces. MarianTokenizer normally
    # appends EOS; reproduce that through CTranslate2's documented input option.
    config=json.loads((work/'config.json').read_text())
    config['add_source_eos']=True
    (work/'config.json').write_text(json.dumps(config,indent=2)+'\n')
    for name in ['source.spm','target.spm']:shutil.copyfile(local/name,work/name)
    source_sp=spm.SentencePieceProcessor(model_file=str(work/'source.spm'))
    target_sp=spm.SentencePieceProcessor(model_file=str(work/'target.spm'))
    engine=ctranslate2.Translator(str(work),device='cpu',compute_type='int8',intra_threads=1)
    for spec in selected:
        tag=spec['target_tag']
        if tag and not any(tag in json.loads(p.read_text()) for p in work.glob('*vocabulary.json')):raise ValueError('Missing target tag '+tag)
        tokens=source_sp.encode(spec['sample_input'],out_type=str)
        if tag:tokens.insert(0,tag)
        result=engine.translate_batch([tokens],beam_size=1,max_decoding_length=128)[0].hypotheses[0]
        text=target_sp.decode(result)
        if not text.strip() or text==spec['sample_input'] or len(text)>max(180,3*len(spec['sample_input'])):raise ValueError('Invalid smoke output '+text)
        dest=OUT/(spec['from']+'-'+spec['to']);dest.mkdir(parents=True,exist_ok=True)
        for file in work.iterdir():
            if file.is_file():shutil.copyfile(file,dest/file.name)
        if tag:(dest/'target_tag.txt').write_text(tag+'\n')
        meta={**spec,'source_sha256':digest(local/'pytorch_model.bin'),'source_format':'Hugging Face Transformers checkpoint',
            'converted_from':f'https://huggingface.co/{model}/tree/{revision}','revision':revision,
            'converter':'ctranslate2 4.8.2','quantization':'int8','attribution':'Helsinki-NLP / OPUS-MT',
            'license':spec['model_card_license'],'native_input_adapter':'add_source_eos=true to match MarianTokenizer with raw SentencePiece input','sample_output':text,
            'files':{p.name:{'sha256':digest(p),'bytes':p.stat().st_size} for p in dest.iterdir() if p.is_file() and p.name!='provenance.json'}}
        (dest/'provenance.json').write_text(json.dumps(meta,ensure_ascii=False,indent=2)+'\n')
        print('PASS '+spec['pair']+': '+text,flush=True)
    del engine
    shutil.rmtree(work)
