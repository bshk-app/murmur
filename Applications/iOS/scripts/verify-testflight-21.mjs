import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import {execFileSync} from 'node:child_process';

const root = path.resolve(import.meta.dirname, '..');
const archive = path.resolve(process.argv[2] ?? path.join(root, 'build/Archives/Murmator-1.0.0-21.xcarchive'));
const exported = process.argv[3] ? path.resolve(process.argv[3]) : undefined;
const plist = file => JSON.parse(execFileSync('/usr/bin/plutil', ['-convert','json','-o','-',file], {encoding:'utf8'}));
const run = (tool,args) => execFileSync(tool,args,{encoding:'utf8',stdio:['ignore','pipe','pipe']});
const archiveInfo = {ApplicationProperties: JSON.parse(run('/usr/bin/plutil', ['-extract','ApplicationProperties','json','-o','-',path.join(archive,'Info.plist')]))};
const appPath = path.join(archive,'Products',archiveInfo.ApplicationProperties.ApplicationPath);
const info = plist(path.join(appPath,'Info.plist'));
assert.equal(info.CFBundleIdentifier,'app.bshk.murmur.ios');
assert.equal(info.CFBundleDisplayName,'Murmator');
assert.equal(info.CFBundleShortVersionString,'1.0.0');
assert.equal(info.CFBundleVersion,'21');
assert.equal(info.ITSAppUsesNonExemptEncryption,false);
assert.ok(!info.NSAppTransportSecurity?.NSAllowsArbitraryLoads);
assert.equal(info['com.apple.developer.translation-ui-provider.network-access'],true);
assert.deepEqual(info.UIBackgroundModes,['audio']);
assert.ok(info.NSMicrophoneUsageDescription?.length > 10);
assert.ok(info.CFBundleIcons?.CFBundlePrimaryIcon);
const plugins = fs.readdirSync(path.join(appPath,'PlugIns')).filter(name=>name.endsWith('.appex')).sort();
assert.deepEqual(plugins,['MurMurKeyboard.appex','MurMurPageTranslation.appex','MurMurWidgets.appex']);
const extensions=fs.readdirSync(path.join(appPath,'Extensions')).filter(name=>name.endsWith('.appex'));
assert.deepEqual(extensions,['MurMurTranslationProvider.appex']);
const checkedBundles = [];
for (const bundle of [appPath,...plugins.map(p=>path.join(appPath,'PlugIns',p)),...extensions.map(p=>path.join(appPath,'Extensions',p))]) {
    const b = plist(path.join(bundle,'Info.plist'));
    assert.equal(b.CFBundleVersion,info.CFBundleVersion);
    assert.equal(b.CFBundleShortVersionString,info.CFBundleShortVersionString);
    const privacy = plist(path.join(bundle,'PrivacyInfo.xcprivacy'));
    assert.equal(privacy.NSPrivacyTracking,false);
    assert.deepEqual(privacy.NSPrivacyCollectedDataTypes,[]);
    assert.ok(privacy.NSPrivacyAccessedAPITypes.some(a=>a.NSPrivacyAccessedAPIType==='NSPrivacyAccessedAPICategoryUserDefaults'));
    run('/usr/bin/codesign',['--verify','--strict',bundle]);
    const architectures = run('/usr/bin/lipo',['-archs',path.join(bundle,b.CFBundleExecutable)]).trim();
    assert.equal(architectures,'arm64');
    checkedBundles.push({bundleIdentifier:b.CFBundleIdentifier,version:b.CFBundleShortVersionString,build:b.CFBundleVersion,architectures,signatureVerified:true});
}
assert.equal(plist(path.join(appPath,'Extensions','MurMurTranslationProvider.appex','Info.plist')).EXAppExtensionAttributes.EXExtensionPointIdentifier,'com.apple.public.translation-ui-provider');
for (const language of ['en','ru','de','es','fr','fi']) {
    assert.ok(fs.existsSync(path.join(appPath,language+'.lproj','Localizable.strings')));
    assert.ok(fs.existsSync(path.join(appPath,language+'.lproj','InfoPlist.strings')));
}
const notices = fs.readFileSync(path.join(appPath,'ThirdPartyNotices.txt'),'utf8');
for (const term of ['Mozilla Public License Version 2.0','CTranslate2','PCRE2','NVIDIA Open Model License','OPUS-MT','GRDB.swift']) assert.ok(notices.includes(term),term);
assert.ok(fs.statSync(path.join(appPath,'BergamotSource.zip')).size > 100000);
run('/usr/bin/unzip',['-tq',path.join(appPath,'BergamotSource.zip')]);
const dsym = path.join(archive,'dSYMs',info.CFBundleExecutable+'.app.dSYM');
const appUUID = run('/usr/bin/dwarfdump',['--uuid',path.join(appPath,info.CFBundleExecutable)]).match(/UUID: ([A-F0-9-]+)/)?.[1];
const symbolUUID = run('/usr/bin/dwarfdump',['--uuid',dsym]).match(/UUID: ([A-F0-9-]+)/)?.[1];
assert.ok(appUUID); assert.equal(symbolUUID,appUUID);
const icon = path.join(root,'Resources/Media.xcassets/AppIcon.appiconset/icon_appstore_1024.png');
const iconInfo = run('/usr/bin/sips',['-g','hasAlpha','-g','pixelWidth','-g','pixelHeight',icon]);
assert.match(iconInfo,/hasAlpha: no/); assert.match(iconInfo,/pixelWidth: 1024/); assert.match(iconInfo,/pixelHeight: 1024/);
let weights = [];
function scan(directory) {
    for (const item of fs.readdirSync(directory,{withFileTypes:true})) {
        const file=path.join(directory,item.name);
        if(item.isDirectory()) scan(file);
        else if(/\.(safetensors|mlmodel|mlmodelc|onnx)$/.test(item.name)||item.name==='model.bin') weights.push(file);
    }
}
scan(appPath); assert.equal(weights.length,0,'Downloaded model weights must not be bundled');
const report = {archive,version:info.CFBundleShortVersionString,build:info.CFBundleVersion,checkedBundles,appUUID,symbolsMatch:true,localizations:6,noticesPresent:true,sourceArchiveVerified:true,opaqueIcon:true,mainTranslationProviderIncluded:true,bundledModelWeights:0,appleServerValidation:'not_performed',uploaded:false};
if(exported) {
    const ipa=fs.readdirSync(exported).filter(f=>f.endsWith('.ipa'));
    assert.equal(ipa.length,1);
    const file=path.join(exported,ipa[0]);
    run('/usr/bin/unzip',['-tq',file]);
    const distribution = plist(path.join(exported,'DistributionSummary.plist'))[ipa[0]][0];
    for (const content of [distribution,...distribution.embeddedBinaries]) {
        assert.equal(content.certificate.type,'Apple Distribution');
        assert.equal(content.entitlements['get-task-allow'],false);
        assert.equal(content.entitlements['beta-reports-active'],true);
        assert.equal(content.team.id,'Q8H6GWJ658');
        assert.equal(content.buildNumber,'21');
        assert.equal(content.versionNumber,'1.0.0');
        const groups=content.entitlements['com.apple.security.application-groups'];
        const expected=['MurMurTranslationProvider.appex','MurMurPageTranslation.appex'].includes(content.name) ? ['group.app.bshk.murmur.ios.translation'] : content.name==='MurMurMobile.app' ? ['group.app.bshk.murmur.ios.shared','group.app.bshk.murmur.ios.translation'] : ['group.app.bshk.murmur.ios.shared'];
        assert.deepEqual([...groups].sort(),expected.sort());
    }
    const unpacked = fs.mkdtempSync(path.join(root,'build/ipa-verification-'));
    run('/usr/bin/unzip',['-q',file,'-d',unpacked]);
    const payload=path.join(unpacked,'Payload','MurMurMobile.app');
    run('/usr/bin/codesign',['--verify','--deep','--strict',payload]);
    assert.equal(plist(path.join(payload,'Info.plist')).CFBundleVersion,'21');
    report.ipa={path:file,bytes:fs.statSync(file).size,sha256:crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')};
    report.distributionSigning={type:'Apple Distribution',debuggerAllowed:false,betaReportsActive:true,embeddedSignaturesVerified:true};
}
const snapshotPath=path.join(root,'Release/1.0.0-21/archive-inputs.json');
if(fs.existsSync(snapshotPath)) {
    const snapshot=JSON.parse(fs.readFileSync(snapshotPath,'utf8'));
    for(const file of snapshot.files) assert.equal(crypto.createHash('sha256').update(fs.readFileSync(path.join(root,file.path))).digest('hex'),file.sha256,`Source changed during archive: ${file.path}`);
    report.archiveInputsUnchanged=true;
}

const page=path.join(appPath,'PlugIns','MurMurPageTranslation.appex');
const pageInfo=plist(path.join(page,'Info.plist'));
assert.equal(pageInfo.NSExtension.NSExtensionPointIdentifier,'com.apple.ui-services');
assert.deepEqual(fs.readFileSync(path.join(page,'Page.js')),fs.readFileSync(path.join(root,'PageTranslation/Resources/Page.js')));
for(const language of ['en','ru','de','es','fr','fi']) assert.ok(fs.existsSync(path.join(page,language+'.lproj','PageTranslation.strings')));
report.pageTranslationIncluded=true;
report.pageJavaScriptMatchesSource=true;
report.pageJavaScriptSHA256=crypto.createHash('sha256').update(fs.readFileSync(path.join(page,'Page.js'))).digest('hex');
report.pageLocalizations=6;
assert.equal(pageInfo.CFBundleIcons.CFBundlePrimaryIcon.CFBundleIconName,"ActionIcon");
assert.equal(pageInfo["CFBundleIcons~ipad"].CFBundlePrimaryIcon.CFBundleIconName,"ActionIcon");
report.pageActionIcon="ActionIcon";
report.safariWebExtensionIncluded=false;
assert.match(pageInfo.NSExtension.NSExtensionPrincipalClass,/\.ActionViewController$/);
assert.equal(pageInfo.NSExtension.NSExtensionAttributes.NSExtensionJavaScriptPreprocessingFile,"Page");
assert.ok(!fs.existsSync(path.join(page,"SharePage.js")));
const validationPath=path.join(root,'Release/1.0.0-21/validation.json');
const prior=JSON.parse(fs.readFileSync(validationPath,'utf8'));
delete prior.exportBlocker;
Object.assign(report,{regressions:prior.regressions,physicalDeviceTested:false,appStoreExported:!!exported});
const uploadPath=path.join(root,'Release/1.0.0-21/upload.json');
if(fs.existsSync(uploadPath)) {
    const upload=JSON.parse(fs.readFileSync(uploadPath,'utf8'));
    if(upload.build===report.build && upload.version===report.version && upload.uploaded) {
        report.uploaded=true;
        report.appleServerValidation='upload_accepted';
        report.uploadRecord='upload.json';
        report.appleProcessing=upload.appleProcessing; report.internalBuildState=upload.internalBuildState; report.testingGroupAvailability=upload.testFlightGroupAssignment;
    }
}
fs.writeFileSync(validationPath,JSON.stringify(report,null,2)+'\n');
console.log(JSON.stringify(report,null,2));
