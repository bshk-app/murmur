import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import os from 'node:os';
import {execFileSync, spawn} from 'node:child_process';

// Only references/identifiers are stored here. The issuer is read from 1Password;
// altool reads the existing private key from ~/.appstoreconnect/private_keys.
const issuerReference = process.env.ASC_ISSUER_REFERENCE || 'op://Private/o5ocl3hneq2mobu6exk4vtbqhu/Issuer ID';
const keyID = process.env.ASC_API_KEY_ID || '38V7FDZ48J';
const appID = '6809815142';
const root = path.resolve(import.meta.dirname, '..');
const [mode, releaseName] = process.argv.slice(2);
if (!['upload', 'status'].includes(mode) || !/^\d+\.\d+\.\d+-\d+$/.test(releaseName || '')) {
    throw Error('Usage: node scripts/testflight-cli.mjs upload|status VERSION-BUILD');
}
const directory = path.join(root, 'Release', releaseName);
const report = JSON.parse(fs.readFileSync(path.join(directory, 'validation.json'), 'utf8'));
if (`${report.version}-${report.build}` !== releaseName) throw Error('Release metadata does not match');
if (!report.checkedBundles?.some(item => item.bundleIdentifier === 'app.bshk.murmur.ios')) throw Error('Unexpected application');
if (mode === 'upload') {
    if (report.uploaded) { console.log('Upload already recorded; use status to check processing.'); process.exit(0); }
    if (!report.appStoreExported || !report.archiveInputsUnchanged) throw Error('Archive/export verification required');
    const checksum = crypto.createHash('sha256').update(fs.readFileSync(report.ipa.path)).digest('hex');
    if (checksum !== report.ipa.sha256) throw Error('IPA changed after validation');
}
const issuer = execFileSync('op', ['read', issuerReference], {encoding: 'utf8', stdio: ['ignore', 'pipe', 'inherit']}).trim();
if (!/^[a-f0-9-]{36}$/i.test(issuer)) throw Error('Invalid issuer format');
async function checkStatus() {
    const encode = value => Buffer.from(JSON.stringify(value)).toString('base64url');
    const now = Math.floor(Date.now() / 1000);
    const payload = encode({alg: 'ES256', kid: keyID, typ: 'JWT'}) + '.' + encode({iss: issuer, aud: 'appstoreconnect-v1', iat: now, exp: now + 120});
    const key = fs.readFileSync(path.join(os.homedir(), '.appstoreconnect/private_keys', `AuthKey_${keyID}.p8`));
    const signature = crypto.sign('sha256', Buffer.from(payload), {key, dsaEncoding: 'ieee-p1363'}).toString('base64url');
    const headers = {Authorization: 'Bearer ' + payload + '.' + signature};
    const url = new URL('https://api.appstoreconnect.apple.com/v1/builds');
    url.searchParams.set('filter[app]', appID); url.searchParams.set('filter[version]', report.build);
    url.searchParams.set('include', 'buildBetaDetail,betaGroups,preReleaseVersion');
    const response = await fetch(url, {headers});
    const data = await response.json();
    if (!response.ok) throw Error(`App Store Connect status request failed (${response.status})`);
    const builds = data.data.filter(build => data.included?.some(item => item.type === 'preReleaseVersions' && item.id === build.relationships?.preReleaseVersion?.data?.id && item.attributes.version === report.version));
    fs.writeFileSync(path.join(directory, 'apple-build-status.json'), JSON.stringify(data, null, 2) + '\n');
    const beta = data.included?.find(item => item.type === 'buildBetaDetails');
    console.log(JSON.stringify({build: report.build, processing: builds[0]?.attributes.processingState ?? 'not_visible_yet', testing: beta?.attributes.internalBuildState, groups: data.included?.filter(item => item.type === 'betaGroups').map(item => item.attributes.name)}));
    return builds[0] ? {...builds[0], testingState: beta?.attributes.internalBuildState} : undefined;
}
if (mode === 'status') process.exit(await checkStatus() ? 0 : 1);
const args = ['--upload-app', '-f', report.ipa.path, '-t', 'ios'];
args.push('--api-key', keyID, '--api-issuer', issuer, '--output-format', 'json');
const child = spawn('xcrun', ['altool', ...args], {stdio: ['ignore', 'pipe', 'pipe']});
let output = '';
for (const stream of [child.stdout, child.stderr]) stream.on('data', chunk => { output += chunk.toString(); });
child.on('error', () => { console.error('Could not start altool'); process.exitCode = 1; });
child.on('close', async code => {
    const sanitized = output.replaceAll(issuer, '[issuer]').replace(/Bearer\s+[A-Za-z0-9_.-]+/gi, 'Bearer [redacted]');
    const log = path.join(directory, `cli-${mode}.log`);
    fs.writeFileSync(log, sanitized, {mode: 0o600});
    console.log(`${mode}: ${code === 0 ? 'completed' : 'failed'}; details: ${log}`);
    process.exitCode = code ?? 1;
    // Reuse the in-memory issuer for processing checks: one 1Password approval,
    // without caching its value or asking for authorization again after upload.
    if (code !== 0) return;
    for (let attempt = 0; attempt < 18; attempt++) {
        try {
            const build = await checkStatus();
            if (build && (['FAILED', 'INVALID'].includes(build.attributes.processingState) ||
                build.attributes.processingState === 'VALID' && build.testingState === 'IN_BETA_TESTING')) return;
        } catch (error) { console.error(error.message); return; }
        await new Promise(resolve => setTimeout(resolve, 10000));
    }
    console.log('Upload accepted; processing is not confirmed yet.');
});
