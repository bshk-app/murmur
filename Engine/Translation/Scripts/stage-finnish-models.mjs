// Verify the previously converted OPUS packs, then stage their distribution.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
const source = path.resolve(process.argv[2] ?? 'Prototypes/iOS/build/TranslationModels');
const destination = path.resolve(process.argv[3] ?? '/tmp/murmur-finnish-distribution');
const catalog = JSON.parse(fs.readFileSync(path.join(source, 'catalog.json')));
let swift = '// Verified OPUS-MT conversions; see Scripts/stage-finnish-models.mjs.\n';
swift += 'extension TranslationQualityDigests {\n    static let finnish: [String: Entry] = [\n';
for (const pair of ['enfi','fien','rufi','firu']) {
  const entry = catalog[pair];
  const directory = path.join(destination, pair.slice(0,2)+'-'+pair.slice(2));
  fs.mkdirSync(directory, {recursive:true});
  swift += `        "${pair}": Entry(files: [\n`;
  for (const [name, metadata] of Object.entries(entry.files)) {
    const file = path.join(source, 'ct2-'+pair, name);
    const digest = crypto.createHash('sha256');
    for await (const chunk of fs.createReadStream(file)) digest.update(chunk);
    if (digest.digest('hex') !== metadata.sha256 || fs.statSync(file).size !== metadata.bytes) throw Error(`Invalid ${pair}/${name}`);
    fs.copyFileSync(file, path.join(directory,name));
    swift += `            File(name: "${name}", sha256: "${metadata.sha256}", bytes: ${metadata.bytes}),\n`;
  }
  fs.writeFileSync(path.join(directory,'provenance.json'), JSON.stringify(entry,null,2)+'\n');
  swift += '        ]),\n';
}
swift += '    ]\n}\n';
fs.writeFileSync('Engine/Translation/Sources/MurmurTranslation/FinnishQualityDigests.swift', swift);
console.log('Verified and staged four Finnish OPUS directions at '+destination);
