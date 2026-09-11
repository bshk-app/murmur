import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
const root = 'Prototypes/iOS/build/opus-eu/distribution';
const sources=JSON.parse(fs.readFileSync('Engine/Translation/Catalog/eu-opus-sources.json'));
let swift='// Generated from verified OPUS conversions by Scripts/register-eu-opus.mjs.\n';
swift+='extension TranslationQualityDigests {\n    static let european: [String: Entry] = [\n';
const report=[];
for(const spec of sources){
 const dir=path.join(root,spec.from+'-'+spec.to);
 const entry=JSON.parse(fs.readFileSync(path.join(dir,'provenance.json')));
 if(entry.source_url!==spec.source_url || entry.target_tag!==spec.target_tag || (spec.hf_revision && entry.revision!==spec.hf_revision))throw Error(`Source mismatch: ${spec.pair}`);
 swift+=`        "${spec.pair}": Entry(files: [\n`;
 for(const [name,meta]of Object.entries(entry.files)){
  const file=path.join(dir,name), hash=crypto.createHash('sha256');
  for await(const chunk of fs.createReadStream(file))hash.update(chunk);
  if(hash.digest('hex')!==meta.sha256||fs.statSync(file).size!==meta.bytes)throw Error('Checksum failed: '+file);
  swift+=`            File(name: "${name}", sha256: "${meta.sha256}", bytes: ${meta.bytes}),\n`;
 }
 swift+='        ]),\n';
 report.push({pair:spec.pair,checkpoint:entry.checkpoint,source_sha256:entry.source_sha256,input:spec.sample_input,output:entry.sample_output,bytes:Object.values(entry.files).reduce((n,f)=>n+f.bytes,0)});
}
swift+='    ]\n}\n';
fs.writeFileSync('Engine/Translation/Sources/MurmurTranslation/EuropeanQualityDigests.swift',swift);
fs.writeFileSync('Engine/Translation/Catalog/eu-opus-verification.json',JSON.stringify(report,null,2)+'\n');
console.log(`Registered ${report.length} verified OPUS directions.`);
