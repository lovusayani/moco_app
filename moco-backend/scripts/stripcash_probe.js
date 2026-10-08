'use strict';

/**
 * One read-only request to the Stripcash aggregator API, reporting only the
 * SHAPE of the answer: HTTP status, field names and types, status values,
 * documented-vs-actual fields, and the clickUrl structure with every value
 * hidden. Never prints the API key, the userId, usernames or URLs.
 *
 * Touches no database and no Redis. Usage (reads STRIPCASH_* from .env):
 *   node scripts/stripcash_probe.js
 */
require('dotenv').config();

const DOCUMENTED = [
  'id', 'username', 'avatarUrl', 'popularSnapshotUrl', 'snapshotUrl', 'clickUrl', 'modelsCountry', 'gender',
  'broadcastGender', 'previewUrlThumbSmall', 'tags', 'favoritedCount', 'viewersCount', 'broadcastVR', 'broadcastHD',
  'geobans', 'status', 'goalMessage', 'neededForGoal', 'earnedForGoal', 'languages',
];

const typeOf = (v) =>
  v === null ? 'null' : Array.isArray(v) ? `array<${[...new Set(v.map(typeOf))].join('|') || 'empty'}>` : typeof v;

const hasGeoban = (m) =>
  m.geobans &&
  ((m.geobans.blockedCountries || []).length ||
    Object.keys(m.geobans.blockedRegions || {}).length ||
    (m.geobans.blockedLanguages || []).length);

function tally(models, pick) {
  const out = {};
  for (const m of models) {
    const k = String(pick(m));
    out[k] = (out[k] || 0) + 1;
  }
  return out;
}

async function main() {
  const key = (process.env.STRIPCASH_API_KEY || '').trim();
  const userId = (process.env.STRIPCASH_USER_ID || '').trim();
  if (!key || !userId) {
    console.log('STRIPCASH_API_KEY / STRIPCASH_USER_ID not set — nothing sent.');
    process.exit(2);
  }
  const base = process.env.STRIPCASH_API_BASE || 'https://go.whitetrafsa.com';
  const url = new URL('/app/models-ext/models', base);
  url.searchParams.set('userId', userId);

  const started = Date.now();
  const res = await fetch(url, {
    headers: { Authorization: `Bearer ${key}`, Accept: 'application/json' },
    signal: AbortSignal.timeout(30000),
  });
  const text = await res.text();
  console.log(`HTTP ${res.status} in ${Date.now() - started} ms, ${text.length} bytes, ${res.headers.get('content-type')}`);
  let body;
  try {
    body = JSON.parse(text);
  } catch {
    console.log('Body is not JSON.');
    return;
  }
  if (!res.ok) {
    console.log('Error body fields:', Object.keys(body || {}).join(', '));
    return;
  }

  console.log('Top-level fields:', Object.entries(body).map(([k, v]) => `${k}: ${typeOf(v)}`).join(', '));
  console.log('count:', body.count, '| total:', body.total, '| models.length:', body.models?.length);
  const models = Array.isArray(body.models) ? body.models : [];
  if (!models.length) return;

  const types = {};
  for (const m of models) for (const [k, v] of Object.entries(m)) (types[k] ??= new Set()).add(typeOf(v));
  console.log('\nModel fields (types seen across all models):');
  for (const [k, t] of Object.entries(types)) console.log(`  ${k}: ${[...t].join(' | ')}`);

  const missing = DOCUMENTED.map((k) => [k, models.filter((m) => !(k in m)).length]).filter(([, n]) => n);
  console.log(`\nDocumented fields missing (count of ${models.length} models):`, missing.map(([k, n]) => `${k} (${n})`).join(', ') || 'none');
  console.log('Undocumented fields:', Object.keys(types).filter((k) => !DOCUMENTED.includes(k)).join(', ') || 'none');

  console.log('\nstatus values:', JSON.stringify(tally(models, (m) => m.status)));
  console.log('gender values:', JSON.stringify(tally(models, (m) => m.gender)));
  console.log('broadcastGender values:', JSON.stringify(tally(models, (m) => m.broadcastGender)));

  const withBans = models.filter(hasGeoban);
  console.log('\nmodels with any geoban:', withBans.length);
  const g = withBans[0]?.geobans;
  if (g) {
    const regions = g.blockedRegions;
    console.log('geobans shape:', JSON.stringify({
      blockedCountries: typeOf(g.blockedCountries),
      blockedRegions: Array.isArray(regions) ? typeOf(regions) : `object<country → ${[...new Set(Object.values(regions || {}).map(typeOf))].join('|') || 'empty'}>`,
      blockedLanguages: typeOf(g.blockedLanguages),
    }));
    const regionKeys = withBans.flatMap((m) => (Array.isArray(m.geobans.blockedRegions) ? m.geobans.blockedRegions : Object.entries(m.geobans.blockedRegions || {}).flatMap(([c, rs]) => (rs || []).map((r) => `${c}.${r}`))));
    console.log('regional ban format sample:', JSON.stringify(regionKeys.slice(0, 4)));
    console.log('country ban format sample:', JSON.stringify(withBans.flatMap((m) => m.geobans.blockedCountries || []).slice(0, 4)));
    console.log('language ban format sample:', JSON.stringify(withBans.flatMap((m) => m.geobans.blockedLanguages || []).slice(0, 4)));
  }
  console.log('tag format sample:', JSON.stringify(models.find((m) => (m.tags || []).length)?.tags.slice(0, 3)));
  console.log('languages format sample:', JSON.stringify(models.find((m) => (m.languages || []).length)?.languages));
  console.log('modelsCountry format sample:', JSON.stringify([...new Set(models.map((m) => m.modelsCountry).filter(Boolean))].slice(0, 5)));

  // clickUrl: structure only — origin, path with the username masked, parameter NAMES.
  const shapes = {};
  for (const m of models) {
    let shape = '(not a URL)';
    try {
      const u = new URL(m.clickUrl);
      const name = String(m.username).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
      const path = u.pathname.replace(new RegExp(name, 'gi'), '{username}').replace(/[A-Za-z0-9_-]{16,}/g, '{token}');
      shape = `${u.origin}${path}?${[...u.searchParams.keys()].sort().join('&')}`;
    } catch {
      /* counted as not a URL */
    }
    shapes[shape] = (shapes[shape] || 0) + 1;
  }
  console.log('\nclickUrl shapes (values hidden):');
  for (const [s, n] of Object.entries(shapes).slice(0, 5)) console.log(`  ${n}× ${s}`);
  console.log('clickUrl contains the affiliate userId:', models.some((m) => String(m.clickUrl).includes(userId)));

  const hosts = new Set();
  for (const m of models.slice(0, 300)) {
    for (const f of ['avatarUrl', 'snapshotUrl', 'previewUrlThumbSmall', 'popularSnapshotUrl']) {
      try {
        hosts.add(new URL(m[f]).host);
      } catch {
        /* null or empty */
      }
    }
  }
  console.log('image hosts:', [...hosts].join(', '));
}

main().catch((err) => {
  console.log('Probe failed:', err.name, err.code || '');
  process.exit(1);
});
