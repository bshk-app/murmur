// Metadata audit only: never selects production defaults or claims conversion/quality.
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const output = path.dirname(fileURLToPath(import.meta.url));
const cache = process.env.OPUS_AUDIT_CACHE || '/Volumes/DATA/Murmur-models/opus-quality';
const languages = 'bg cs da de el en es et fi fr ga hr hu it lt lv mt nl pl pt ro ru sk sl sv uk'.split(' ');
const names = 'Bulgarian Czech Danish German Greek English Spanish Estonian Finnish French Irish Croatian Hungarian Italian Lithuanian Latvian Maltese Dutch Polish Portuguese Romanian Russian Slovak Slovenian Swedish Ukrainian'.split(' ');
const iso3 = 'bul ces dan deu ell eng spa est fin fra gle hrv hun ita lit lav mlt nld pol por ron rus slk slv swe ukr'.split(' ');
const aliases = Object.fromEntries(languages.map((l,i)=>[l,[l,iso3[i],names[i],...({de:['ger'],el:['gre'],fr:['fre'],nl:['dut'],ro:['rum'],sk:['slo'],cs:['cze']}[l]||[])]]));
await fs.mkdir(cache,{recursive:true});
async function request(url) {
 for(let attempt=0;attempt<5;attempt++) {
  try { const r=await fetch(url); if(r.ok) return r; if(r.status===404) return null; if(r.status!==429&&r.status<500) throw Error(`${r.status} ${url}`); }
  catch(e) { if(attempt===4) throw e; }
  await new Promise(r=>setTimeout(r,1000*2**attempt));
 }
 throw Error(`Retries exhausted: ${url}`);
}
let models=[], pages=0, url='https://huggingface.co/api/models?author=Helsinki-NLP&search=opus-mt&limit=100&full=true';
if(process.argv.includes('--cached')) { ({models,pages}=JSON.parse(await fs.readFile(path.join(cache,'inventory.json'),'utf8'))); }
else {
 const seen=new Set();
 while(url) { if(seen.has(url)) throw Error('Pagination loop'); seen.add(url); const r=await request(url); models.push(...await r.json()); pages++; url=r.headers.get('link')?.match(/<([^>]+)>;\s*rel="next"/)?.[1]||null; }
 await fs.writeFile(path.join(cache,'inventory.json'),JSON.stringify({pages,models}));
}
models=[...new Map(models.map(m=>[m.id,m])).values()].sort((a,b)=>a.id.localeCompare(b.id));
const results=[]; let cursor=0;
async function worker() { while(cursor<models.length) { const model=models[cursor++];
 const filename=path.join(cache,`${model.id.replaceAll('/','__')}__${model.sha}.md`);
 let card; try { card=await fs.readFile(filename,'utf8'); } catch { const r=await request(`https://huggingface.co/${model.id}/raw/${model.sha}/README.md`); card=r?await r.text():''; await fs.writeFile(filename,card); }
 const line=kind=>card.split('\n').find(l=>new RegExp(`^\\s*[*-]\\s*${kind} languages?(?:\\(s\\))?\\s*:`,'i').test(l))||'';
 const parse=l=>l.slice(l.indexOf(':')+1).replace(/[`\[\]]/g,'').split(/[\s,]+/).filter(Boolean);
 const source=line('source'), target=line('target'), sourceIDs=parse(source), targetIDs=parse(target);
 const required=/sentence.initial language (?:token|label) is required/i.test(card);
 const explicitTags=[...card.matchAll(/>>(\w+)<<|&gt;&gt;(\w+)&lt;&lt;/g)].map(m=>m[1]||m[2]);
 const files=(model.siblings||[]).map(s=>s.rfilename);
 const original=card.match(/https:\/\/object\.pouta\.csc\.fi\/[^\s)]+\.zip/)?.[0]||null;
 const license=card.match(/^license:\s*['"]?([^\n'"]+)/m)?.[1]?.trim()||model.tags?.find(t=>t.startsWith('license:'))?.slice(8)||null;
 const routes=[];
 for(const from of languages) for(const to of languages) {
  if(from===to||!aliases[from].some(a=>sourceIDs.includes(a))) continue;
  const targetID=aliases[to].find(a=>targetIDs.includes(a)); if(!targetID) continue;
  const tag=required?`>>${targetID}<<`:'';
  // Generic documented >>id<< plus exact target membership is explicit card evidence.
  const tagEvidence=required?(explicitTags.includes(targetID)?'explicit-label':/>>id<<|&gt;&gt;id&lt;&lt;/.test(card)?'documented-id-format-and-exact-target-membership':'missing'):'not-required';
  routes.push({from,to,target_tag:tag,target_tag_evidence:tagEvidence});
 }
 results.push({checkpoint:model.id,revision:model.sha,card_url:`https://huggingface.co/${model.id}/blob/${model.sha}/README.md`,license,source_evidence:source,target_evidence:target,source_ids:sourceIDs,target_ids:targetIDs,requires_target_tag:required,original_archive:original,conversion:{status:'not-tested',original_sentencepiece_archive_available:!!original&&/SentencePiece/i.test(card),transformers_files_present:['config.json','source.spm','target.spm','vocab.json'].every(f=>files.includes(f))&&files.some(f=>['pytorch_model.bin','model.safetensors'].includes(f))},routes});
 if(results.length%100===0) console.log(`Inspected ${results.length}/${models.length} cards`);
}}
await Promise.all(Array.from({length:6},worker)); results.sort((a,b)=>a.checkpoint.localeCompare(b.checkpoint));
const baseline=JSON.parse(await fs.readFile(path.join(output,'../Catalog/eu-opus-sources.json'),'utf8'));
for(const [from,to,checkpoint,target_tag] of [['en','ru','tc-big-en-zle','>>rus<<'],['ru','en','tc-big-zle-en',''],['en','fi','tc-big-en-fi',''],['fi','en','tc-big-fi-en',''],['ru','fi','tc-big-zle-fi',''],['fi','ru','tc-big-fi-zle','>>rus<<']]) baseline.push({from,to,checkpoint:`Helsinki-NLP/opus-mt-${checkpoint}`,target_tag});
const matrix=languages.flatMap(from=>languages.filter(to=>to!==from).map(to=>{
 const candidates=results.flatMap(m=>m.routes.filter(r=>r.from===from&&r.to===to).map(r=>({checkpoint:m.checkpoint,revision:m.revision,target_tag:r.target_tag,target_tag_evidence:r.target_tag_evidence,license:m.license,conversion_status:'not-tested'})));
 const direct=baseline.find(b=>b.from===from&&b.to===to);
 const legs=direct?[direct]:[baseline.find(b=>b.from===from&&b.to==='en'),baseline.find(b=>b.from==='en'&&b.to===to)];
 return {from,to,priority:['ru','en','fi','de','fr'].includes(from)&&['ru','en','fi','de','fr'].includes(to),baseline:{route:direct?'direct':'pivot-en',legs:legs.map(b=>b?{checkpoint:b.checkpoint,revision:results.find(m=>m.checkpoint===b.checkpoint)?.revision||null,target_tag:b.target_tag||''}:null),quality_status:'not-qualified'},candidates,selection_status:'baseline-retained-pending-qualification'};
}));
const summary={schema_version:1,languages,inventory_pages:pages,models_inspected:results.length,directions:matrix.length,directions_with_card_verified_candidates:matrix.filter(x=>x.candidates.length).length,priority_directions_with_candidates:matrix.filter(x=>x.priority&&x.candidates.length).length,limitations:['Pinned HF revision records metadata provenance, not the revision of pre-existing converted application weights.','Only Helsinki-NLP opus-mt repositories are covered.','Card membership does not establish translation quality or conversion compatibility.','No model is promoted by this metadata audit.','Archive links are upstream locations; archive bytes were not downloaded or hashed.']};
await fs.writeFile(path.join(output,'opus-candidates.json'),JSON.stringify({summary,models:results.filter(m=>m.routes.length),matrix},null,2)+'\n');
console.log(JSON.stringify(summary,null,2));
const nonBible=matrix.filter(r=>r.candidates.some(c=>!c.checkpoint.includes('bible'))).length;
const report=`# OPUS candidate metadata audit\n\nInspected ${results.length} repositories across ${pages} HF API pages, following every next link. ${results.filter(m=>m.routes.length).length} checkpoints have source and target membership evidence for the application's 26 languages. The matrix has ${matrix.length} directions; ${nonBible} have a non-Bible candidate. Bible-domain candidates are recorded for completeness, not recommended for general dictation.\n\n## First 20 directions\n\n| Direction | Baseline | Non-Bible direct candidates | Bible candidates |\n|---|---|---|---|\n${matrix.filter(r=>r.priority).map(r=>`| ${r.from} → ${r.to} | ${r.baseline.legs.map(l=>l.checkpoint.replace('Helsinki-NLP/opus-mt-','')).join(' → ')} | ${r.candidates.filter(c=>!c.checkpoint.includes('bible')).length} | ${r.candidates.filter(c=>c.checkpoint.includes('bible')).length} |`).join('\n')}\n\n## Interpretation and reproducibility\n\nRun \`node Engine/Translation/Qualification/discover-opus.mjs\` for a fresh paginated inventory; use \`--cached\` to regenerate against the saved inventory and revision-keyed cards. Set OPUS_AUDIT_CACHE to relocate metadata storage. No weights are downloaded. The JSON includes exact source/target card lines, license, revision, archive location, file availability, and target tag evidence. Generic documented \`>>id<<\` is accepted only with exact target-language membership; language groups are never expanded from checkpoint names.\n\nBaseline routes come from the existing EU catalog and six RU/EN/FI tc-big conversions. HF revisions in this audit pin inspected metadata, not the previously converted application weights; those remain identified by the shipped SHA-256 digests. Conversion availability is a file/card preflight, and conversion status remains not-tested. Quality, latency, INT8 parity, device resource use and human review are not measured by discovery. No candidates are selected or promoted. FR→FI has only Bible-domain direct candidates in this inventory; pivot must remain until comparative qualification.\n\n## Benchmark integration references\n\nOmni Bench skill: /Volumes/DATA/omni-bench/.claude/skills/omni-bench/SKILL.md (also .agents/skills/omni-bench/SKILL.md). Hosts own inference; Omni Bench owns scoring and artifacts. Use its prepare → run → score → diff pipeline and record model revision, backend, hardware and decode parameters. Never reimplement BLEU/chrF or WER/CER inside this discovery script.\n`;
await fs.writeFile(path.join(output,'CANDIDATE-AUDIT.md'),report);
