// Run Xcode's export/upload using the existing App Store Connect key, without
// persisting the issuer or private key in the repository.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {execFileSync, spawn} from 'node:child_process';
const args = process.argv.slice(2);
if (!args.includes('-exportArchive')) throw Error('Only archive export/upload is supported');
const keyID = process.env.ASC_API_KEY_ID || '38V7FDZ48J';
const issuer = execFileSync('op', ['read', process.env.ASC_ISSUER_REFERENCE || 'op://Private/o5ocl3hneq2mobu6exk4vtbqhu/Issuer ID'], {
    encoding: 'utf8', timeout: 60000, stdio: ['ignore', 'pipe', 'inherit'],
}).trim();
if (!/^[a-f0-9-]{36}$/i.test(issuer)) throw Error('Invalid issuer format');
const keyPath = path.join(os.homedir(), '.appstoreconnect/private_keys', `AuthKey_${keyID}.p8`);
fs.accessSync(keyPath, fs.constants.R_OK);
const child = spawn('xcodebuild', [...args, '-allowProvisioningUpdates', '-authenticationKeyPath', keyPath,
    '-authenticationKeyID', keyID, '-authenticationKeyIssuerID', issuer], {stdio:['ignore','pipe','pipe']});
for (const stream of [child.stdout, child.stderr]) stream.on('data', bytes => process.stdout.write(bytes.toString().replaceAll(issuer, '[issuer]')));
child.on('error', error => { console.error(error.message); process.exitCode = 1; });
child.on('close', code => { process.exitCode = code ?? 1; });
