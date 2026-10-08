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
const USER_ID = 'test-affiliate-user-id-abcdef';

let server;
let baseUrl;
const realFetch = global.fetch;
const providerCalls = [];
let onlineReply;
let deletedReply;

function model(username, extra = {}) {
  return {
    id: Math.floor(Math.random() * 1e9),
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
  env.stripcash.userId = USER_ID;
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
  env.stripcash.userId = '';
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

test('sync upserts by username, updates last_seen_at, and marks absent models offline', async () => {
  await syncWith([model('a', { viewersCount: 5 }), model('b')]);
  const before = (await query(`SELECT last_seen_at FROM live_models WHERE username = 'a'`)).rows[0].last_seen_at;

  await new Promise((r) => setTimeout(r, 20));
  const result = await syncWith([model('a', { viewersCount: 50 }), model('c')]);
  assert.equal(result.status, 'synced');
  assert.equal(result.wentOffline, 1);

  const { rows } = await query('SELECT username, viewers_count, status, last_seen_at, provider_rank FROM live_models ORDER BY username');
  assert.deepEqual(rows.map((r) => [r.username, r.status]), [['a', 'public'], ['b', 'offline'], ['c', 'public']]);
  assert.equal(rows[0].viewers_count, 50);
  assert.ok(rows[0].last_seen_at > before, 'last_seen_at moves forward');
  assert.equal(rows[2].provider_rank, 2);
  const state = await live.getState();
  assert.equal(state.last_sync_ok, true);
  assert.equal(state.last_total, 7);
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
  await query(`UPDATE live_models SET last_seen_at = now() - interval '5 minutes' WHERE username = 'hindi'`);
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
    'avatarUrl', 'broadcastGender', 'country', 'favorites', 'gender', 'goal', 'id', 'isHd', 'isVr',
    'languages', 'provider', 'snapshotUrl', 'tags', 'thumbnailUrl', 'username', 'viewers',
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
  await syncWith([model('gone'), model('stays')]);
  deletedReply = () =>
    json(200, { count: 2, models: [{ username: 'gone', deletedAt: '2026-10-01T10:00:00Z', reason: 'banned' }, { username: 'never_stored', deletedAt: '2026-10-02T11:00:00Z', reason: 'offline' }] });
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
  assert.equal(new Date((await live.getState()).deleted_cursor).toISOString(), '2026-10-02T11:00:00.000Z');
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
