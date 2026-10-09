'use strict';

/**
 * Moco Live (Stripcash aggregator API): normalization, provider auth and
 * rate-limit handling, sync upsert, geoban filtering, listing rules, and the
 * deleted / 30-day cleanup. The provider is a stub; the database, Redis and
 * routes are real (local test instances).
 */

const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('http');

const { createApp } = require('../src/app');
const db = require('../src/config/db');
const redisConfig = require('../src/config/redis');
const env = require('../src/config/env');
const jobs = require('../src/jobs');
const stripcash = require('../src/integrations/stripcash');
const live = require('../src/modules/live/live.service');
const { handleLive } = require('../src/workers/live.worker');
const { resetDb, createUser } = require('./helpers');
const { query } = require('../src/config/db');
const { redis } = require('../src/config/redis');
const { signToken } = require('../src/middleware/auth');

const API_KEY = 'test-stripcash-key-0123456789';
const USER_ID = 'test-api-user-id-abcdef';
const PLAYER_ID = 'f'.repeat(64);

let server;
let baseUrl;
const realFetch = global.fetch;
const providerCalls = [];
let onlineReply;
let deletedReply;

function model(username, extra = {}) {
  return {
    // Stable per username, like the provider's own ids.
    id: [...username].reduce((h, c) => (h * 31 + c.charCodeAt(0)) % 1e9, 7),
    username,
    avatarUrl: `https://img.example/${username}/avatar.jpg`,
    popularSnapshotUrl: `https://img.example/${username}/popular.jpg`,
    snapshotUrl: `https://img.example/${username}/snap.jpg`,
    clickUrl: `https://go.example/${username}?userId=${USER_ID}`,
    modelsCountry: 'us',
    gender: 'female',
    broadcastGender: 'female',
    previewUrlThumbSmall: `https://img.example/${username}/thumb.jpg`,
    tags: ['girls', 'girls/asian'],
    favoritedCount: 100,
    viewersCount: 10,
    broadcastVR: false,
    broadcastHD: true,
    geobans: { blockedCountries: [], blockedRegions: {}, blockedLanguages: [] },
    status: 'public',
    goalMessage: null,
    neededForGoal: 0,
    earnedForGoal: 0,
    languages: ['en'],
    ...extra,
  };
}

const json = (status, body) => new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });

test.before(async () => {
  env.stripcash.apiKey = API_KEY;
  env.stripcash.apiUserId = USER_ID;
  env.stripcash.playerUserId = PLAYER_ID;
  global.fetch = async (url, init) => {
    const href = String(url);
    if (href.startsWith(env.stripcash.baseUrl)) {
      providerCalls.push({ url: new URL(href), auth: init?.headers?.Authorization });
      if (href.includes('/models/deleted')) return deletedReply();
      return onlineReply();
    }
    return realFetch(url, init);
  };
  await resetDb();
  server = http.createServer(createApp());
  await new Promise((resolve) => server.listen(0, resolve));
  baseUrl = `http://127.0.0.1:${server.address().port}`;
});

test.after(async () => {
  global.fetch = realFetch;
  env.stripcash.apiKey = '';
  env.stripcash.apiUserId = '';
  env.stripcash.playerUserId = '';
  await new Promise((resolve) => server.close(resolve));
  await db.close();
  await redisConfig.close();
});

test.beforeEach(async () => {
  providerCalls.length = 0;
  onlineReply = () => json(200, { count: 0, total: 0, models: [] });
  deletedReply = () => json(200, { count: 0, models: [] });
  jobs.clearRecordedJobs();
  await query('TRUNCATE live_models, live_provider_state');
  // The provider's 5-second slot is shared through Redis; each test starts free.
  await redis.del('live:stripcash:rate_slot', 'live:demand');
});

async function get(path, { token, headers = {} } = {}) {
  const res = await realFetch(`${baseUrl}${path}`, {
    headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), ...headers },
  });
  const text = await res.text();
  return { status: res.status, body: text ? JSON.parse(text) : null };
}

async function syncWith(models) {
  onlineReply = () => json(200, { count: models.length, total: models.length + 5, models });
  await redis.del('live:stripcash:rate_slot');
  return live.sync();
}

// --- normalization ----------------------------------------------------------

test('normalizes a provider model into the stored shape', () => {
  const m = stripcash.normalizeModel(
    model('Anna_X', {
      modelsCountry: 'UA',
      tags: ['Girls', 'girls/milfs', 'Girls'],
      languages: ['EN', 'uk'],
      geobans: { blockedCountries: ['RU'], blockedRegions: { us: ['tx', 'ny'] }, blockedLanguages: ['UK'] },
      goalMessage: 'Dance',
      neededForGoal: '500',
      earnedForGoal: 120,
      isNew: true,
      unknownNested: { a: 1 },
    }),
    3,
  );
  assert.equal(m.provider, 'stripcash');
  assert.equal(m.username, 'Anna_X');
  assert.equal(m.country, 'ua');
  assert.deepEqual(m.tags, ['girls', 'girls/milfs']);
  assert.deepEqual(m.languages, ['en', 'uk']);
  assert.deepEqual(m.blockedCountries, ['ru']);
  assert.deepEqual(m.blockedRegions.sort(), ['us.ny', 'us.tx']);
  assert.deepEqual(m.blockedRegionCountries, ['us']);
  assert.deepEqual(m.blockedLanguages, ['uk']);
  assert.equal(m.goalNeeded, 500);
  assert.equal(m.providerRank, 3);
  assert.equal(m.isHd, true);
  assert.equal(m.thumbUrl, 'https://img.example/Anna_X/thumb.jpg');
  assert.deepEqual(m.metadata, { isNew: true }, 'only flat unknown fields are kept as metadata');
});

test('regional bans accept both the object and the flat "us.tx" form', () => {
  assert.deepEqual(stripcash.normalizeRegions({ us: ['ny', 'va'] }), ['us.ny', 'us.va']);
  assert.deepEqual(stripcash.normalizeRegions(['US.TX']), ['us.tx']);
  assert.deepEqual(stripcash.normalizeRegions(null), []);
});

test('bad records are dropped and a malformed response is rejected', () => {
  const parsed = stripcash.parseModelsResponse({
    count: 3,
    total: 9,
    models: [model('a'), { id: 1 }, null, model('a'), model('b', { avatarUrl: 'javascript:alert(1)' })],
  });
  assert.deepEqual(parsed.models.map((m) => m.username), ['a', 'b']);
  assert.equal(parsed.models[1].avatarUrl, null, 'non-http image URLs are discarded');
  assert.equal(parsed.total, 9);
  assert.throws(() => stripcash.parseModelsResponse({ count: 1 }), { code: 'bad_response' });
});

// --- provider requests ------------------------------------------------------

test('requests the aggregator endpoint with Bearer auth and the userId', async () => {
  await syncWith([model('a')]);
  assert.equal(providerCalls.length, 1);
  const call = providerCalls[0];
  assert.equal(call.url.origin + call.url.pathname, 'https://go.whitetrafsa.com/app/models-ext/models');
  assert.equal(call.url.searchParams.get('userId'), USER_ID);
  assert.equal(call.auth, `Bearer ${API_KEY}`);
});

test('an auth failure is recorded, keeps stored data, and leaks no secret', async () => {
  await syncWith([model('kept')]);
  onlineReply = () => json(401, { error: 'unauthorized' });
  await redis.del('live:stripcash:rate_slot');

  const result = await live.sync();
  assert.deepEqual(result, { status: 'failed', error: 'auth_failed' });
  const state = await live.getState();
  assert.equal(state.last_sync_ok, false);
  assert.equal(state.last_sync_error, 'auth_failed');
  const { rows } = await query('SELECT username FROM live_models');
  assert.deepEqual(rows.map((r) => r.username), ['kept'], 'a failed fetch never wipes the list');
  assert.equal(JSON.stringify(state).includes(API_KEY), false);
});

test('never calls the provider more than once per 5 seconds', async () => {
  onlineReply = () => json(200, { count: 1, total: 1, models: [model('a')] });
  const first = await live.sync();
  const second = await live.sync();
  assert.equal(first.status, 'synced');
  assert.equal(second.status, 'rate_limited');
  assert.equal(providerCalls.length, 1);
});

test('without credentials Live is "not configured" and makes no calls', async () => {
  env.stripcash.apiKey = '';
  try {
    assert.deepEqual(await live.sync(), { status: 'not_configured' });
    const user = await createUser();
    const res = await get('/api/live/models', { token: signToken(user) });
    assert.equal(res.status, 200);
    assert.equal(res.body.available, false);
    assert.deepEqual(res.body.models, []);
    assert.equal(providerCalls.length, 0);
  } finally {
    env.stripcash.apiKey = API_KEY;
  }
});

// --- sync -------------------------------------------------------------------

test('sync writes only changed rows, keeps counters in the snapshot, and marks absent models offline', async () => {
  const first = await syncWith([model('a', { viewersCount: 5 }), model('b')]);
  assert.deepEqual([first.inserted, first.updated, first.unchanged], [2, 0, 0]);
  const before = (await query(`SELECT updated_at, last_seen_at FROM live_models WHERE username = 'a'`)).rows[0];

  await new Promise((r) => setTimeout(r, 20));
  // a: only counters/rank change → no row write; c: new; b: gone.
  const result = await syncWith([model('c'), model('a', { viewersCount: 50, favoritedCount: 7 })]);
  assert.equal(result.status, 'synced');
  assert.deepEqual([result.inserted, result.updated, result.unchanged, result.wentOffline], [1, 0, 1, 1]);

  const { rows } = await query('SELECT username, status, updated_at, last_seen_at FROM live_models ORDER BY username');
  assert.deepEqual(rows.map((r) => [r.username, r.status]), [['a', 'public'], ['b', 'offline'], ['c', 'public']]);
  assert.equal(rows[0].updated_at.getTime(), before.updated_at.getTime(), 'unchanged row is not rewritten');
  assert.equal(rows[0].last_seen_at.getTime(), before.last_seen_at.getTime(), 'last_seen_at is refreshed lazily');

  const state = await live.getState();
  assert.equal(state.last_sync_ok, true);
  assert.equal(state.last_total, 7);
  assert.deepEqual(state.live_snapshot.a, [2, 50, 7, 0, 0], 'rank, viewers, favorites, goal');
  assert.deepEqual(Object.keys(state.live_snapshot).sort(), ['a', 'c'], 'the snapshot is the online set');

  // A meaningful change (tags) rewrites the row.
  const third = await syncWith([model('c'), model('a', { tags: ['girls/new'] })]);
  assert.deepEqual([third.updated, third.unchanged], [1, 1]);
});

test('last_seen_at is refreshed in bulk once it is older than the refresh interval', async () => {
  await syncWith([model('a')]);
  await query(`UPDATE live_models SET last_seen_at = now() - interval '7 hours' WHERE username = 'a'`);
  const result = await syncWith([model('a')]);
  assert.equal(result.seenRefreshed, 1);
  const { rows } = await query(`SELECT last_seen_at FROM live_models WHERE username = 'a'`);
  assert.ok(Date.now() - rows[0].last_seen_at.getTime() < 60_000);
});

test('snapshot image URLs: the response-wide timestamp is templated, not rewritten per row', async () => {
  const shot = (ts, id) => `https://img.doppiocdn.com/thumbs/${ts}/${id}`;
  await syncWith([model('a', { id: 11, snapshotUrl: shot(1791000000, 11) }), model('b', { id: 12, snapshotUrl: shot(1791000000, 12) })]);
  const stored = (await query(`SELECT snapshot_url FROM live_models WHERE username = 'a'`)).rows[0].snapshot_url;
  assert.equal(stored, 'https://img.doppiocdn.com/thumbs/{ts}/11');

  const next = await syncWith([model('a', { id: 11, snapshotUrl: shot(1791000030, 11) }), model('b', { id: 12, snapshotUrl: shot(1791000030, 12) })]);
  assert.equal(next.unchanged, 2, 'a new snapshot timestamp alone writes no rows');

  const token = signToken(await createUser());
  const res = await get('/api/live/models', { token, headers: { 'cf-ipcountry': 'DE' } });
  assert.equal(res.body.models.find((m) => m.username === 'a').snapshotUrl, shot(1791000030, 11), 'served with the current timestamp');
});

test('raw stream URLs and CDN hints are never stored', () => {
  const m = stripcash.normalizeModel(
    model('s', { stream: { url: 'https://x/hls/1.m3u8' }, hlsPlaylist: 'https://x/a.m3u8', CDNDefaultHost: 'cdn.x', note: 'https://x/live/hls/2' , other: 'kept' }),
    1,
  );
  assert.deepEqual(Object.keys(m.metadata), ['other']);
});

test('"all online" is an allowlist: unknown future statuses stay hidden', async () => {
  const liveSettings = require('../src/modules/live/live.settings');
  await syncWith([
    model('pub'), model('p2p_one', { status: 'p2p' }), model('grp', { status: 'groupShow' }),
    model('vp', { status: 'virtualPrivate' }), model('voice', { status: 'p2pVoice' }), model('priv', { status: 'private' }),
    model('future', { status: 'superShow' }),
  ]);
  const viewer = { country: 'de', region: null, languages: [] };
  const all = await live.list(viewer, { limit: 50 }, { ...liveSettings.DEFAULTS, status: 'any' });
  assert.deepEqual(all.map((m) => m.username).sort(), ['grp', 'p2p_one', 'priv', 'pub', 'voice', 'vp']);
  const pub = await live.list(viewer, { limit: 50 }, liveSettings.DEFAULTS);
  assert.deepEqual(pub.map((m) => m.username), ['pub'], 'default listing is public only');
});

test('a stale snapshot (syncs stopped) lists nothing', async () => {
  await syncWith([model('a')]);
  await query(`UPDATE live_provider_state SET last_ok_sync_at = now() - interval '10 minutes'`);
  const out = await live.list({ country: 'de', region: null, languages: [] }, { limit: 10 });
  assert.deepEqual(out, []);
});

test('the sync job re-schedules itself only while Live has viewers', async () => {
  onlineReply = () => json(200, { count: 0, total: 0, models: [] });
  const idle = await handleLive({ data: { task: 'sync' } });
  assert.equal(idle.rescheduled, false);
  assert.equal(jobs.recordedJobs().length, 0);

  await live.noteDemand();
  await redis.del('live:stripcash:rate_slot');
  const busy = await handleLive({ data: { task: 'sync' } });
  assert.equal(busy.rescheduled, true);
  const queued = jobs.recordedJobs().filter((j) => j.topic === jobs.TOPICS.LIVE);
  assert.equal(queued.length, 1);
  assert.equal(queued[0].delaySeconds, 30);
});

// --- listing + geobans ------------------------------------------------------

async function seedForListing() {
  await syncWith([
    model('open', { viewersCount: 5, favoritedCount: 900, broadcastHD: false }),
    model('ban_ua', { viewersCount: 50, geobans: { blockedCountries: ['ua'], blockedRegions: {}, blockedLanguages: [] } }),
    model('ban_tx', { viewersCount: 40, geobans: { blockedCountries: [], blockedRegions: { us: ['tx'] }, blockedLanguages: [] } }),
    model('ban_uk_lang', { viewersCount: 30, geobans: { blockedCountries: [], blockedRegions: {}, blockedLanguages: ['uk'] } }),
    model('private_one', { status: 'private', viewersCount: 99 }),
    model('hindi', { languages: ['hi'], modelsCountry: 'in', tags: ['girls/indian'], viewersCount: 1 }),
  ]);
}

const names = (res) => res.body.models.map((m) => m.username).sort();

test('geobans: blocked country, region and language are hidden', async () => {
  await seedForListing();
  const token = signToken(await createUser());

  const fromUkraine = await get('/api/live/models', { token, headers: { 'cf-ipcountry': 'UA', 'accept-language': 'uk-UA,uk;q=0.9' } });
  assert.deepEqual(names(fromUkraine), ['ban_tx', 'hindi', 'open']);

  const fromTexas = await get('/api/live/models', { token, headers: { 'cf-ipcountry': 'US', 'cf-region-code': 'TX', 'accept-language': 'en-US' } });
  assert.deepEqual(names(fromTexas), ['ban_ua', 'ban_uk_lang', 'hindi', 'open']);

  const fromCalifornia = await get('/api/live/models', { token, headers: { 'x-vercel-ip-country': 'US', 'x-vercel-ip-country-region': 'CA' } });
  assert.deepEqual(names(fromCalifornia), ['ban_tx', 'ban_ua', 'ban_uk_lang', 'hindi', 'open']);
});

test('geobans fail closed when the viewer location is unknown', async () => {
  await seedForListing();
  const token = signToken(await createUser());

  const unknown = await get('/api/live/models', { token });
  assert.deepEqual(names(unknown), ['ban_uk_lang', 'hindi', 'open'], 'country and regional bans hide the model');

  const usNoRegion = await get('/api/live/models', { token, headers: { 'cf-ipcountry': 'US' } });
  assert.deepEqual(names(usNoRegion), ['ban_ua', 'ban_uk_lang', 'hindi', 'open'], 'a US regional ban hides it from US viewers of unknown region');

  const tor = await get('/api/live/models', { token, headers: { 'cf-ipcountry': 'T1' } });
  assert.deepEqual(names(tor), names(unknown));
});

test('no query parameter can bypass geobans', async () => {
  await seedForListing();
  const token = signToken(await createUser());
  const res = await get('/api/live/models?geobans=0&applyGeobans=0&admin=1&country=us', {
    token,
    headers: { 'cf-ipcountry': 'UA' },
  });
  assert.equal(res.status, 200);
  assert.equal(names(res).includes('ban_ua'), false);
});

test('listing: public and recently seen only, normalized fields, no provider secrets', async () => {
  await seedForListing();
  // Not in the latest sync → not online.
  await query(`UPDATE live_provider_state SET live_snapshot = live_snapshot - 'hindi'`);
  const token = signToken(await createUser());

  const res = await get('/api/live/models', { token, headers: { 'cf-ipcountry': 'DE' } });
  assert.equal(res.status, 200);
  assert.equal(res.body.available, true);
  assert.deepEqual(names(res), ['ban_tx', 'ban_ua', 'ban_uk_lang', 'open']);
  const body = JSON.stringify(res.body);
  for (const secret of [API_KEY, USER_ID, 'clickUrl', 'geobans', 'blocked']) {
    assert.equal(body.includes(secret), false, `${secret} must not be in the response`);
  }
  const m = res.body.models.find((x) => x.username === 'open');
  assert.deepEqual(Object.keys(m).sort(), [
    'avatarUrl', 'broadcastGender', 'country', 'favorites', 'featured', 'gender', 'goal', 'id', 'isHd', 'isVr',
    'languages', 'provider', 'snapshotUrl', 'status', 'tags', 'thumbnailUrl', 'username', 'viewers',
  ]);
});

test('listing: sorting, filters and limits', async () => {
  await seedForListing();
  const token = signToken(await createUser());
  const h = { 'cf-ipcountry': 'DE' };
  const order = async (q) => (await get(`/api/live/models${q}`, { token, headers: h })).body.models.map((m) => m.username);

  assert.deepEqual(await order(''), ['open', 'ban_ua', 'ban_tx', 'ban_uk_lang', 'hindi'], 'provider order');
  assert.deepEqual(await order('?sort=viewers'), ['ban_ua', 'ban_tx', 'ban_uk_lang', 'open', 'hindi']);
  assert.equal((await order('?sort=favorites'))[0], 'open');
  assert.equal((await order('?sort=hd')).at(-1), 'open', 'non-HD last');
  assert.deepEqual(await order('?language=hi'), ['hindi']);
  assert.deepEqual(await order('?country=in'), ['hindi']);
  assert.deepEqual(await order('?tag=girls/indian'), ['hindi']);
  assert.deepEqual(await order('?limit=2'), ['open', 'ban_ua']);
  assert.deepEqual(await order('?limit=2&offset=2'), ['ban_tx', 'ban_uk_lang']);

  assert.equal((await get('/api/live/models?limit=500', { token })).status, 400);
  assert.equal((await get('/api/live/models?sort=random', { token })).status, 400);
  assert.equal((await get('/api/live/models')).status, 401, 'signed-in users only');
});

test('a listing request starts the sync chain and refreshes stale data', async () => {
  onlineReply = () => json(200, { count: 1, total: 1, models: [model('fresh')] });
  const token = signToken(await createUser());
  const res = await get('/api/live/models', { token, headers: { 'cf-ipcountry': 'DE' } });
  assert.deepEqual(names(res), ['fresh'], 'stale (never synced) data is refreshed inline');
  assert.equal(await live.hasDemand(), true);
  assert.equal(jobs.recordedJobs().filter((j) => j.topic === jobs.TOPICS.LIVE).length, 1);

  // Fresh data: no second provider call.
  await get('/api/live/models', { token });
  assert.equal(providerCalls.length, 1);
});

// --- cleanup ----------------------------------------------------------------

test('cleanup removes provider-deleted models and advances the cursor', async () => {
  // Inside the default 7-day window, relative to now (fixed dates go stale).
  const newestDeletion = new Date(Date.now() - 3600_000).toISOString();
  await syncWith([model('gone'), model('stays')]);
  deletedReply = () =>
    json(200, { count: 2, models: [{ username: 'gone', deletedAt: new Date(Date.now() - 2 * 86400_000).toISOString(), reason: 'banned' }, { username: 'never_stored', deletedAt: newestDeletion, reason: 'offline' }] });
  await redis.del('live:stripcash:rate_slot');

  const result = await live.cleanup();
  assert.equal(result.deletedCheck, 'ok');
  assert.equal(result.deletedRemoved, 1);
  const { rows } = await query('SELECT username FROM live_models');
  assert.deepEqual(rows.map((r) => r.username), ['stays']);

  const call = providerCalls.at(-1);
  assert.equal(call.url.pathname, '/app/models-ext/models/deleted');
  assert.equal(call.auth, `Bearer ${API_KEY}`);
  assert.ok(call.url.searchParams.get('deleted_since'));
  assert.equal(new Date((await live.getState()).deleted_cursor).toISOString(), newestDeletion);
});

test('cleanup removes models absent for 30 days, even without the provider', async () => {
  await syncWith([model('old'), model('recent')]);
  await query(`UPDATE live_models SET last_seen_at = now() - interval '31 days' WHERE username = 'old'`);
  await query(`UPDATE live_models SET last_seen_at = now() - interval '29 days' WHERE username = 'recent'`);
  deletedReply = () => json(503, {});
  await redis.del('live:stripcash:rate_slot');

  const result = await live.cleanup();
  assert.equal(result.absentRemoved, 1);
  assert.equal(result.deletedCheck, 'http_error');
  const { rows } = await query('SELECT username FROM live_models');
  assert.deepEqual(rows.map((r) => r.username), ['recent']);
});

test('the daily cleanup is queued once per day', async () => {
  await jobs.liveCleanup();
  await jobs.liveCleanup();
  const queued = jobs.recordedJobs().filter((j) => j.topic === jobs.TOPICS.LIVE);
  assert.equal(queued.length, 2, 'record mode keeps both; Vercel dedupes by the shared key');
  assert.equal(queued[0].idempotencyKey, queued[1].idempotencyKey);
  assert.equal(queued[0].payload.task, 'cleanup');
});

// --- client config / age gate -----------------------------------------------

test('GET /api/live/config exposes the player userId and the age gate, never the API key', async () => {
  await query(`DELETE FROM app_settings WHERE key = 'live'`);
  const token = signToken(await createUser());
  const res = await get('/api/live/config', { token });
  assert.equal(res.status, 200);
  const liveSettings = require('../src/modules/live/live.settings');
  assert.deepEqual(res.body, {
    enabled: true,
    provider: 'stripcash',
    ...liveSettings.clientView(liveSettings.DEFAULTS),
    player: { type: 'stripchat-player', userId: PLAYER_ID, strict: 1, autoplay: 'all', scriptUrl: null },
  });
  assert.equal(JSON.stringify(res.body).includes(USER_ID), false, 'the API user id stays server-side');
  assert.equal(res.body.requireAgeConfirmation, true);
  assert.equal('selection' in res.body, false, 'curation lists stay admin-side');
  assert.equal(JSON.stringify(res.body).includes(API_KEY), false);
  assert.equal((await get('/api/live/config')).status, 401);
});

test('the age gate stays on unless explicitly turned off', async () => {
  const token = signToken(await createUser());
  const setLive = (value) =>
    query(
      `INSERT INTO app_settings (key, value) VALUES ('live', $1)
       ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value`,
      [JSON.stringify(value)],
    );
  await setLive({ requireAgeConfirmation: 'no' });
  assert.equal((await get('/api/live/config', { token })).body.requireAgeConfirmation, true);
  await setLive({ requireAgeConfirmation: false });
  assert.equal((await get('/api/live/config', { token })).body.requireAgeConfirmation, false);
  await query(`DELETE FROM app_settings WHERE key = 'live'`);
});

test('Live switched off: no player config, no models, no provider calls', async () => {
  await syncWith([model('a')]);
  providerCalls.length = 0;
  await query(`INSERT INTO app_settings (key, value) VALUES ('live', '{"enabled": false}')
               ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value`);
  try {
    const token = signToken(await createUser());
    const config = await get('/api/live/config', { token });
    assert.equal(config.body.enabled, false);
    assert.equal(config.body.player, null);
    const list = await get('/api/live/models', { token, headers: { 'cf-ipcountry': 'DE' } });
    assert.equal(list.body.available, false);
    assert.deepEqual(list.body.models, []);
    assert.equal(providerCalls.length, 0);
  } finally {
    await query(`DELETE FROM app_settings WHERE key = 'live'`);
  }
});

// --- Admin → Settings → Live (Task 2) ----------------------------------------

const liveSettings = require('../src/modules/live/live.settings');
const ADMIN_PHONE_ENV = process.env.ADMIN_PHONES;

async function adminToken() {
  const admin = await createUser();
  process.env.ADMIN_PHONES = admin.phone;
  return signToken(admin);
}

async function send(method, path, token, body) {
  const res = await realFetch(`${baseUrl}${path}`, {
    method,
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}`, 'cf-ipcountry': 'DE' },
    body: body ? JSON.stringify(body) : undefined,
  });
  return { status: res.status, body: await res.json() };
}

const withSettings = (patch) => {
  const s = JSON.parse(JSON.stringify(liveSettings.DEFAULTS));
  for (const [k, v] of Object.entries(patch)) {
    if (v && typeof v === 'object' && !Array.isArray(v) && s[k] && typeof s[k] === 'object') Object.assign(s[k], v);
    else s[k] = v;
  }
  return s;
};

async function seedRanked() {
  await syncWith([
    model('r1', { viewersCount: 10, favoritedCount: 5, broadcastHD: false, languages: ['en'] }),
    model('r2', { viewersCount: 90, favoritedCount: 1, languages: ['en'] }),
    model('r3', { viewersCount: 50, favoritedCount: 900, languages: ['hi'], modelsCountry: 'in' }),
    model('r4', { viewersCount: 30, favoritedCount: 3, status: 'groupShow' }),
    model('r5', { viewersCount: 70, favoritedCount: 4, geobans: { blockedCountries: ['de'], blockedRegions: {}, blockedLanguages: [] } }),
  ]);
}

test.afterEach(() => {
  if (ADMIN_PHONE_ENV === undefined) delete process.env.ADMIN_PHONES;
  else process.env.ADMIN_PHONES = ADMIN_PHONE_ENV;
});

test('admin settings: defaults, save, reload, audit; admin-only', async () => {
  await query(`DELETE FROM app_settings WHERE key = 'live'`);
  const token = await adminToken();
  const first = await send('GET', '/api/admin/live/settings', token);
  assert.equal(first.status, 200);
  assert.deepEqual({ ...first.body.settings, updatedAt: undefined }, { ...liveSettings.DEFAULTS, updatedAt: undefined });
  assert.equal(first.body.provider.configured, true);
  assert.equal(JSON.stringify(first.body).includes(API_KEY), false);

  const next = withSettings({
    enabled: false,
    pageSize: 12,
    layout: { preset: 'mixed', columns: { mobile: 1, tablet: 2, desktop: 6 }, aspect: 'wide', density: 'compact', radius: 'large' },
    card: { tags: true, goal: true, viewers: false },
    selection: { mode: 'all_except_blocked', featured: ['r3', 'r1'], hidden: ['r2'], selected: [] },
    sort: 'featured',
    clickBehavior: 'provider',
    preferredLanguage: 'HI',
  });
  const saved = await send('PUT', '/api/admin/live/settings', token, { settings: next });
  assert.equal(saved.status, 200);
  const reloaded = (await send('GET', '/api/admin/live/settings', token)).body.settings;
  assert.equal(reloaded.enabled, false);
  assert.equal(reloaded.layout.preset, 'mixed');
  assert.equal(reloaded.layout.columns.desktop, 6);
  assert.equal(reloaded.card.viewers, false);
  assert.deepEqual(reloaded.selection.featured, ['r3', 'r1']);
  assert.equal(reloaded.preferredLanguage, 'hi');
  assert.ok(reloaded.updatedAt);
  const { rows } = await query(`SELECT action FROM admin_audit_log WHERE action = 'settings.live.update'`);
  assert.equal(rows.length >= 1, true);

  const user = signToken(await createUser());
  assert.equal((await send('GET', '/api/admin/live/settings', user)).status, 403);
  assert.equal((await send('PUT', '/api/admin/live/settings', user, { settings: next })).status, 403);
  await query(`DELETE FROM app_settings WHERE key = 'live'`);
});

test('admin settings: invalid values are rejected field by field', async () => {
  const token = await adminToken();
  const bad = withSettings({ pageSize: 500, layout: { preset: 'masonry' }, selection: { mode: 'all', featured: ['bad name!'], hidden: [], selected: [] } });
  const res = await send('PUT', '/api/admin/live/settings', token, { settings: bad });
  assert.equal(res.status, 400);
  const fields = res.body.error.details.map((d) => d.field);
  assert.ok(fields.includes('pageSize'));
  assert.ok(fields.includes('layout.preset'));
  assert.ok(fields.includes('selection.featured.0'));
});

test('no setting can override geobans', async () => {
  await seedRanked();
  const token = await adminToken();
  const sneaky = { ...withSettings({ selection: { mode: 'selected', featured: ['r5'], hidden: [], selected: ['r5'] } }), geobans: false, applyGeobans: false, ignoreGeobans: true };
  await send('PUT', '/api/admin/live/settings', token, { settings: sneaky });
  const stored = (await query(`SELECT value FROM app_settings WHERE key = 'live'`)).rows[0].value;
  assert.equal(Object.keys(stored).some((k) => /geoban/i.test(k)), false, 'unknown keys are not stored');

  const preview = await send('POST', '/api/admin/live/preview', token, { settings: sneaky });
  assert.deepEqual(preview.body.models.map((m) => m.username), [], 'r5 is geobanned in DE even when explicitly selected');
  const listing = await get('/api/live/models', { token: signToken(await createUser()), headers: { 'cf-ipcountry': 'DE' } });
  assert.deepEqual(listing.body.models, []);
  await query(`DELETE FROM app_settings WHERE key = 'live'`);
});

test('selection modes, featured and hidden', async () => {
  await seedRanked();
  const token = await adminToken();
  const preview = async (patch) =>
    (await send('POST', '/api/admin/live/preview', token, { settings: withSettings(patch) })).body.models.map((m) => m.username);

  // r4 is a group show (public only by default); r5 is geobanned for DE.
  assert.deepEqual(await preview({}), ['r1', 'r2', 'r3']);
  assert.deepEqual(await preview({ status: 'any' }), ['r1', 'r2', 'r3', 'r4']);
  assert.deepEqual(await preview({ selection: { mode: 'all', featured: [], hidden: ['r2'], selected: [] } }), ['r1', 'r3'], 'an explicitly hidden model stays hidden in "all" too');
  assert.deepEqual(await preview({ selection: { mode: 'all_except_blocked', featured: [], hidden: ['r2'], selected: [] } }), ['r1', 'r3']);
  assert.deepEqual(await preview({ selection: { mode: 'selected', featured: [], hidden: ['r3'], selected: ['r3', 'r2'] } }), ['r2']);
  assert.deepEqual(
    await preview({ sort: 'featured', selection: { mode: 'all', featured: ['r3', 'r2'], hidden: [], selected: [] } }),
    ['r3', 'r2', 'r1'],
    'featured first, in the admin order',
  );
  const res = await send('POST', '/api/admin/live/preview', token, {
    settings: withSettings({ sort: 'featured', selection: { mode: 'all', featured: ['r3'], hidden: [], selected: [] } }),
  });
  assert.equal(res.body.models.find((m) => m.username === 'r3').featured, true);
  assert.equal(res.body.models.find((m) => m.username === 'r1').featured, false);
  assert.equal(res.body.viewer.country, 'de');
});

test('sorting and preferences', async () => {
  await seedRanked();
  const token = await adminToken();
  const order = async (patch) =>
    (await send('POST', '/api/admin/live/preview', token, { settings: withSettings(patch) })).body.models.map((m) => m.username);
  assert.deepEqual(await order({ sort: 'default' }), ['r1', 'r2', 'r3']);
  assert.deepEqual(await order({ sort: 'viewers' }), ['r2', 'r3', 'r1']);
  assert.deepEqual(await order({ sort: 'favorites' }), ['r3', 'r1', 'r2']);
  assert.deepEqual(await order({ sort: 'hd' }), ['r2', 'r3', 'r1']);
  assert.deepEqual(await order({ preferredLanguage: 'hi' }), ['r3', 'r1', 'r2'], 'preferred language is boosted, not filtered');
  assert.deepEqual(await order({ pageSize: 6, preferredCountry: 'in', sort: 'viewers' }), ['r3', 'r2', 'r1']);
});

test('public listing follows the saved settings; click behaviour controls the provider link', async () => {
  await seedRanked();
  const token = await adminToken();
  const userToken = signToken(await createUser());
  const list = async () => (await get('/api/live/models', { token: userToken, headers: { 'cf-ipcountry': 'DE' } })).body;

  await send('PUT', '/api/admin/live/settings', token, {
    settings: withSettings({ pageSize: 6, sort: 'viewers', selection: { mode: 'all_except_blocked', featured: [], hidden: ['r2'], selected: [] } }),
  });
  let body = await list();
  assert.equal(body.limit, 6);
  assert.equal(body.sort, 'viewers');
  assert.deepEqual(body.models.map((m) => m.username), ['r3', 'r1']);
  assert.equal('destinationUrl' in body.models[0], false, 'internal player: no provider link');

  const config = (await get('/api/live/config', { token: userToken })).body;
  assert.equal(config.pageSize, 6);
  assert.equal(config.clickBehavior, 'internal_player');

  await send('PUT', '/api/admin/live/settings', token, { settings: withSettings({ clickBehavior: 'provider' }) });
  body = await list();
  assert.match(body.models[0].destinationUrl, /^https:\/\/go\.example\//);
  assert.equal((await get('/api/live/config', { token: userToken })).body.clickBehavior, 'provider');

  await send('PUT', '/api/admin/live/settings', token, { settings: withSettings({ enabled: false }) });
  body = await list();
  assert.equal(body.available, false);
  assert.deepEqual(body.models, []);
  await query(`DELETE FROM app_settings WHERE key = 'live'`);
});

test('admin model search lists stored models for the pickers', async () => {
  await seedRanked();
  await query(`UPDATE live_models SET last_seen_at = now() - interval '2 days', status = 'offline' WHERE username = 'r1'`);
  await query(`UPDATE live_provider_state SET live_snapshot = live_snapshot - 'r1'`);
  const token = await adminToken();
  const res = await send('GET', '/api/admin/live/models?q=r', token);
  assert.equal(res.status, 200);
  const r1 = res.body.models.find((m) => m.username === 'r1');
  assert.equal(r1.online, false, 'offline models can still be picked');
  assert.equal(res.body.models[0].online, true, 'online first');
  assert.equal(JSON.stringify(res.body).includes('blocked'), false);
  const none = await send('GET', '/api/admin/live/models?q=%25', token);
  assert.deepEqual(none.body.models, [], 'LIKE wildcards are matched literally');
});

test('a stored document with a bad value falls back to that default, and the age gate stays on', async () => {
  await query(
    `INSERT INTO app_settings (key, value) VALUES ('live', $1)
     ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value`,
    [JSON.stringify({ pageSize: 9999, layout: { preset: 'grid', radius: 'huge' }, sort: 'viewers' })],
  );
  const s = await liveSettings.read();
  assert.equal(s.pageSize, liveSettings.DEFAULTS.pageSize);
  assert.equal(s.layout.radius, liveSettings.DEFAULTS.layout.radius);
  assert.equal(s.sort, 'viewers');
  assert.equal(s.requireAgeConfirmation, true);
  await query(`DELETE FROM app_settings WHERE key = 'live'`);
});
