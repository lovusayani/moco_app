'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('http');

const { createApp } = require('../src/app');
const db = require('../src/config/db');
const redisConfig = require('../src/config/redis');
const queues = require('../src/workers/queues');
const { resetDb, createUser } = require('./helpers');
const { signToken } = require('../src/middleware/auth');

let server;
let baseUrl;

test.before(async () => {
  await resetDb();
  server = http.createServer(createApp());
  await new Promise((resolve) => server.listen(0, resolve));
  baseUrl = `http://127.0.0.1:${server.address().port}`;
});

test.after(async () => {
  await new Promise((resolve) => server.close(resolve));
  await queues.closeAll();
  await db.close();
  await redisConfig.close();
});

async function call(method, path, { token, body } = {}) {
  const response = await fetch(`${baseUrl}${path}`, {
    method,
    headers: {
      'Content-Type': 'application/json',
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await response.text();
  return { status: response.status, body: text ? JSON.parse(text) : null };
}

/** A listener discovery will actually return: approved and named. */
async function createDiscoverableListener({ name, bio = null, audio = true, video = true }) {
  const user = await createUser({ listener: true });
  await db.query('UPDATE users SET display_name = $2 WHERE id = $1', [user.id, name]);
  await db.query(
    `UPDATE listener_profiles
        SET bio = $2, accepts_audio = $3, accepts_video = $4, is_online = TRUE
      WHERE user_id = $1`,
    [user.id, bio, audio, video],
  );
  return user;
}

test('search matches on display name, server-side', async () => {
  await resetDb();
  const caller = await createUser({ balance: 100 });
  await createDiscoverableListener({ name: 'Priya' });
  await createDiscoverableListener({ name: 'Kavya' });

  const token = signToken(caller);
  const all = await call('GET', '/api/listeners', { token });
  assert.equal(all.body.listeners.length, 2);

  const search = await call('GET', '/api/listeners?q=riy', { token });
  assert.equal(search.status, 200);
  assert.equal(search.body.listeners.length, 1);
  assert.equal(search.body.listeners[0].name, 'Priya');
});

test('search also matches on bio', async () => {
  await resetDb();
  const caller = await createUser({ balance: 100 });
  await createDiscoverableListener({ name: 'Ananya', bio: 'Loves astronomy talk' });
  await createDiscoverableListener({ name: 'Meera', bio: 'Cricket fan' });

  const result = await call('GET', '/api/listeners?q=astronomy', {
    token: signToken(caller),
  });
  assert.equal(result.body.listeners.length, 1);
  assert.equal(result.body.listeners[0].name, 'Ananya');
});

test('search is case-insensitive', async () => {
  await resetDb();
  const caller = await createUser({ balance: 100 });
  await createDiscoverableListener({ name: 'Priya' });

  const result = await call('GET', '/api/listeners?q=PRIYA', {
    token: signToken(caller),
  });
  assert.equal(result.body.listeners.length, 1);
});

test('search returning nothing is an empty page, not an error', async () => {
  await resetDb();
  const caller = await createUser({ balance: 100 });
  await createDiscoverableListener({ name: 'Priya' });

  const result = await call('GET', '/api/listeners?q=zzzznotfound', {
    token: signToken(caller),
  });
  assert.equal(result.status, 200);
  assert.deepEqual(result.body.listeners, []);
  assert.equal(result.body.nextOffset, null);
});

test('search composes with filters rather than replacing them', async () => {
  await resetDb();
  const caller = await createUser({ balance: 100 });
  const hindi = await createDiscoverableListener({ name: 'Priya Sharma' });
  const telugu = await createDiscoverableListener({ name: 'Priya Reddy' });
  await db.query(`UPDATE listener_profiles SET languages = ARRAY['hi'] WHERE user_id = $1`, [
    hindi.id,
  ]);
  await db.query(`UPDATE listener_profiles SET languages = ARRAY['te'] WHERE user_id = $1`, [
    telugu.id,
  ]);

  const token = signToken(caller);
  assert.equal((await call('GET', '/api/listeners?q=Priya', { token })).body.listeners.length, 2);

  const filtered = await call('GET', '/api/listeners?q=Priya&language=te', { token });
  assert.equal(filtered.body.listeners.length, 1);
  assert.equal(filtered.body.listeners[0].name, 'Priya Reddy');
});

test('callType filters to listeners who take that call type', async () => {
  await resetDb();
  const caller = await createUser({ balance: 100 });
  await createDiscoverableListener({ name: 'AudioOnly', audio: true, video: false });
  await createDiscoverableListener({ name: 'VideoOnly', audio: false, video: true });
  await createDiscoverableListener({ name: 'Both', audio: true, video: true });

  const token = signToken(caller);

  const audio = await call('GET', '/api/listeners?callType=audio', { token });
  const audioNames = audio.body.listeners.map((l) => l.name).sort();
  assert.deepEqual(audioNames, ['AudioOnly', 'Both']);

  const video = await call('GET', '/api/listeners?callType=video', { token });
  const videoNames = video.body.listeners.map((l) => l.name).sort();
  assert.deepEqual(videoNames, ['Both', 'VideoOnly']);

  // No toggle applied means no capability filter.
  const none = await call('GET', '/api/listeners', { token });
  assert.equal(none.body.listeners.length, 3);
});

test('a listener must accept at least one call type', async () => {
  await resetDb();
  const listener = await createDiscoverableListener({ name: 'Nobody' });

  await assert.rejects(
    () =>
      db.query(
        'UPDATE listener_profiles SET accepts_audio = FALSE, accepts_video = FALSE WHERE user_id = $1',
        [listener.id],
      ),
    /listener_accepts_a_call_type/,
  );
});

test('discovery publishes verified and capability without leaking KYC', async () => {
  await resetDb();
  const caller = await createUser({ balance: 100 });
  await createDiscoverableListener({ name: 'Priya', audio: true, video: false });

  const result = await call('GET', '/api/listeners', { token: signToken(caller) });
  const listener = result.body.listeners[0];

  assert.equal(listener.verified, true);
  assert.equal(listener.acceptsAudio, true);
  assert.equal(listener.acceptsVideo, false);
  // KYC internals must never reach a caller.
  assert.equal(listener.kycStatus, undefined);
  assert.equal(listener.kyc_status, undefined);
});

test('pagination still works alongside search', async () => {
  await resetDb();
  const caller = await createUser({ balance: 100 });
  for (let i = 0; i < 3; i += 1) {
    await createDiscoverableListener({ name: `Tester ${i}` });
  }

  const token = signToken(caller);
  const first = await call('GET', '/api/listeners?q=Tester&limit=2&offset=0', { token });
  assert.equal(first.body.listeners.length, 2);
  assert.equal(first.body.nextOffset, 2);

  const second = await call('GET', '/api/listeners?q=Tester&limit=2&offset=2', { token });
  assert.equal(second.body.listeners.length, 1);
  assert.equal(second.body.nextOffset, null);
});

test('an over-long search term is rejected rather than run', async () => {
  await resetDb();
  const caller = await createUser({ balance: 100 });
  const result = await call('GET', `/api/listeners?q=${'x'.repeat(100)}`, {
    token: signToken(caller),
  });
  assert.equal(result.status, 400);
});
