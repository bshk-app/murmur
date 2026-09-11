// Physical Voice Memos test: after selecting MurMur in Share, run this check.
// Only metadata counts/statuses are reported; no filename, audio or transcript.
import {spawnSync} from 'node:child_process';
import fs from 'node:fs';
const output='/tmp/murmur-shared-audio-arrival.json';
const result=spawnSync('xcrun',['devicectl','device','info','files','--device','alex-iphone15pro','--domain-type','appDataContainer','--domain-identifier','app.bshk.murmur.ios','--subdirectory','Library/Application Support/MurMur/AudioImports','--json-output',output],{encoding:'utf8'});
if(result.status!==0){console.error('Device file inspection failed; unlock the phone.');process.exit(2);}
const data=JSON.parse(fs.readFileSync(output));
const files=data.result?.files ?? [];
const jobs=files.map(x=>x.relativePath).filter(x=>typeof x==='string' && x.endsWith('/job.json'));
const snapshotIndex=process.argv.indexOf('--snapshot');
if(snapshotIndex>=0){fs.writeFileSync(process.argv[snapshotIndex+1],JSON.stringify(jobs));console.log('Saved baseline import IDs.');process.exit(0);}
const afterIndex=process.argv.indexOf('--after');
const baseline=afterIndex>=0 ? JSON.parse(fs.readFileSync(process.argv[afterIndex+1])) : [];
const hasJob=jobs.some(x=>!baseline.includes(x));
console.log(hasJob?'PASS: shared audio reached a durable import job.':'FAIL: no shared audio import job arrived.');
process.exit(hasJob?0:1);
