#!/usr/bin/env node
// A continuous fixed-duration public read-speech replay, not spontaneous speech.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';

const [corpus, output, language = 'ru', durationString = '1800'] = process.argv.slice(2);
if (!corpus || !output) throw Error('usage: prepare-endurance-fixture.mjs CORPUS OUTPUT_DIRECTORY LANGUAGE SECONDS');
const seconds = Number(durationString);
if (!Number.isFinite(seconds) || seconds < 1 || seconds > 7200) throw Error('invalid duration');
const manifestBytes = fs.readFileSync(path.join(corpus, 'manifest.json'));
const manifest = JSON.parse(manifestBytes);
const sha = value => crypto.createHash('sha256').update(value).digest('hex');
const seed = 'murmur-opus-endurance-v1';
const clips = manifest.clips.filter(c => c.language === language).sort((a,b) => sha(seed+a.wavSHA256).localeCompare(sha(seed+b.wavSHA256)));
if (!clips.length) throw Error('no language fixtures');
function pcm(file) {
  const bytes = fs.readFileSync(file);
  if (bytes.toString('ascii',0,4) !== 'RIFF' || bytes.toString('ascii',8,12) !== 'WAVE') throw Error('not RIFF WAVE');
  let samples, valid = false;
  for (let p=12; p+8<=bytes.length;) {
    const kind=bytes.toString('ascii',p,p+4), size=bytes.readUInt32LE(p+4), start=p+8;
    if (start+size>bytes.length) throw Error('truncated WAV');
    if (kind==='fmt ') valid=size>=16 && bytes.readUInt16LE(start)===1 && bytes.readUInt16LE(start+2)===1 && bytes.readUInt32LE(start+4)===16000 && bytes.readUInt16LE(start+14)===16;
    if (kind==='data') samples=bytes.subarray(start,start+size);
    p=start+size+(size%2);
  }
  if (!valid || !samples || samples.length%2) throw Error('requires PCM16 mono 16kHz');
  return {bytes,samples};
}
const decoded = clips.map(clip => {
  const file = path.join(corpus,clip.filename), data=pcm(file);
  if (sha(data.bytes)!==clip.wavSHA256) throw Error('fixture hash mismatch: '+clip.filename);
  return {...clip, pcm:data.samples};
});
const totalSamples=Math.floor(seconds*16000), data=Buffer.alloc(totalSamples*2), segments=[];
let at=0, index=0;
while (at<totalSamples) {
  const clip=decoded[index%decoded.length], n=clip.pcm.length/2;
  if (at+n>totalSamples) break; // Finish a full utterance; pad the tail with silence.
  clip.pcm.copy(data,at*2);
  segments.push({id:`${index}:${clip.id}`,start_sample:at,end_sample:at+n,source_wav_sha256:clip.wavSHA256,reference:clip.reference});
  at+=n+8000; index+=1; // 500ms separation is part of the pinned synthetic schedule.
}
const header=Buffer.alloc(44);
header.write('RIFF'); header.writeUInt32LE(data.length+36,4); header.write('WAVEfmt ',8);
header.writeUInt32LE(16,16); header.writeUInt16LE(1,20); header.writeUInt16LE(1,22);
header.writeUInt32LE(16000,24); header.writeUInt32LE(32000,28); header.writeUInt16LE(2,32); header.writeUInt16LE(16,34);
header.write('data',36); header.writeUInt32LE(data.length,40);
const wav=Buffer.concat([header,data]);
fs.mkdirSync(output,{recursive:true});
const filename=`${language}-endurance-${seconds}s.wav`;
const destination=path.join(output,filename);
if(fs.existsSync(destination)) throw Error('refusing to overwrite existing fixture');
fs.writeFileSync(destination,wav);
fs.writeFileSync(path.join(output,filename+'.json'),JSON.stringify({schema_version:1,seed,language,sample_rate:16000,samples:totalSamples,seconds:totalSamples/16000,
  corpus_manifest_sha256:sha(manifestBytes),dataset:manifest.dataset,revision:manifest.revision,license:manifest.license,
  content:'repeated public read speech with inserted silence; endurance only, not spontaneous/noise quality evidence',wav_sha256:sha(wav),segments},null,2)+'\n');
console.log(JSON.stringify({filename,seconds,segments:segments.length,sha256:sha(wav)}));
