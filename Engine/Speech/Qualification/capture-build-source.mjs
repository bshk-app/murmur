#!/usr/bin/env node
// Embed the actual source/artifact fingerprint used by a device qualification build.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {fileURLToPath} from 'node:url';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'../../..');
const hashes={};
function visit(relative){
  const absolute=path.join(root,relative), stat=fs.lstatSync(absolute);
  if(stat.isSymbolicLink()) return;
  if(stat.isDirectory()){
    for(const name of fs.readdirSync(absolute).sort()){
      if(name.startsWith('.') || /^(Tests|TestsSupport|Qualification|build.*|node_modules)$/.test(name)) continue;
      visit(path.join(relative,name));
    }
  } else if(/\.(swift|h|cpp|a)$/.test(relative) || relative.endsWith('Package.resolved')) {
    hashes[relative]=crypto.createHash('sha256').update(fs.readFileSync(absolute)).digest('hex');
  }
}
for(const directory of ['Engine/Core','Engine/Speech','Engine/Translation','MurmurKit/Sources/CBergamot','Applications/iOS/Sources','Applications/iOS/Shared','Applications/iOS/PageTranslation','Applications/iOS/TranslationProvider'])visit(directory);
for(const file of ['Applications/iOS/Package.resolved','Applications/iOS/Project.swift'])visit(file);
const canonical=JSON.stringify(hashes);
const manifest={schema_version:1,source_sha256:crypto.createHash('sha256').update(canonical).digest('hex'),files:hashes};
const output=path.join(root,'Applications/iOS/Resources/QualityQualificationBuild.json');
fs.writeFileSync(output,JSON.stringify(manifest,null,2)+'\n');
console.log(`${manifest.source_sha256}: ${Object.keys(hashes).length} source/artifact files`);
