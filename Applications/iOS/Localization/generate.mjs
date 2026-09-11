import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const rows = fs.readFileSync(path.join(root,'Localization/translations.tsv'),'utf8').trimEnd().split('\n').map(x=>x.split('\t'));
const columns = rows.shift();
const keys = rows.map(x=>x[0]);
if (new Set(keys).size !== keys.length) throw Error('Duplicate localization keys');
const decode = x=>x.replaceAll('\\n','\n').replaceAll('\\t','\t');
const placeholders = x=>(x.match(/%(?:\d+\$)?(?:lld|@|d|f)/g)??[]).sort().join('|');
for (const lang of ['en', ...columns.slice(1)]) {
  const values = new Map();
  for (const row of rows) {
    const key=decode(row[0]), value=decode(lang==='en' ? row[0] : row[columns.indexOf(lang)] ?? '');
    if (!value.trim() || placeholders(key)!==placeholders(value)) throw Error(`Invalid ${lang}: ${key}`);
    values.set(key,value);
  }
  const directory = path.join(root, 'Resources/Localizations', lang+'.lproj');
  fs.mkdirSync(directory,{recursive:true});
  fs.writeFileSync(path.join(directory,'Localizable.strings'), [...values].map(([k,v])=>`${JSON.stringify(k)} = ${JSON.stringify(v)};`).join('\n')+'\n');
  fs.writeFileSync(path.join(directory,'InfoPlist.strings'), '"NSMicrophoneUsageDescription" = '+JSON.stringify(values.get('Murmator transcribes your voice on this device.'))+';\n');
}
console.log(`Validated ${keys.length} keys in 6 languages.`);
