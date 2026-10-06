// Synthetic DOM fixtures, not observed account values; no browser/network.
import { readFileSync } from 'node:fs';
import { runInNewContext } from 'node:vm';
import assert from 'node:assert/strict';
const script = readFileSync(new URL('../Resources/claude-official-usage.js', import.meta.url), 'utf8');
function fixture({ value = '25', textValue = '25', max = '100', min = '0', reset = 'Resets in 3 hours', weekly = true, host = 'claude.ai', path = '/settings/usage', contextOnly = false, title = 'Your usage' } = {}) {
  const heading = { innerText: title };
  const make = (label, raw, displayed) => {
    const anchor = { innerText: label, children: [] };
    const bar = { getAttribute: key => ({ 'aria-valuenow': raw, 'aria-valuemax': max, 'aria-valuemin': min })[key] ?? null };
    const card = { innerText: `${label}\n${reset}\n${displayed} % used`, parentElement: null,
      querySelectorAll: selector => selector.includes('progressbar') ? [bar] : [] };
    anchor.parentElement = card; return anchor;
  };
  const nodes = [make(contextOnly ? 'Context window' : 'Current session', value, textValue)];
  if (weekly) nodes.push(make('All models', '4', '4'));
  const document = { querySelectorAll: selector => selector === 'h1,h2,h3' ? [heading] : nodes };
  Object.defineProperty(document, 'cookie', { get() { throw new Error('Cookies must never be read'); } });
  return JSON.parse(JSON.stringify(runInNewContext(script, { location: { protocol: 'https:', hostname: host, pathname: path }, document }, { timeout: 100 })));
}
assert.equal(fixture().session.usedPercent, 25);
assert.equal(fixture().weekly.usedPercent, 4);
assert.equal(fixture({ value: '100', textValue: '100' }).session.usedPercent, 100);
for (const value of ['', ' ', 'NaN', '-1', '101']) assert.equal(fixture({ value, weekly: false }).recognized, false);
assert.equal(fixture({ value: '0', textValue: '0' }).session.usedPercent, 0);
assert.equal(fixture({ value: '25', textValue: '26', weekly: false }).recognized, false);
for (const max of ['', ' ', '200']) assert.equal(fixture({ max, weekly: false }).recognized, false);
assert.equal(fixture({ min: '1', weekly: false }).recognized, false);
assert.equal(fixture({ contextOnly: true, weekly: false }).recognized, false);
assert.equal(fixture({ host: 'other.test' }).recognized, false);
assert.equal(fixture({ path: '/chat/private' }).recognized, false);
for (const title of ['Plan usage limits', 'Usage', "Limites d'utilisation du forfait"]) assert.equal(fixture({ title }).session.usedPercent, 25);
for (const title of ['Settings', 'Billing', 'Usages']) assert.equal(fixture({ title }).recognized, false);
console.log('Official-page extractor: 24 synthetic checks PASS; empty≠0, exhausted=100, no context/cookie read, wrong page and conflicting values rejected. Not real-account validation.');
