// Read-only, official usage route only. Never reads inputs, cookies, storage,
// scripts, account details or conversations. Unknown/ambiguous layouts fail closed.
(() => {
  const absent = { recognized: false, session: null, weekly: null };
  if (location.protocol !== 'https:' || location.hostname !== 'claude.ai' ||
      location.pathname.replace(/\/+$/, '') !== '/settings/usage') return absent;
  const normalize = s => (s || '').replace(/\s+/g, ' ').trim().toLocaleLowerCase();
  const headings = [...document.querySelectorAll('h1,h2,h3')].slice(0, 80);
  if (!headings.some(e => ['usage', 'your usage', 'votre utilisation', 'utilisation'].includes(normalize(e.innerText)))) return absent;
  const nodes = [...document.querySelectorAll('h2,h3,h4,p,span,div,label')].slice(0, 5000)
    .filter(e => e.children.length === 0);
  const resetPattern = /^(resets?\b|reset\b|réinitialisation\b|se réinitialise\b)/i;
  const usedPattern = /(\d+(?:[.,]\d+)?)\s*%\s*(?:used|utilis[ée]s?|consomm[ée]s?)/gi;
  const find = labels => {
    const results = [];
    for (const anchor of nodes.filter(e => labels.includes(normalize(e.innerText)))) {
      let container = anchor.parentElement;
      for (let depth = 0; container && depth < 6; depth++, container = container.parentElement) {
        const text = container.innerText || '';
        if (text.length > 600) break;
        const percents = [...text.matchAll(usedPattern)].map(m => Number(m[1].replace(',', '.')));
        const unique = [...new Set(percents)];
        if (unique.length > 1) break;
        const bars = [...container.querySelectorAll('[role="progressbar"],[role="meter"]')];
        if (bars.length > 1) break;
        const bar = bars[0];
        const raw = bar?.getAttribute('aria-valuenow');
        const max = bar?.getAttribute('aria-valuemax');
        const min = bar?.getAttribute('aria-valuemin');
        const explicitNumber = s => typeof s === 'string' && /^\d+(?:\.\d+)?$/.test(s.trim());
        if (bar && (raw != null && !explicitNumber(raw) || max != null && (!explicitNumber(max) || Number(max) !== 100) ||
                    min != null && (!explicitNumber(min) || Number(min) !== 0))) break;
        const value = explicitNumber(raw) ? Number(raw) : unique[0];
        if (!Number.isFinite(value) || value < 0 || value > 100) continue;
        if (unique.length === 1 && value !== unique[0]) break;
        const reset = text.split(/\r?\n/).map(s => s.trim()).find(s => resetPattern.test(s));
        // Continue one level if needed to include the reset, but never merge cards.
        if (!reset && depth < 2) continue;
        const times = [...container.querySelectorAll('time[datetime]')];
        const iso = times.length === 1 ? times[0].getAttribute('datetime') : null;
        const resetISO = iso && Number.isFinite(Date.parse(iso)) ? new Date(iso).toISOString().replace('.000Z', 'Z') : null;
        results.push({ usedPercent: value, resetLabel: reset?.slice(0, 120) || null, resetISO });
        break;
      }
    }
    const distinct = [...new Set(results.map(v => JSON.stringify(v)))];
    return distinct.length === 1 ? JSON.parse(distinct[0]) : null;
  };
  const session = find(['current session', 'session actuelle']);
  const weekly = find(['all models', 'tous les modèles', 'this week', 'cette semaine']);
  return { recognized: session !== null || weekly !== null, session, weekly };
})()
