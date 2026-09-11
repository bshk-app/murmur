import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import {execFileSync} from 'node:child_process';

// Local validation only. This script never uploads or infers Apple processing.
const root = path.resolve(import.meta.dirname, '..');
const release = path.join(root, 'Release/1.0.0-15');
const locales = ['en', 'ru', 'de', 'es', 'fr', 'fi'];
const version = '1.0.0', build = '15', team = 'Q8H6GWJ658';
const sourceOnly = process.argv.includes('--source-only');
const archive = path.resolve(process.argv[2] && !sourceOnly ? process.argv[2] : path.join(root, `build/Archives/Murmator-${version}-${build}.xcarchive`));
const exported = !sourceOnly && process.argv[3] ? path.resolve(process.argv[3]) : undefined;
const run = (tool, args) => execFileSync(tool, args, {encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe']});
const plist = file => JSON.parse(run('/usr/bin/plutil', ['-convert', 'json', '-o', '-', file]));
const sha = file => crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const read = relative => fs.readFileSync(path.join(root, relative), 'utf8');
const json = file => JSON.parse(fs.readFileSync(file, 'utf8'));
const shared = 'group.app.bshk.murmur.ios.shared';
const translation = 'group.app.bshk.murmur.ios.translation';
const bundleNames = ['MurMurMobile.app', 'MurMurKeyboard.appex', 'MurMurPageTranslation.appex', 'MurMurSafariTranslation.appex', 'MurMurWidgets.appex', 'MurMurTranslationProvider.appex'];
const identifiers = ['app.bshk.murmur.ios', 'app.bshk.murmur.ios.keyboard', 'app.bshk.murmur.ios.page-translation', 'app.bshk.murmur.ios.safari-translation', 'app.bshk.murmur.ios.widgets', 'app.bshk.murmur.ios.translation'];
const expectedGroups = name => ['MurMurTranslationProvider.appex', 'MurMurPageTranslation.appex', 'MurMurSafariTranslation.appex'].includes(name)
    ? [translation] : name === 'MurMurMobile.app' ? [shared, translation] : [shared];
const safariResources = path.join(root, 'SafariTranslation/Resources');

function filesUnder(directory) {
    return fs.readdirSync(directory, {withFileTypes: true}).flatMap(item => {
        const file = path.join(directory, item.name);
        return item.isDirectory() ? filesUnder(file) : [file];
    });
}
function checkManifest(directory) {
    const manifest = json(path.join(directory, 'manifest.json'));
    assert.equal(manifest.manifest_version, 3);
    assert.equal(manifest.default_locale, 'en');
    assert.deepEqual([...manifest.permissions].sort(), ['activeTab', 'nativeMessaging', 'scripting'].sort());
    assert.equal(manifest.externally_connectable, undefined);
    assert.deepEqual(manifest.host_permissions, ['http://*/*', 'https://*/*']);
    assert.deepEqual(manifest.background, {scripts: ['background.js'], type: 'module', persistent: false});
    assert.equal(manifest.content_scripts.length, 1);
    assert.deepEqual(manifest.content_scripts[0], {matches: ['http://*/*', 'https://*/*'], js: ['content.js'], run_at: 'document_idle', all_frames: false});
    assert.equal(manifest.action.default_popup, undefined);
    const iconPaths = new Set([...Object.values(manifest.icons), ...Object.values(manifest.action.default_icon)]);
    for (const relative of iconPaths) {
        assert.ok(!relative.includes('..') && !path.isAbsolute(relative));
        const icon = path.join(directory, relative);
        assert.ok(fs.statSync(icon).size > 100);
        const geometry = run('/usr/bin/sips', ['-g', 'pixelWidth', '-g', 'pixelHeight', '-g', 'hasAlpha', icon]);
        assert.match(geometry, /pixelWidth: 180/); assert.match(geometry, /pixelHeight: 180/);
        assert.match(geometry, /hasAlpha: yes/);
    }
    const english = json(path.join(directory, '_locales/en/messages.json'));
    assert.ok(Object.keys(english).length > 10);
    for (const language of locales) {
        const messages = json(path.join(directory, `_locales/${language}/messages.json`));
        assert.deepEqual(Object.keys(messages).sort(), Object.keys(english).sort(), `Missing Safari strings: ${language}`);
        for (const item of Object.values(messages)) assert.ok(typeof item.message === 'string' && item.message.length > 0);
    }
}
function checkSources() {
    const project = read('Project.swift');
    assert.match(project, /let releaseVersion = "1\.0\.0"/);
    assert.match(project, /let releaseBuild = "15"/);
    const production = project.split('.target(name: "MurmatorPageTestHost"')[0];
    for (const term of ['TestSupport', 'node_modules', 'Prototypes/', 'UITestHost/', 'Tests/**', 'ct2-enfi']) assert.ok(!production.includes(term), `Test-only production project input: ${term}`);
    assert.match(production, /"NSExtensionPointIdentifier": "com\.apple\.services"/);
    assert.match(production, /"NSExtensionJavaScriptPreprocessingFile": "SharePage"/);
    assert.match(production, /"NSExtensionPointIdentifier": "com\.apple\.Safari\.web-extension"/);
    assert.ok(!production.includes('PageTranslation/ActionViewController.swift'));
    assert.ok(!production.includes('PageTranslation/PageTranslationView.swift'));
    assert.ok(!production.includes('PageTranslation/Resources/Page.js'));
    for (const relative of ['PageTranslation/ActionRequestHandler.swift', 'PageTranslation/Resources/SharePage.js', 'SafariTranslation/SafariWebExtensionHandler.swift', 'SafariTranslation/Resources/background.js', 'SafariTranslation/Resources/content.js']) {
        assert.ok(!/Prototypes\/|TestSupport\/|fixture-model|SafariStreamingProbe|127\.0\.0\.1/.test(read(relative)), `Fixture reference in ${relative}`);
    }
    const settings = read('Sources/SetupViews.swift');
    for (const term of ['CFBundleShortVersionString', 'CFBundleVersion', 'settings-version', 'Text("Version")', 'Text("Build")']) assert.ok(settings.includes(term), `Settings footer missing ${term}`);
    for (const language of locales) {
        const strings = plist(path.join(root, `Resources/Localizations/${language}.lproj/Localizable.strings`));
        assert.ok(strings.Version && strings.Build, `Version/build strings missing: ${language}`);
    }
    assert.deepEqual(plist(path.join(root, 'TranslationProvider.entitlements'))['com.apple.security.application-groups'], [translation]);
    const actionIcon = run('/usr/bin/sips', ['-g', 'hasAlpha', path.join(root, 'PageTranslation/Resources/ActionAssets.xcassets/ActionIcon.appiconset/action-cat-1024.png')]);
    assert.match(actionIcon, /hasAlpha: yes/);
    checkManifest(safariResources);
    return {version, build, settingsVersionFooterSourceVerified: true, productionTargetInputsExcludeFixtures: true,
        safariManifestVerified: true, safariLocalizations: locales.length, sourceCheckedAt: new Date().toISOString()};
}
const sourceChecks = checkSources();
if (sourceOnly) {
    fs.mkdirSync(release, {recursive: true});
    fs.writeFileSync(path.join(release, 'source-validation.json'), JSON.stringify(sourceChecks, null, 2) + '\n');
    console.log(JSON.stringify(sourceChecks, null, 2));
    process.exit(0);
}

function checkBundleContents(app) {
    const plugins = fs.readdirSync(path.join(app, 'PlugIns')).filter(name => name.endsWith('.appex')).sort();
    assert.deepEqual(plugins, ['MurMurKeyboard.appex', 'MurMurPageTranslation.appex', 'MurMurSafariTranslation.appex', 'MurMurWidgets.appex']);
    assert.deepEqual(fs.readdirSync(path.join(app, 'Extensions')).filter(name => name.endsWith('.appex')).sort(), ['MurMurTranslationProvider.appex']);
    const all = [app, ...plugins.map(name => path.join(app, 'PlugIns', name)), path.join(app, 'Extensions/MurMurTranslationProvider.appex')];
    const checked = [];
    for (const bundle of all) {
        const name = path.basename(bundle), info = plist(path.join(bundle, 'Info.plist'));
        assert.equal(info.CFBundleIdentifier, identifiers[bundleNames.indexOf(name)]);
        assert.equal(info.CFBundleShortVersionString, version); assert.equal(info.CFBundleVersion, build);
        assert.ok(!info.NSAppTransportSecurity?.NSAllowsArbitraryLoads);
        const privacy = plist(path.join(bundle, 'PrivacyInfo.xcprivacy'));
        assert.equal(privacy.NSPrivacyTracking, false); assert.deepEqual(privacy.NSPrivacyCollectedDataTypes, []);
        assert.ok(privacy.NSPrivacyAccessedAPITypes.some(item => item.NSPrivacyAccessedAPIType === 'NSPrivacyAccessedAPICategoryUserDefaults'));
        run('/usr/bin/codesign', ['--verify', '--strict', bundle]);
        const entitlementXML = run('/usr/bin/codesign', ['-d', '--entitlements', ':-', bundle]);
        const signed = JSON.parse(execFileSync('/usr/bin/plutil', ['-convert', 'json', '-o', '-', '-'], {input: entitlementXML, encoding: 'utf8'}));
        assert.deepEqual([...(signed['com.apple.security.application-groups'] ?? [])].sort(), expectedGroups(name).sort());
        assert.equal(signed['application-identifier'], `${team}.${info.CFBundleIdentifier}`);
        assert.equal(signed['com.apple.developer.team-identifier'], team);
        const architectures = run('/usr/bin/lipo', ['-archs', path.join(bundle, info.CFBundleExecutable)]).trim();
        assert.equal(architectures, 'arm64');
        checked.push({bundleIdentifier: info.CFBundleIdentifier, version, build, architectures, signatureVerified: true, applicationGroups: expectedGroups(name)});
    }
    const page = path.join(app, 'PlugIns/MurMurPageTranslation.appex');
    const pageInfo = plist(path.join(page, 'Info.plist'));
    assert.equal(pageInfo.NSExtension.NSExtensionPointIdentifier, 'com.apple.services');
    assert.match(pageInfo.NSExtension.NSExtensionPrincipalClass, /\.ActionRequestHandler$/);
    assert.equal(pageInfo.NSExtension.NSExtensionAttributes.NSExtensionJavaScriptPreprocessingFile, 'SharePage');
    assert.equal(pageInfo.NSExtension.NSExtensionMainStoryboard, undefined);
    assert.ok(!fs.existsSync(path.join(page, 'Page.js')));
    assert.equal(pageInfo.CFBundleIcons.CFBundlePrimaryIcon.CFBundleIconName, 'ActionIcon');
    assert.equal(pageInfo['CFBundleIcons~ipad'].CFBundlePrimaryIcon.CFBundleIconName, 'ActionIcon');
    assert.equal(sha(path.join(page, 'SharePage.js')), sha(path.join(root, 'PageTranslation/Resources/SharePage.js')));
    const safari = path.join(app, 'PlugIns/MurMurSafariTranslation.appex');
    const safariInfo = plist(path.join(safari, 'Info.plist'));
    assert.equal(safariInfo.NSExtension.NSExtensionPointIdentifier, 'com.apple.Safari.web-extension');
    assert.match(safariInfo.NSExtension.NSExtensionPrincipalClass, /\.SafariWebExtensionHandler$/);
    checkManifest(safari);
    for (const source of filesUnder(safariResources)) {
        const relative = path.relative(safariResources, source);
        assert.equal(sha(path.join(safari, relative)), sha(source), `Safari resource differs: ${relative}`);
    }
    assert.equal(plist(path.join(app, 'Extensions/MurMurTranslationProvider.appex/Info.plist')).EXAppExtensionAttributes.EXExtensionPointIdentifier, 'com.apple.public.translation-ui-provider');
    for (const language of locales) {
        const local = plist(path.join(app, language + '.lproj/Localizable.strings'));
        assert.ok(local.Version && local.Build);
        assert.ok(fs.existsSync(path.join(app, language + '.lproj/InfoPlist.strings')));
        assert.ok(fs.existsSync(path.join(page, language + '.lproj/PageTranslation.strings')));
    }
    for (const file of filesUnder(app)) {
        const relative = path.relative(app, file);
        assert.ok(!/(^|\/)(node_modules|TestSupport|UITestHost|Prototypes|fixtures?|Tests)(\/|$)/i.test(relative), `Test-only bundle artifact: ${relative}`);
        assert.ok(!/\.(safetensors|mlmodel|onnx)$|(^|\/)model\.bin$|\.mlmodelc(\/|$)|(^|\/)(ct2-|moz-)/i.test(relative), `Model weights bundled: ${relative}`);
        assert.ok(!/\.xctest(\/|$)|(^|\/)(fixture[^/]*|.*\.test\.mjs|package-lock\.json)$/i.test(relative), `Test artifact bundled: ${relative}`);
    }
    return checked;
}

const archiveInfo = JSON.parse(run('/usr/bin/plutil', ['-extract', 'ApplicationProperties', 'json', '-o', '-', path.join(archive, 'Info.plist')]));
const appPath = path.join(archive, 'Products', archiveInfo.ApplicationPath);
const checkedBundles = checkBundleContents(appPath);
const info = plist(path.join(appPath, 'Info.plist'));
assert.equal(info.CFBundleDisplayName, 'Murmator');
assert.equal(info.ITSAppUsesNonExemptEncryption, false);
assert.equal(info['com.apple.developer.translation-ui-provider.network-access'], true);
assert.deepEqual(info.UIBackgroundModes, ['audio']);
assert.ok(info.NSMicrophoneUsageDescription?.length > 10);
assert.ok(info.CFBundleIcons?.CFBundlePrimaryIcon);
const appUUID = run('/usr/bin/dwarfdump', ['--uuid', path.join(appPath, info.CFBundleExecutable)]).match(/UUID: ([A-F0-9-]+)/)?.[1];
const symbolUUID = run('/usr/bin/dwarfdump', ['--uuid', path.join(archive, 'dSYMs', info.CFBundleExecutable + '.app.dSYM')]).match(/UUID: ([A-F0-9-]+)/)?.[1];
assert.ok(appUUID); assert.equal(symbolUUID, appUUID);
const notices = fs.readFileSync(path.join(appPath, 'ThirdPartyNotices.txt'), 'utf8');
for (const term of ['Mozilla Public License Version 2.0', 'CTranslate2', 'PCRE2', 'NVIDIA Open Model License', 'OPUS-MT']) assert.ok(notices.includes(term), term);
assert.ok(fs.statSync(path.join(appPath, 'BergamotSource.zip')).size > 100000);
run('/usr/bin/unzip', ['-tq', path.join(appPath, 'BergamotSource.zip')]);
const iconInfo = run('/usr/bin/sips', ['-g', 'hasAlpha', '-g', 'pixelWidth', '-g', 'pixelHeight', path.join(root, 'Resources/Media.xcassets/AppIcon.appiconset/icon_appstore_1024.png')]);
assert.match(iconInfo, /hasAlpha: no/); assert.match(iconInfo, /pixelWidth: 1024/); assert.match(iconInfo, /pixelHeight: 1024/);
const validationPath = path.join(release, 'validation.json');
const prior = fs.existsSync(validationPath) ? json(validationPath) : {};
const report = {...sourceChecks, archive, archiveStatus: 'verified', checkedBundles, appUUID, symbolsMatch: true,
    noticesPresent: true, sourceArchiveVerified: true, opaqueIcon: true, pageActionIcon: 'ActionIcon',
    pageTranslationIncluded: true, safariWebExtensionIncluded: true, nonUIShareActionIncluded: true,
    pageJavaScriptMatchesSource: true, pageJavaScriptSHA256: sha(path.join(root, 'PageTranslation/Resources/SharePage.js')),
    safariResourcesMatchSource: true, localizations: locales.length, pageLocalizations: locales.length,
    mainTranslationProviderIncluded: true, bundledModelWeights: 0, bundledTestArtifacts: 0,
    archiveInputsUnchanged: null, appStoreExported: false, appleServerValidation: 'not_performed', uploaded: false,
    appleProcessing: 'not_verified', testingGroupAvailability: 'not_verified',
    tests: prior.tests ?? {}, physicalDeviceTested: prior.physicalDeviceTested ?? false};
const snapshotPath = path.join(release, 'archive-inputs.json');
if (fs.existsSync(snapshotPath)) {
    const snapshot = json(snapshotPath);
    assert.ok(snapshot.files.length > 0);
    for (const file of snapshot.files) assert.equal(sha(path.join(root, file.path)), file.sha256, `Source changed during archive: ${file.path}`);
    report.archiveInputsUnchanged = true;
}
if (exported) {
    const ipas = fs.readdirSync(exported).filter(file => file.endsWith('.ipa'));
    assert.equal(ipas.length, 1);
    const file = path.join(exported, ipas[0]);
    run('/usr/bin/unzip', ['-tq', file]);
    const distribution = plist(path.join(exported, 'DistributionSummary.plist'))[ipas[0]][0];
    const contents = [distribution, ...distribution.embeddedBinaries];
    assert.deepEqual(contents.map(item => item.name).sort(), [...bundleNames].sort());
    for (const item of contents) {
        assert.equal(item.certificate.type, 'Apple Distribution');
        assert.equal(item.entitlements['get-task-allow'], false);
        assert.equal(item.entitlements['beta-reports-active'], true);
        assert.equal(item.team.id, team); assert.equal(item.buildNumber, build); assert.equal(item.versionNumber, version);
        assert.deepEqual([...item.entitlements['com.apple.security.application-groups']].sort(), expectedGroups(item.name).sort());
    }
    // Retain extracted files as local evidence, as in previous release validators.
    const unpacked = fs.mkdtempSync(path.join(root, 'build/ipa-verification-15-'));
    run('/usr/bin/unzip', ['-q', file, '-d', unpacked]);
    const payload = path.join(unpacked, 'Payload/MurMurMobile.app');
    run('/usr/bin/codesign', ['--verify', '--deep', '--strict', payload]);
    report.exportedBundles = checkBundleContents(payload);
    report.ipa = {path: file, bytes: fs.statSync(file).size, sha256: sha(file)};
    report.distributionSigning = {type: 'Apple Distribution', debuggerAllowed: false, betaReportsActive: true, embeddedSignaturesVerified: true};
    report.appStoreExported = true;
}
const uploadPath = path.join(release, 'upload.json');
if (fs.existsSync(uploadPath)) {
    const upload = json(uploadPath);
    if (upload.version === version && upload.build === build && upload.uploaded === true) {
        report.uploaded = true; report.appleServerValidation = 'upload_accepted'; report.uploadRecord = 'upload.json';
    }
}
fs.mkdirSync(release, {recursive: true});
fs.writeFileSync(validationPath, JSON.stringify(report, null, 2) + '\n');
console.log(JSON.stringify(report, null, 2));
