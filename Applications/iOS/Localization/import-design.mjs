import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
const root = path.dirname(fileURLToPath(import.meta.url));
const source = fs.readFileSync(process.argv[2], 'utf8');
function objectAt(start) {
  start = source.indexOf('{', start);
  let depth = 0, string = false, escape = false;
  for (let i = start; i < source.length; i++) {
    const c = source[i];
    if (string) { if (escape) escape = false; else if (c === '\\') escape = true; else if (c === '"') string = false; continue; }
    if (c === '"') string = true;
    else if (c === '{') depth++;
    else if (c === '}' && --depth === 0) return JSON.parse(source.slice(start, i + 1));
  }
  throw Error('Unterminated copy object');
}
const dict = objectAt(source.indexOf('window.MURMUR_COPY ='));
for (const match of source.matchAll(/Object\.assign\(window\.MURMUR_COPY,/g)) Object.assign(dict, objectAt(match.index));
const rows = fs.readFileSync(path.join(root, 'translations.tsv'), 'utf8').trimEnd().split('\n').map(x=>x.split('\t'));
const columns = rows.shift();
const merged = new Map(rows.map(row=>[row[0], row]));
const escape = x => x.replaceAll('\n', '\\n').replaceAll('\t', '\\t');
for (const [key, translations] of Object.entries(dict)) {
  if (!columns.slice(1).every(lang => typeof translations[lang] === 'string')) throw Error('Missing translation: ' + key);
  merged.set(escape(key), [escape(key), ...columns.slice(1).map(lang=>escape(translations[lang]))]);
}
fs.writeFileSync(path.join(root, 'translations.tsv'), [columns, ...merged.values()].map(x=>x.join('\t')).join('\n')+'\n');
console.log(`Imported ${Object.keys(dict).length} design keys; ${merged.size} total keys.`);
