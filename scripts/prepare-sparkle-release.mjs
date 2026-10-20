#!/usr/bin/env node
// PREPARATION ONLY: never uploads, installs, signs code, creates keys or changes
// settings. Requires an already configured, Developer ID signed/notarized app.
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath } from 'node:url';
import { spawn } from 'node:child_process';
import { schemaVersion, UpdateError, httpsURL, sha256, validateRelease, verifyArchive, verifyReleaseMetadata } from './update-contract.mjs';

export const toolHashes = Object.freeze({
  sign_update: '43c249771bafc3aa581228abae00731a012d324691b8292860896635050be76b',
  generate_appcast: '59e48e8432433cf4358519027e67e2c66a7348e0fe415f75f67b3b2372c13844',
});
export const keyToolHash = 'c37679f98d9121981cf7b2d18592fdc8b44931bffa604acf10c9e11791b6222e';
const requireValue = (value, code) => { if (!value) throw new UpdateError(code); };
export function signerArguments({keyFile, keychainAccount}, root, appPath) {
  requireValue(Boolean(keyFile) !== Boolean(keychainAccount), 'configurationMissing');
  if (keychainAccount) {
    requireValue(typeof keychainAccount === 'string' && /^[A-Za-z0-9._-]{3,128}$/.test(keychainAccount), 'configurationMissing');
    // Explicit account only. No implicit global Keychain lookup, key creation,
    // export, import, password argument or environment-carried secret.
    return ['--account', keychainAccount];
  }
  const keyPath=fs.realpathSync(keyFile), keyStat=fs.lstatSync(keyFile);
  requireValue(keyStat.isFile() && keyStat.uid === process.getuid() &&
    (keyStat.mode & 0o077) === 0 && !keyPath.startsWith(root + path.sep) &&
    !keyPath.startsWith(appPath + path.sep), 'configurationMissing');
  return ['--ed-key-file', keyPath];
}
// Dedicated process groups: timeout/interruption kills only children started by
// this invocation, including generator extraction helpers. No shell/key output.
export async function run(command, args, timeout = 60000) {
  return await new Promise((resolve, reject) => {
    const child = spawn(command, args, {detached: true, stdio: ['ignore', 'pipe', 'pipe']});
    let output = '', stopped = false, force;
    const stop = () => {
      if (stopped) return; stopped = true;
      try { process.kill(-child.pid, 'SIGTERM'); } catch {}
      force = setTimeout(() => { try { process.kill(-child.pid, 'SIGKILL'); } catch {} }, 1000);
    };
    const timer = setTimeout(stop, timeout);
    process.once('SIGINT', stop); process.once('SIGTERM', stop);
    const collect = bytes => { output = (output + bytes.toString()).slice(0,262145); if (output.length > 262144) stop(); };
    child.stdout.on('data', collect); child.stderr.on('data', collect);
    const cleanup = () => { clearTimeout(timer); clearTimeout(force);
      process.removeListener('SIGINT', stop); process.removeListener('SIGTERM', stop); };
    child.on('error', () => { cleanup(); reject(new UpdateError('unknown')); });
    child.on('close', code => {
      if (stopped) { try { process.kill(-child.pid, 'SIGKILL'); } catch {} }
      cleanup();
      if (stopped || code !== 0) reject(new UpdateError('signingUnavailable')); else resolve(output.trim()); });
  });
}
export function validateBundleInfo(info, downloadPrefix, installedBuild, channel) {
  requireValue(info.SURequireSignedFeed === true && info.SUVerifyUpdateBeforeExtraction === true &&
    info.SUSendProfileInfo === false && typeof info.SUFeedURL === 'string' &&
    typeof info.SUPublicEDKey === 'string', 'configurationMissing');
  const feed = httpsURL(info.SUFeedURL);
  requireValue(feed.pathname.endsWith('.xml'), 'configurationMissing');
  const key = Buffer.from(info.SUPublicEDKey ?? '', 'base64');
  requireValue(key.length === 32 && key.some(byte => byte !== 0) &&
    key.toString('base64') === info.SUPublicEDKey, 'configurationMissing');
  const hosts = [feed.hostname, ...(info.ARQUpdateDownloadHosts ?? [])];
  requireValue(hosts.every(host => typeof host === 'string' && httpsURL(`https://${host}`).hostname === host),
    'configurationMissing');
  const prefix = httpsURL(downloadPrefix, hosts);
  requireValue(prefix.pathname.endsWith('/'), 'configurationMissing');
  requireValue(['stable', 'prerelease'].includes(channel), 'configurationMissing');
  // Publisher builds are deliberately decimal components. Native Sparkle remains
  // authoritative for installed-app version ordering and compatibility.
  const newer = (next, old) => {
    if (!/^\d+(?:\.\d+)*$/.test(next ?? '') || !/^\d+(?:\.\d+)*$/.test(old ?? '')) return false;
    const left = next.split('.').map(BigInt), right = old.split('.').map(BigInt);
    for (let index=0; index<Math.max(left.length,right.length); index++) {
      if ((left[index] ?? 0n) !== (right[index] ?? 0n)) return (left[index] ?? 0n) > (right[index] ?? 0n);
    } return false;
  };
  requireValue(newer(info.CFBundleVersion, installedBuild) &&
    /^[0-9]+(?:\.[0-9]+){1,3}$/.test(info.CFBundleShortVersionString ?? ''), 'incompatible');
  return {feed, key, hosts, prefix};
}
export async function prepare(options, execute = run) {
  const {app, tools, keyFile, keychainAccount, output, downloadPrefix, installedBuild, channel = 'stable'} = options;
  requireValue(app && tools && (Boolean(keyFile) !== Boolean(keychainAccount)) && output && downloadPrefix && installedBuild, 'configurationMissing');
  const root = path.resolve(fileURLToPath(new URL('..', import.meta.url)));
  const appPath = fs.realpathSync(app), outputPath = path.resolve(output);
  requireValue(appPath.endsWith('.app') && path.basename(appPath).match(/^[A-Za-z0-9_-]+\.app$/), 'configurationMissing');
  requireValue(outputPath.startsWith(path.join(root, 'Products.noindex') + path.sep) &&
    !fs.existsSync(outputPath), 'notWritable');
  const parent = fs.realpathSync(path.dirname(outputPath)), products = fs.realpathSync(path.join(root, 'Products.noindex'));
  requireValue(parent === products || parent.startsWith(products + path.sep), 'notWritable');
  const originalInfo = fs.readFileSync(`${appPath}/Contents/Info.plist`);
  const info = JSON.parse(await execute('/usr/bin/plutil', ['-convert', 'json', '-o', '-', `${appPath}/Contents/Info.plist`]));
  const configuration = validateBundleInfo(info, downloadPrefix, installedBuild, channel);
  await execute('/usr/bin/codesign', ['--verify', '--deep', '--strict', appPath]);
  const signature = await execute('/usr/bin/codesign', ['-dvv', appPath]);
  requireValue(/Authority=Developer ID Application:/.test(signature) && /TeamIdentifier=[A-Z0-9]{10}\b/.test(signature), 'signingUnavailable');
  await execute('/usr/sbin/spctl', ['--assess', '--type', 'execute', appPath]);
  await execute('/usr/bin/xcrun', ['stapler', 'validate', appPath]);
  const signer=signerArguments({keyFile,keychainAccount},root,appPath);
  for (const [name, expected] of Object.entries(toolHashes)) {
    requireValue(sha256(fs.readFileSync(path.join(tools, name))) === expected, 'signingUnavailable');
  }
  if (keychainAccount) {
    const keyTool=path.join(tools,'generate_keys');
    requireValue(sha256(fs.readFileSync(keyTool)) === keyToolHash, 'signingUnavailable');
    // -p is lookup-only in the pinned official tool. It fails on a missing
    // account and never creates or exports a private key. Only public output.
    const existingPublicKey=await execute(keyTool,['--account',keychainAccount,'-p']);
    requireValue(existingPublicKey === info.SUPublicEDKey, 'signingUnavailable');
  }
  const executable = path.join(appPath, 'Contents/MacOS', info.CFBundleExecutable);
  const slices = (await execute('/usr/bin/lipo', ['-archs', executable])).split(/\s+/).sort();
  const architecture = slices.join(',') === 'arm64,x86_64' ? 'universal2' : slices.length === 1 ? slices[0] : null;
  requireValue(['arm64','x86_64','universal2'].includes(architecture), 'incompatible');
  fs.mkdirSync(outputPath, {mode: 0o700});
  let completed = false, newGeneratorCache;
  try {
    const filename = `${path.basename(appPath, '.app')}-${info.CFBundleShortVersionString}-${architecture}.zip`;
    const archive = path.join(outputPath, filename);
    await execute('/usr/bin/ditto', ['-c', '-k', '--sequesterRsrc', '--keepParent', appPath, archive]);
    const value = await execute(path.join(tools, 'sign_update'), [...signer, '-p', archive]);
    const bytes = fs.readFileSync(archive);
    const record = {schemaVersion, productID: info.CFBundleIdentifier,
      version: info.CFBundleShortVersionString, build: info.CFBundleVersion, platform: 'macos',
      architecture, channel, artifact: {url: new URL(filename, configuration.prefix).href,
        sizeBytes: bytes.length, sha256: sha256(bytes),
        signature: {algorithm: 'ed25519', value, publicKeyID: sha256(configuration.key)}}};
    validateRelease(record, configuration.hosts);
    verifyArchive(bytes, record, configuration.key); // Must match embedded public key.
    // Validate the exact archive, not only a mutable source bundle. No installed
    // app or user profile is touched; this extraction is exclusively task output.
    const validation = path.join(outputPath, '.validation');
    fs.mkdirSync(validation, {mode:0o700});
    await execute('/usr/bin/ditto', ['-x', '-k', archive, validation]);
    const archivedApp = path.join(validation, path.basename(appPath));
    requireValue(sha256(fs.readFileSync(`${archivedApp}/Contents/Info.plist`)) === sha256(originalInfo), 'invalidArchive');
    await execute('/usr/bin/codesign', ['--verify', '--deep', '--strict', archivedApp]);
    const archivedSignature = await execute('/usr/bin/codesign', ['-dvv', archivedApp]);
    requireValue(archivedSignature.match(/TeamIdentifier=([A-Z0-9]{10})\b/)?.[1] ===
      signature.match(/TeamIdentifier=([A-Z0-9]{10})\b/)?.[1], 'invalidArchive');
    await execute('/usr/sbin/spctl', ['--assess', '--type', 'execute', archivedApp]);
    await execute('/usr/bin/xcrun', ['stapler', 'validate', archivedApp]);
    fs.rmSync(validation, {recursive:true});
    const args = [...signer, '--download-url-prefix', configuration.prefix.href,
      '--maximum-deltas', '0', '--maximum-versions', '2', '--versions', info.CFBundleVersion];
    if (channel === 'prerelease') args.push('--channel', 'prerelease');
    const cachePath = path.join(os.homedir(), 'Library/Caches/Sparkle_generate_appcast', record.artifact.sha256);
    requireValue(!fs.existsSync(cachePath+'.tmp'), 'notWritable');
    if (!fs.existsSync(cachePath)) newGeneratorCache = cachePath;
    await execute(path.join(tools, 'generate_appcast'), [...args, outputPath]);
    const feedPath = path.join(outputPath, path.basename(configuration.feed.pathname));
    await execute(path.join(tools, 'sign_update'), [...signer, '--verify', feedPath]);
    const xpath = async expression => await execute('/usr/bin/xmllint', ['--nonet', '--xpath', expression, feedPath]);
    requireValue(await xpath('count(/rss/channel/item)') === '1', 'invalidFeed');
    requireValue(await xpath('string(/rss/channel/item/enclosure/@url)') === record.artifact.url &&
      await xpath('string(/rss/channel/item/enclosure/@length)') === String(bytes.length) &&
      await xpath('string(/rss/channel/item/*[local-name()="version"])') === record.build &&
      await xpath('string(/rss/channel/item/enclosure/@*[local-name()="edSignature"])') === value &&
      await xpath('string(/rss/channel/item/*[local-name()="channel"])') === (channel === 'stable' ? '' : channel), 'invalidFeed');
    // Independent signed metadata for non-Sparkle adapters/catalogs, bound to
    // the same trusted key and exact archive. Never trust the JSON alone.
    const manifestPath=path.join(outputPath,'release.json');
    fs.writeFileSync(manifestPath, JSON.stringify(record, null, 2) + '\n', {flag:'wx'});
    const manifestSignature=await execute(path.join(tools,'sign_update'),[...signer,'-p',manifestPath]);
    verifyReleaseMetadata(fs.readFileSync(manifestPath),manifestSignature,configuration.key,configuration.hosts);
    fs.writeFileSync(path.join(outputPath,'release.json.ed25519'),manifestSignature+'\n',{flag:'wx'});
    fs.writeFileSync(path.join(outputPath, 'preparation.json'), JSON.stringify({
      prepared: true, published: false, installed: false, feedURL: configuration.feed.href,
      feedSHA256: sha256(fs.readFileSync(feedPath)), nativeUpdateTested: false,
    }, null, 2) + '\n', {flag:'wx'});
    completed = true;
    return record;
  } finally {
    // Pinned SDK 2.10.0 caches extracted archives by their SHA256. Remove only
    // this invocation's newly created extraction, never a pre-existing cache.
    if (newGeneratorCache) {
      fs.rmSync(newGeneratorCache, {recursive:true,force:true});
      fs.rmSync(newGeneratorCache+'.tmp', {recursive:true,force:true});
    }
    // Exclusively created task output only. Never touch the input app/key,
    // a prior output, a backup, data directory or installed application.
    if (!completed) fs.rmSync(outputPath, {recursive:true});
  }
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const names = {'--app':'app','--tools':'tools','--key-file':'keyFile','--keychain-account':'keychainAccount','--output':'output',
    '--download-prefix':'downloadPrefix','--installed-build':'installedBuild','--channel':'channel'};
  const options = {};
  try {
    const args = process.argv.slice(2);
    for (let index=0; index<args.length; index+=2) {
      const name = names[args[index]];
      requireValue(name && args[index+1] && !Object.hasOwn(options,name), 'configurationMissing');
      options[name] = args[index+1];
    }
    const record = await prepare(options);
    console.log(JSON.stringify({state:'prepared', release:record, published:false, installed:false}));
  } catch (error) {
    console.error(JSON.stringify({state:'blocked', errorCode:error instanceof UpdateError ? error.code : 'configurationMissing',
      published:false, installed:false}));
    process.exitCode = 1; // No raw tool output, key, private path or credential.
  }
}
