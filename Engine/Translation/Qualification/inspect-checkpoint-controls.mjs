import fs from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
const here=path.dirname(fileURLToPath(import.meta.url));
const audit=JSON.parse(await fs.readFile(path.join(here,'opus-candidates.json')));
const ids=new Set(audit.matrix.filter(r=>r.priority).flatMap(r=>r.baseline.legs.map(l=>l.checkpoint)));
for(const key of ['de-fi','fi-de','de-fr','fr-de','tc-big-de-zle','tc-big-zle-de','tc-big-fr-zle','tc-big-zle-fr'])ids.add('Helsinki-NLP/opus-mt-'+key);
const plan=JSON.parse(await fs.readFile(path.join(here,'first20-study-plan.json')));
for(const row of plan.rows)if(row.candidate)ids.add(row.candidate.checkpoint);
const output=[];
for(const id of [...ids].sort()) {
 const model=audit.models.find(m=>m.checkpoint===id);const configs={};
 for(const file of ['config.json','generation_config.json','tokenizer_config.json']) {
  const r=await fetch(`https://huggingface.co/${id}/raw/${model.revision}/${file}`);
  if(r.status===404)continue;if(!r.ok)throw Error(`${r.status} ${id}/${file}`);configs[file]=await r.json();
 }
 const effective={...configs['config.json'],...configs['generation_config.json']};
 output.push({checkpoint:id,revision:model.revision,configs,generation_controls:Object.fromEntries(['num_beams','max_length','min_length','length_penalty','early_stopping','no_repeat_ngram_size','repetition_penalty','decoder_start_token_id','forced_eos_token_id','bad_words_ids','pad_token_id','eos_token_id'].filter(k=>k in effective).map(k=>[k,effective[k]])),default_decode_parity:'not-tested',note:'HF generation defaults are recorded, not assumed numerically identical to CT2 settings.'});
}
await fs.writeFile(path.join(here,'checkpoint-controls.json'),JSON.stringify(output,null,2)+'\n');
console.log(`Pinned original generation/tokenization configs for ${output.length} checkpoints.`);
