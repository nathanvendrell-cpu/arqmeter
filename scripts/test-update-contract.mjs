import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { generateKeyPairSync, sign, randomUUID } from 'node:crypto';
import { schemaVersion, states, UpdateError, sha256, httpsURL, validateRelease,
  evaluateRelease, verifyArchive, verifyReleaseMetadata, validateStatus } from './update-contract.mjs';
import { validateBundleInfo, signerArguments, prepare, run, toolHashes, keyToolHash } from './prepare-sparkle-release.mjs';

function fixture() {
  const keys = generateKeyPairSync('ed25519');
  const key = keys.publicKey.export({type:'spki',format:'der'}).subarray(-32);
  const bytes = Buffer.from('synthetic archive fixture, not an installed application');
  const release = {schemaVersion, productID:'com.example.update-fixture',version:'2.0.0',build:'20261020.26',
    platform:'macos',architecture:'arm64',channel:'stable',artifact:{
      url:'https://github.com/example/fixture/releases/download/v2/fixture.zip',
      sizeBytes:bytes.length,sha256:sha256(bytes),signature:{algorithm:'ed25519',
        value:sign(null,bytes,keys.privateKey).toString('base64'),publicKeyID:sha256(key)}}};
  return {keys,key,bytes,release};
}
const clone = value => structuredClone(value);
const rejected = (operation, code) => assert.throws(operation, error => error instanceof UpdateError && (!code || error.code === code));
const status = (state, target = null) => ({schemaVersion,productID:'com.example.update-fixture',
  operationID:randomUUID(),updatedAt:'2026-10-20T12:00:00.000Z',state,
  installedBuild:state === 'succeeded' ? target.build : '20261020.25',target,downloadedBytes:null,
  errorCode:['unconfigured','blocked','failed'].includes(state) ? 'configurationMissing' : null,retryable:false});
const info = key => ({CFBundleIdentifier:'com.example.update-fixture',CFBundleShortVersionString:'2.0.0',
  CFBundleVersion:'20261020.26',SURequireSignedFeed:true,SUVerifyUpdateBeforeExtraction:true,
  SUSendProfileInfo:false,SUFeedURL:'https://raw.githubusercontent.com/example/fixture/main/appcast.xml',
  SUPublicEDKey:key.toString('base64'),ARQUpdateDownloadHosts:['github.com']});

test('complete release metadata, two products and all user states round trip without credentials', () => {
  const {release} = fixture();
  assert.deepEqual(JSON.parse(JSON.stringify(validateRelease(release,['github.com']))),release);
  const other = clone(release);other.productID='com.example.other-app';assert.equal(validateRelease(other).productID,other.productID);
  for(const state of states) {
    const needsTarget=['available','downloading','readyToInstall','installing','relaunching','succeeded'].includes(state);
    assert.deepEqual(validateStatus(status(state,needsTarget ? release : null)).state,state);
  }
});
test('metadata needs exact fields, size/hash and canonical signature; unknown fields are refused', () => {
  const {release}=fixture();
  for(const mutate of [x=>x.privateKey='forbidden',x=>delete x.version,x=>x.artifact.sizeBytes=-1,
    x=>x.artifact.sizeBytes=Number.MAX_SAFE_INTEGER+1,x=>x.artifact.sha256='bad',
    x=>x.artifact.signature.value='bad',x=>x.artifact.signature.algorithm='unsigned']) {
    const value=clone(release);mutate(value);rejected(()=>validateRelease(value));
  }
});
test('HTTPS requires safe URL and separately trusted exact host', () => {
  for(const url of ['http://github.com/a','https://user:pass@github.com/a','https://github.com/a?secret=x',
    'https://github.com/a#fragment','https://github.com:8443/a','not a URL']) rejected(()=>httpsURL(url));
  rejected(()=>httpsURL('https://github.com.evil.test/a',['github.com']),'incompatible');
});
test('metadata presence is not authentication, compatibility or native newer-version proof', () => {
  const {release}=fixture();const context={allowedHosts:['github.com'],productID:release.productID,
    platform:'macos',architecture:'arm64',nativeVersionIsNewer:true,nativeCompatibilityPassed:true,metadataSignatureVerified:true};
  assert.equal(evaluateRelease(release,context),release);
  for(const field of ['nativeVersionIsNewer','nativeCompatibilityPassed','metadataSignatureVerified'])
    rejected(()=>evaluateRelease(release,{...context,[field]:false}));
  rejected(()=>evaluateRelease(release,{...context,platform:'windows'}),'incompatible');
  rejected(()=>evaluateRelease(release,{...context,architecture:'x86_64'}),'incompatible');
  const prerelease=clone(release);prerelease.channel='prerelease';
  rejected(()=>evaluateRelease(prerelease,context),'incompatible');
  assert.equal(evaluateRelease(prerelease,{...context,includePrerelease:true}),prerelease);
});
test('exact archive accepted; bad hash, altered bytes, wrong key/signature rejected', () => {
  const {bytes,release,key}=fixture();assert.equal(verifyArchive(bytes,release,key),true);
  rejected(()=>verifyArchive(Buffer.from('changed'),release,key),'invalidArchive');
  rejected(()=>verifyArchive(bytes,release,fixture().key),'invalidArchive');
  const forged=clone(release);forged.artifact.signature.value=Buffer.alloc(64).toString('base64');
  rejected(()=>verifyArchive(bytes,forged,key),'invalidArchive');
  const hash=clone(release);hash.artifact.sha256='0'.repeat(64);
  rejected(()=>verifyArchive(bytes,hash,key),'invalidArchive');
});
test('detached metadata signature authenticates exact bytes, not a reserialized or changed JSON', () => {
  const {keys,key,release}=fixture();const bytes=Buffer.from(JSON.stringify(release));
  const signature=sign(null,bytes,keys.privateKey).toString('base64');
  assert.deepEqual(verifyReleaseMetadata(bytes,signature,key,['github.com']),release);
  rejected(()=>verifyReleaseMetadata(Buffer.from(JSON.stringify(release,null,2)),signature,key),'invalidFeed');
  rejected(()=>verifyReleaseMetadata(bytes,signature,fixture().key),'invalidFeed');
  const changed=clone(release);changed.version='9.0.0';
  rejected(()=>verifyReleaseMetadata(Buffer.from(JSON.stringify(changed)),signature,key),'invalidFeed');
});
test('status never equates download or relaunch request with success', () => {
  const {release}=fixture();rejected(()=>validateStatus({...status('succeeded',release),installedBuild:'20261020.25'}));
  rejected(()=>validateStatus(status('downloading')));
  const value=status('downloading',release);value.downloadedBytes=release.artifact.sizeBytes+1;rejected(()=>validateStatus(value));
  const extra=status('idle');extra.rawError='/private/path';rejected(()=>validateStatus(extra));
  const invalid=status('idle');invalid.operationID='-'.repeat(36);rejected(()=>validateStatus(invalid));
});
test('publisher requires signed-feed configuration, key, known host and increasing numeric build', () => {
  const {key}=fixture(), valid=info(key), prefix='https://github.com/example/fixture/releases/download/v2/';
  assert.equal(validateBundleInfo(valid,prefix,'20261020.25','stable').key.equals(key),true);
  for(const mutate of [x=>delete x.SUFeedURL,x=>x.SUPublicEDKey=Buffer.alloc(32).toString('base64'),
    x=>x.SURequireSignedFeed=false,x=>x.SUVerifyUpdateBeforeExtraction=false,x=>x.SUSendProfileInfo=true]) {
    const value=clone(valid);mutate(value);rejected(()=>validateBundleInfo(value,prefix,'20261020.25','stable'));
  }
  for(const build of ['20261020.26','20261020.27','bad']) rejected(()=>validateBundleInfo(valid,prefix,build,'stable'),'incompatible');
  rejected(()=>validateBundleInfo(valid,'https://evil.test/','20261020.25','stable'));
  rejected(()=>validateBundleInfo(valid,prefix,'20261020.25','nightly'));
});
test('preparation with missing arguments does not invoke a signing tool or create output', async () => {
  let calls=0;await assert.rejects(prepare({},async()=>{calls++;}),error=>error.code==='configurationMissing');assert.equal(calls,0);
});
test('explicit Keychain account never exports a key or falls back to an implicit account', () => {
  assert.deepEqual(signerArguments({keychainAccount:'arqmeter'},'/project','/app'),['--account','arqmeter']);
  rejected(()=>signerArguments({},'/project','/app'),'configurationMissing');
  rejected(()=>signerArguments({keychainAccount:'arqmeter',keyFile:'/file'},'/project','/app'),'configurationMissing');
  for(const value of ['--ed-key-file secret','a','account\nsecret',{},'x'.repeat(129)])
    rejected(()=>signerArguments({keychainAccount:value},'/project','/app'),'configurationMissing');
  assert.match(keyToolHash,/^[a-f0-9]{64}$/);
});
test('ad hoc signing is refused in Keychain mode before any Keychain tool is invoked', async () => {
  const directory=fs.mkdtempSync(path.resolve('Products.noindex/.keychain-preflight-fixture-'));
  const app=path.join(directory,'Fixture.app'),output=path.join(directory,'release');
  fs.mkdirSync(path.join(app,'Contents'),{recursive:true});fs.writeFileSync(path.join(app,'Contents/Info.plist'),'fixture');
  const calls=[];
  const execute=async(command,args)=>{
    calls.push(path.basename(command));
    if(command==='/usr/bin/plutil')return JSON.stringify(info(fixture().key));
    if(command==='/usr/bin/codesign')return args[0]==='-dvv' ? 'Signature=adhoc\nTeamIdentifier=not set' : '';
    assert.fail('No Keychain or later tool may run after an ad hoc identity');
  };
  try {
    await assert.rejects(prepare({app,output,tools:'unused',keychainAccount:'arqmeter',
      installedBuild:'20261020.25',downloadPrefix:'https://github.com/example/fixture/releases/download/v2/'},execute),
      error=>error.code==='signingUnavailable');
    assert.equal(fs.existsSync(output),false);assert.deepEqual(calls,['plutil','codesign','codesign']);
  } finally {fs.rmSync(directory,{recursive:true});}
});
test('publisher refuses ad hoc signing before reading a private key or creating output', async () => {
  const directory=fs.mkdtempSync(path.resolve('Products.noindex/.preflight-fixture-'));
  const app=path.join(directory,'Fixture.app'),output=path.join(directory,'release');
  fs.mkdirSync(path.join(app,'Contents'),{recursive:true});fs.writeFileSync(path.join(app,'Contents/Info.plist'),'fixture');
  const calls=[];
  const execute=async(command,args)=>{
    calls.push(path.basename(command));
    if(command==='/usr/bin/plutil')return JSON.stringify(info(fixture().key));
    if(command==='/usr/bin/codesign')return args[0]==='-dvv' ? 'Signature=adhoc\nTeamIdentifier=not set' : '';
    assert.fail('No later tool may run after an ad hoc identity');
  };
  try {
    await assert.rejects(prepare({app,output,tools:'unused',keyFile:path.join(directory,'does-not-exist'),
      installedBuild:'20261020.25',downloadPrefix:'https://github.com/example/fixture/releases/download/v2/'},execute),
      error=>error.code==='signingUnavailable');
    assert.equal(fs.existsSync(output),false);assert.deepEqual(calls,['plutil','codesign','codesign']);
  } finally {fs.rmSync(directory,{recursive:true});}
});
test('publisher preserves a pre-existing output and rejects a linked output parent', async () => {
  const directory=fs.mkdtempSync(path.resolve('Products.noindex/.output-fixture-'));
  const app=path.join(directory,'Fixture.app'),output=path.join(directory,'release');
  fs.mkdirSync(app);fs.mkdirSync(output);fs.writeFileSync(path.join(output,'keep'),'unchanged');
  const options={app,output,tools:'unused',keyFile:'unused',installedBuild:'1',downloadPrefix:'https://github.com/'};
  try {
    await assert.rejects(prepare(options,()=>assert.fail('No tool may run')),error=>error.code==='notWritable');
    assert.equal(fs.readFileSync(path.join(output,'keep'),'utf8'),'unchanged');
    fs.symlinkSync('/private/tmp',path.join(directory,'linked'));
    await assert.rejects(prepare({...options,output:path.join(directory,'linked',randomUUID())},
      ()=>assert.fail('No tool may run')),error=>error.code==='notWritable');
  } finally {fs.rmSync(directory,{recursive:true});}
});
test('bounded process runner rejects nonzero, reaps child and has a real timeout', async () => {
  assert.equal(await run(process.execPath,['-e','process.stdout.write("fixture")']), 'fixture');
  await assert.rejects(run(process.execPath,['-e','process.exit(3)']));
  await assert.rejects(run(process.execPath,['-e','setInterval(()=>{},1000)'],50));
});
test('timeout also stops a task-owned descendant, not only the tool parent', async () => {
  const directory=fs.mkdtempSync(path.resolve('Products.noindex/.process-fixture-'));
  const pidFile=path.join(directory,'child.pid');let childPID;
  const helper='process.on("SIGTERM",()=>{});setInterval(()=>{},1000)';
  const parent=`const cp=require('node:child_process'),fs=require('node:fs');
    const child=cp.spawn(process.execPath,['-e',${JSON.stringify(helper)}],{stdio:'ignore'});
    fs.writeFileSync(${JSON.stringify(pidFile)},String(child.pid));setInterval(()=>{},1000);`;
  try {
    await assert.rejects(run(process.execPath,['-e',parent],200));
    childPID=Number(fs.readFileSync(pidFile,'utf8'));
    const alive=()=>{try {process.kill(childPID,0);return true;}catch{return false;}};
    for(let index=0;index<30&&alive();index++)await new Promise(resolve=>setTimeout(resolve,20));
    assert.equal(alive(),false,'Task descendant must be reaped after timeout');
  } finally {
    // This PID was started by this exact fixture, never a pattern/age search.
    if(childPID) {try {process.kill(childPID,'SIGKILL');}catch{}}
    fs.rmSync(directory,{recursive:true});
  }
});

test('official SDK generates and validates a signed appcast over a real disposable app archive',
  {skip:!process.env.ARQ_SPARKLE_TOOLS}, async () => {
  const tools=path.resolve(process.env.ARQ_SPARKLE_TOOLS);
  for(const [name,hash] of Object.entries(toolHashes)) assert.equal(sha256(fs.readFileSync(path.join(tools,name))),hash);
  const directory=fs.mkdtempSync(path.resolve('Products.noindex/.release-fixture-'));
  fs.chmodSync(directory,0o700);
  let newGeneratorCache;
  try {
    const {keys,key}=fixture();
    const seed=keys.privateKey.export({type:'pkcs8',format:'der'});
    assert.equal(seed.length,48);assert.equal(seed.subarray(0,16).toString('hex'),'302e020100300506032b657004220420');
    const keyFile=path.join(directory,'ephemeral-seed');fs.writeFileSync(keyFile,seed.subarray(-32).toString('base64'),{mode:0o600});
    const app=path.join(directory,'Fixture.app'), output=path.join(directory,'output');
    fs.mkdirSync(path.join(app,'Contents/MacOS'),{recursive:true});fs.mkdirSync(output);
    fs.copyFileSync('/usr/bin/true',path.join(app,'Contents/MacOS/Fixture'));fs.chmodSync(path.join(app,'Contents/MacOS/Fixture'),0o755);
    const values={...info(key),CFBundleExecutable:'Fixture',CFBundleName:'Fixture',CFBundlePackageType:'APPL',
      LSMinimumSystemVersion:'13.0',SUFeedURL:'https://example.test/appcast.xml'};
    fs.writeFileSync(path.join(app,'Contents/Info.plist'),JSON.stringify(values));
    await run('/usr/bin/plutil',['-convert','xml1',path.join(app,'Contents/Info.plist')]);
    await run('/usr/bin/codesign',['--force','--sign','-',app]);
    const archive=path.join(output,'Fixture-2.zip');await run('/usr/bin/ditto',['-c','-k','--keepParent',app,archive]);
    const cachePath=path.join(os.homedir(),'Library/Caches/Sparkle_generate_appcast',sha256(fs.readFileSync(archive)));
    assert.equal(fs.existsSync(cachePath+'.tmp'),false);
    if(!fs.existsSync(cachePath))newGeneratorCache=cachePath;
    await run(path.join(tools,'generate_appcast'),['--ed-key-file',keyFile,'--maximum-deltas','0',
      '--download-url-prefix','https://example.test/fixtures/',output]);
    const feed=path.join(output,'appcast.xml');assert.equal(fs.existsSync(feed),true);
    await run(path.join(tools,'sign_update'),['--ed-key-file',keyFile,'--verify',feed]);
    const value=await run('/usr/bin/xmllint',['--nonet','--xpath',
      'string(/rss/channel/item/enclosure/@*[local-name()="edSignature"])',feed]);
    const bytes=fs.readFileSync(archive), record=fixture().release;
    record.artifact={url:'https://example.test/fixtures/Fixture-2.zip',sizeBytes:bytes.length,sha256:sha256(bytes),
      signature:{algorithm:'ed25519',value,publicKeyID:sha256(key)}};
    assert.equal(verifyArchive(bytes,record,key),true);
    const metadata=path.join(output,'release.json');fs.writeFileSync(metadata,JSON.stringify(record));
    const metadataSignature=await run(path.join(tools,'sign_update'),['--ed-key-file',keyFile,'-p',metadata]);
    assert.deepEqual(verifyReleaseMetadata(fs.readFileSync(metadata),metadataSignature,key),record);
    const original=fs.readFileSync(feed,'utf8'),modified=original.replace('20261020.26','20261020.99');
    assert.notEqual(original,modified);fs.writeFileSync(feed,modified);
    await assert.rejects(run(path.join(tools,'sign_update'),['--ed-key-file',keyFile,'--verify',feed]));
    console.log('Signed appcast/archive/metadata fixture verified; NO install, UI, profile, network or production key.');
  } finally {
    if(newGeneratorCache) {
      fs.rmSync(newGeneratorCache,{recursive:true,force:true});
      fs.rmSync(newGeneratorCache+'.tmp',{recursive:true,force:true});
    }
    fs.rmSync(directory,{recursive:true});
  }
});
