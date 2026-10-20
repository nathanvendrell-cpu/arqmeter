// Reference validation only. Not an installer, trust store, network client or
// replacement for the native updater's signature/version/compatibility checks.
import { createHash, createPublicKey, verify } from 'node:crypto';

export const schemaVersion = '7agency.app-update.v1';
export const states = Object.freeze(['unconfigured', 'idle', 'checking', 'upToDate',
  'available', 'downloading', 'readyToInstall', 'installing', 'relaunching',
  'succeeded', 'cancelled', 'blocked', 'failed']);
export const errorCodes = Object.freeze(['configurationMissing', 'signingUnavailable',
  'network', 'invalidFeed', 'invalidArchive', 'incompatible', 'notWritable',
  'userCancelled', 'installFailed', 'relaunchUnverified', 'unknown']);
export class UpdateError extends Error {
  constructor(code) { super(code); this.code = code; }
}
const requireValue = (test, code = 'invalidFeed') => { if (!test) throw new UpdateError(code); };
const exactKeys = (object, expected) => object && typeof object === 'object' &&
  !Array.isArray(object) && Object.keys(object).length === expected.length &&
  expected.every(key => Object.hasOwn(object, key));
const text = value => typeof value === 'string' && /^[A-Za-z0-9][A-Za-z0-9.+_-]{0,79}$/.test(value);
const hex = value => typeof value === 'string' && /^[a-f0-9]{64}$/.test(value);
const base64 = (value, length) => typeof value === 'string' &&
  Buffer.from(value, 'base64').length === length && Buffer.from(value, 'base64').toString('base64') === value;
export const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');
export function httpsURL(value, allowedHosts) {
  let url;
  try { url = new URL(value); } catch { throw new UpdateError('invalidFeed'); }
  requireValue(typeof value === 'string' && url.protocol === 'https:' && !url.username &&
    !url.password && !url.search && !url.hash && (!url.port || url.port === '443'));
  if (allowedHosts) requireValue(Array.isArray(allowedHosts) && allowedHosts.includes(url.hostname), 'incompatible');
  return url;
}
export function validateRelease(record, allowedHosts) {
  requireValue(exactKeys(record, ['schemaVersion', 'productID', 'version', 'build',
    'platform', 'architecture', 'channel', 'artifact']));
  requireValue(record.schemaVersion === schemaVersion &&
    typeof record.productID === 'string' && /^[a-zA-Z0-9-]+(?:\.[a-zA-Z0-9-]+){2,}$/.test(record.productID));
  requireValue(text(record.version) && text(record.build) && ['macos', 'windows', 'linux'].includes(record.platform));
  requireValue(['arm64', 'x86_64', 'universal2'].includes(record.architecture) &&
    (record.architecture !== 'universal2' || record.platform === 'macos'));
  requireValue(['stable', 'prerelease'].includes(record.channel));
  const artifact = record.artifact;
  requireValue(exactKeys(artifact, ['url', 'sizeBytes', 'sha256', 'signature']));
  httpsURL(artifact.url, allowedHosts);
  requireValue(Number.isSafeInteger(artifact.sizeBytes) && artifact.sizeBytes > 0 && hex(artifact.sha256));
  requireValue(exactKeys(artifact.signature, ['algorithm', 'value', 'publicKeyID']) &&
    artifact.signature.algorithm === 'ed25519' && base64(artifact.signature.value, 64) &&
    hex(artifact.signature.publicKeyID));
  return record; // Shape and transport policy only; NOT authentication.
}
export function evaluateRelease(record, context) {
  validateRelease(record, context.allowedHosts);
  requireValue(context.allowedHosts?.length > 0, 'configurationMissing');
  requireValue(record.productID === context.productID && record.platform === context.platform &&
    (record.architecture === context.architecture ||
      record.platform === 'macos' && record.architecture === 'universal2' &&
      ['arm64','x86_64'].includes(context.architecture)), 'incompatible');
  requireValue(record.channel === 'stable' || context.includePrerelease === true, 'incompatible');
  requireValue(context.nativeVersionIsNewer === true && context.nativeCompatibilityPassed === true,
    'incompatible');
  requireValue(context.metadataSignatureVerified === true, 'invalidFeed');
  return record;
}
export function verifyArchive(bytes, record, trustedRawPublicKey) {
  validateRelease(record);
  requireValue(Buffer.isBuffer(bytes) && Buffer.isBuffer(trustedRawPublicKey) && trustedRawPublicKey.length === 32,
    'configurationMissing');
  requireValue(sha256(trustedRawPublicKey) === record.artifact.signature.publicKeyID &&
    bytes.length === record.artifact.sizeBytes && sha256(bytes) === record.artifact.sha256,
    'invalidArchive');
  const key = createPublicKey({format: 'der', type: 'spki',
    key: Buffer.concat([Buffer.from('302a300506032b6570032100', 'hex'), trustedRawPublicKey])});
  requireValue(verify(null, bytes, key, Buffer.from(record.artifact.signature.value, 'base64')), 'invalidArchive');
  return true;
}
export function verifyReleaseMetadata(bytes, signature, trustedRawPublicKey, allowedHosts) {
  requireValue(Buffer.isBuffer(bytes) && bytes.length <= 131072 && base64(signature,64) &&
    Buffer.isBuffer(trustedRawPublicKey) && trustedRawPublicKey.length === 32, 'invalidFeed');
  const key=createPublicKey({format:'der',type:'spki',
    key:Buffer.concat([Buffer.from('302a300506032b6570032100','hex'),trustedRawPublicKey])});
  requireValue(verify(null,bytes,key,Buffer.from(signature,'base64')), 'invalidFeed');
  let record;
  try {record=JSON.parse(bytes.toString('utf8'));} catch {throw new UpdateError('invalidFeed');}
  validateRelease(record,allowedHosts);
  requireValue(record.artifact.signature.publicKeyID === sha256(trustedRawPublicKey), 'invalidFeed');
  return record; // Authenticated metadata; native product/version checks still required.
}
export function validateStatus(status) {
  requireValue(exactKeys(status, ['schemaVersion', 'productID', 'operationID', 'updatedAt',
    'state', 'installedBuild', 'target', 'downloadedBytes', 'errorCode', 'retryable']));
  requireValue(status.schemaVersion === schemaVersion && text(status.installedBuild) &&
    typeof status.productID === 'string' && /^[a-zA-Z0-9-]+(?:\.[a-zA-Z0-9-]+){2,}$/.test(status.productID));
  requireValue(typeof status.operationID === 'string' && /^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/.test(status.operationID) &&
    typeof status.updatedAt === 'string' && Number.isFinite(Date.parse(status.updatedAt)) &&
    new Date(status.updatedAt).toISOString() === status.updatedAt && states.includes(status.state));
  requireValue(typeof status.retryable === 'boolean' &&
    (status.errorCode === null || errorCodes.includes(status.errorCode)));
  if (status.target !== null) {
    validateRelease(status.target);
    requireValue(status.target.productID === status.productID);
  }
  if (['available', 'downloading', 'readyToInstall', 'installing', 'relaunching', 'succeeded'].includes(status.state))
    requireValue(status.target !== null);
  if (status.state === 'succeeded') requireValue(status.installedBuild === status.target.build);
  if (['unconfigured', 'blocked', 'failed'].includes(status.state)) requireValue(status.errorCode !== null);
  if (!['unconfigured', 'blocked', 'failed', 'cancelled'].includes(status.state)) requireValue(status.errorCode === null);
  requireValue(status.downloadedBytes === null || Number.isSafeInteger(status.downloadedBytes) &&
    status.downloadedBytes >= 0 && status.target !== null && status.downloadedBytes <= status.target.artifact.sizeBytes);
  return status;
}
