import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {execFileSync} from 'node:child_process';
import assert from 'node:assert/strict';

const plist = file => JSON.parse(execFileSync('/usr/bin/plutil', ['-convert', 'json', '-o', '-', file], {encoding: 'utf8'}));
function compare(a, b) {
    for (const value of [a, b]) assert.match(value ?? '', /^\d+(\.\d+){0,2}$/, 'Missing or invalid MinimumOSVersion');
    const left = a.split('.').map(Number), right = b.split('.').map(Number);
    for (let i = 0; i < 3; i++) {
        const difference = (left[i] ?? 0) - (right[i] ?? 0);
        if (difference) return difference;
    }
    return 0;
}

// Check final Mach-O executables, including Xcode-generated static framework
// stubs: upstream Info.plist values alone do not describe those binaries.
export function verifyMinimumOS(app) {
    const checked = [];
    function visit(directory) {
        if (/\.(app|appex|framework)$/.test(directory)) {
            const info = plist(path.join(directory, 'Info.plist'));
            const binary = path.join(directory, info.CFBundleExecutable);
            const output = execFileSync('/usr/bin/xcrun', ['vtool', '-show-build', binary], {encoding: 'utf8'});
            const minimums = output.split(/Load command \d+/).flatMap(command => {
                const match = /cmd LC_BUILD_VERSION\b/.test(command)
                    ? command.match(/\bminos\s+([\d.]+)/)
                    : /cmd LC_VERSION_MIN_IPHONEOS\b/.test(command) ? command.match(/\bversion\s+([\d.]+)/) : null;
                return match ? [match[1]] : [];
            });
            assert.ok(minimums.length, `${binary}: missing iOS deployment load command`);
            for (const minimum of minimums) {
                assert.ok(compare(info.MinimumOSVersion, minimum) >= 0,
                    `${directory}: Info.plist declares iOS ${info.MinimumOSVersion}, but Mach-O requires iOS ${minimum} (ITMS-90208)`);
            }
            if (directory.endsWith('.framework')) {
                const container = path.dirname(path.dirname(directory));
                const host = plist(path.join(container, 'Info.plist'));
                assert.ok(compare(host.MinimumOSVersion, info.MinimumOSVersion) >= 0,
                    `${directory}: framework minimum exceeds its containing bundle's iOS ${host.MinimumOSVersion}`);
            }
            checked.push({bundle: path.relative(app, directory) || '.', declared: info.MinimumOSVersion, binaryMinimums: [...new Set(minimums)]});
        }
        for (const entry of fs.readdirSync(directory, {withFileTypes: true})) {
            if (entry.isDirectory()) visit(path.join(directory, entry.name));
        }
    }
    visit(app);
    return checked;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
    assert.ok(process.argv[2], 'Usage: node verify-minimum-os.mjs PATH_TO_APP');
    console.log(JSON.stringify(verifyMinimumOS(path.resolve(process.argv[2])), null, 2));
}
