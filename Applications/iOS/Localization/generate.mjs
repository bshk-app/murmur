import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const rows = fs.readFileSync(path.join(root,'Localization/translations.tsv'),'utf8').trimEnd().split('\n').map(x=>x.split('\t'));
const columns = rows.shift(), keys = rows.map(x=>x[0]);
if (new Set(keys).size !== keys.length) throw Error('Duplicate localization keys');
const decode = x=>x.replaceAll('\\n','\n').replaceAll('\\t','\t');
const placeholders = x=>(x.match(/%(?:\d+\$)?(?:lld|@|d|f)/g)??[]).sort().join('|');
const pairPattern = /("(?:\\.|[^"\\])*")\s*=\s*("(?:\\.|[^"\\])*");/g;
function mergeStrings(file, values) {
  let text = fs.existsSync(file) ? fs.readFileSync(file,'utf8') : '';
  const seen = new Set();
  text = text.replace(pairPattern, (original, k, v) => {
    const key=JSON.parse(k); seen.add(key);
    return !values.has(key) || values.get(key)===JSON.parse(v) ? original : JSON.stringify(key)+' = '+JSON.stringify(values.get(key))+';';
  });
  if (text && !text.endsWith('\n')) text += '\n';
  for (const [k,v] of values) if (!seen.has(k)) text += JSON.stringify(k)+' = '+JSON.stringify(v)+';\n';
  fs.writeFileSync(file,text);
}
for (const lang of ['en', ...columns.slice(1)]) {
  const values = new Map(), directory = path.join(root,'Resources/Localizations',lang+'.lproj');
  const existing = path.join(directory,'Localizable.strings');
  // Preserve shipped strings and English copy overrides until migrated into the table.
  if (fs.existsSync(existing)) for (const [,k,v] of fs.readFileSync(existing,'utf8').matchAll(pairPattern)) values.set(JSON.parse(k),JSON.parse(v));
  for (const row of rows) {
    const key=decode(row[0]), value=decode(lang==='en' ? values.get(key) ?? row[0] : row[columns.indexOf(lang)] ?? '');
    if (!value.trim() || placeholders(key)!==placeholders(value)) throw Error('Invalid '+lang+': '+key);
    values.set(key,value);
  }
  fs.mkdirSync(directory,{recursive:true});
  mergeStrings(existing,values);
  const info = path.join(directory,'InfoPlist.strings');
  const privacy = new Map([['NSCameraUsageDescription',values.get('Murmator reads and translates text from a photo on this device.')]]);
  if (!fs.existsSync(info) || !fs.readFileSync(info,'utf8').includes('"NSMicrophoneUsageDescription"')) privacy.set('NSMicrophoneUsageDescription',values.get('Murmator transcribes your voice on this device.'));
  mergeStrings(info,privacy);
}
console.log('Validated '+keys.length+' keys in 6 languages.');
