import assert from 'node:assert/strict';
import fs from 'node:fs';
const data=JSON.parse(fs.readFileSync(new URL('./opus-candidates.json',import.meta.url)));
assert.equal(data.matrix.length,650);
assert.equal(new Set(data.matrix.map(r=>`${r.from}-${r.to}`)).size,650);
assert.equal(data.matrix.filter(r=>r.priority).length,20);
for(const row of data.matrix) {
 assert.notEqual(row.from,row.to);
 assert.ok(row.baseline.legs.every(Boolean));
 for(const candidate of row.candidates) {
  assert.match(candidate.revision,/^[a-f0-9]{40}$/);
  const model=data.models.find(m=>m.checkpoint===candidate.checkpoint);
  assert.ok(model.source_evidence&&model.target_evidence);
  assert.equal(candidate.conversion_status,'not-tested');
  assert.notEqual(candidate.target_tag_evidence,'missing');
  assert.ok(model.routes.some(r=>r.from===row.from&&r.to===row.to&&r.target_tag===candidate.target_tag));
 }
}
assert.ok(data.matrix.find(r=>r.from==='en'&&r.to==='de').candidates.some(c=>c.checkpoint==='Helsinki-NLP/opus-mt-en-de'));
assert.equal(data.matrix.find(r=>r.from==='en'&&r.to==='ru').baseline.legs[0].target_tag,'>>rus<<');
assert.ok(data.matrix.find(r=>r.from==='de'&&r.to==='fi').candidates.some(c=>c.checkpoint==='Helsinki-NLP/opus-mt-de-fi'));
console.log('Validated 650 unique directions, 20 priority directions, baseline legs, revision pins and card/tag evidence.');
