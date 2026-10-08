'use strict';

/**
 * Push notifications: device-token lifecycle (register, rotate, hand over to
 * another account, unregister on sign-out), the FCM HTTP v1 request, stale
 * token cleanup in the notification worker, and the admin test push.
 *
 * FCM itself is never contacted: requests to Google are answered by a stub,
 * everything else (routes, database, queue handler) runs for real against the
 * local test database.
 */

process.env.ADMIN_EMAILS = 'pushadmin@moco.test';

const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('http');
const crypto = require('crypto');

const { createApp } = require('../src/app');
const db = require('../src/config/db');
const redisConfig = require('../src/config/redis');
const env = require('../src/config/env');
const jobs = require('../src/jobs');
const fcm = require('../src/integrations/fcm');
const { handleNotification } = require('../src/workers/notification.worker');
const { resetDb, createUser } = require('./helpers');
const { query } = require('../src/config/db');
const { signToken } = require('../src/middleware/auth');

const TOKEN_A = 'device-token-aaaaaaaaaaaaaaaaaaaa';
const TOKEN_B = 'device-token-bbbbbbbbbbbbbbbbbbbb';

let server;
let baseUrl;
const realFetch = global.fetch;
const fcmRequests = [];
let fcmReply = () => ({ status: 200, body: { name: 'projects/moco-test/messages/1' } });

test.before(async () => {
  const { privateKey } = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 });
  env.fcm.serviceAccountJson = JSON.stringify({
    project_id: 'moco-test',
    client_email: 'push@moco-test.iam.gserviceaccount.com',
    private_key: privateKey.export({ type: 'pkcs8', format: 'pem' }),
  });
  fcm.resetForTests();

  global.fetch = async (url, init) => {
    const href = String(url);
    if (href.startsWith('https://oauth2.googleapis.com/')) {
      return new Response(JSON.stringify({ access_token: 'stub-access-token', expires_in: 3600 }), { status: 200 });
    }
    if (href.startsWith('https://fcm.googleapis.com/')) {
      fcmRequests.push({ url: href, headers: init.headers, body: JSON.parse(init.body) });
      const { status, body } = await fcmReply();
      return new Response(JSON.stringify(body), { status });
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
  env.fcm.serviceAccountJson = '';
  fcm.resetForTests();
  await new Promise((resolve) => server.close(resolve));
  await db.close();
  await redisConfig.close();
});

test.beforeEach(() => {
  fcmRequests.length = 0;
  fcmReply = () => ({ status: 200, body: { name: 'projects/moco-test/messages/1' } });
  jobs.clearRecordedJobs();
});

async function call(method, path, { token, body } = {}) {
  const response = await realFetch(`${baseUrl}${path}`, {
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

const tokenOf = async (userId) =>
  (await query('SELECT fcm_token FROM users WHERE id = $1', [userId])).rows[0].fcm_token;

test('registering a token stores it, and a rotated token replaces it', async () => {
  const user = await createUser();
  const auth = signToken(user);

  assert.equal((await call('POST', '/api/users/me/fcm-token', { token: auth, body: { token: TOKEN_A } })).status, 200);
  assert.equal(await tokenOf(user.id), TOKEN_A);

  assert.equal((await call('POST', '/api/users/me/fcm-token', { token: auth, body: { token: TOKEN_B } })).status, 200);
  assert.equal(await tokenOf(user.id), TOKEN_B);
});

test('a device token moves to the account that signed in on it last', async () => {
  const first = await createUser();
  const second = await createUser();

  await call('POST', '/api/users/me/fcm-token', { token: signToken(first), body: { token: TOKEN_A } });
  await call('POST', '/api/users/me/fcm-token', { token: signToken(second), body: { token: TOKEN_A } });

  assert.equal(await tokenOf(first.id), null, 'the earlier account no longer receives this device’s pushes');
  assert.equal(await tokenOf(second.id), TOKEN_A);
});

test('sign-out unregisters only the token it names', async () => {
  const user = await createUser();
  const auth = signToken(user);
  await call('POST', '/api/users/me/fcm-token', { token: auth, body: { token: TOKEN_A } });

  // A stale sign-out from an old install must not clear the current token.
  await call('DELETE', '/api/users/me/fcm-token', { token: auth, body: { token: TOKEN_B } });
  assert.equal(await tokenOf(user.id), TOKEN_A);

  await call('DELETE', '/api/users/me/fcm-token', { token: auth, body: { token: TOKEN_A } });
  assert.equal(await tokenOf(user.id), null);
});

test('token routes require a session and a plausible token', async () => {
  assert.equal((await call('POST', '/api/users/me/fcm-token', { body: { token: TOKEN_A } })).status, 401);
  const user = await createUser();
  const res = await call('POST', '/api/users/me/fcm-token', { token: signToken(user), body: { token: 'short' } });
  assert.equal(res.status, 400);
});

test('the worker sends an FCM v1 message with a tray notification and string data', async () => {
  const user = await createUser();
  await query('UPDATE users SET fcm_token = $2 WHERE id = $1', [user.id, TOKEN_A]);

  const result = await handleNotification({
    data: {
      userId: user.id,
      title: 'Incoming call',
      body: 'Asha is calling you',
      data: { type: 'incoming_call', callId: 42, callType: 'audio' },
      highPriority: true,
    },
  });

  assert.equal(result.status, 'sent');
  assert.equal(fcmRequests.length, 1);
  const { url, headers, body } = fcmRequests[0];
  assert.equal(url, 'https://fcm.googleapis.com/v1/projects/moco-test/messages:send');
  assert.equal(headers.Authorization, 'Bearer stub-access-token');
  assert.equal(body.message.token, TOKEN_A);
  assert.deepEqual(body.message.notification, { title: 'Incoming call', body: 'Asha is calling you' });
  assert.equal(body.message.data.type, 'incoming_call');
  assert.equal(body.message.data.callId, '42', 'FCM data values must be strings');
  assert.equal(body.message.android.priority, 'HIGH');
  assert.equal(body.message.android.notification.channel_id, fcm.CHANNELS.calls);
});

test('an unregistered token is cleared so it is not tried again', async () => {
  const user = await createUser();
  await query('UPDATE users SET fcm_token = $2 WHERE id = $1', [user.id, TOKEN_A]);
  fcmReply = () => ({
    status: 404,
    body: { error: { status: 'NOT_FOUND', details: [{ errorCode: 'UNREGISTERED' }] } },
  });

  const result = await handleNotification({ data: { userId: user.id, title: 'Hi', body: 'There' } });
  assert.equal(result.status, 'stale_token_cleared');
  assert.equal(await tokenOf(user.id), null);
});

test('a stale-token answer never clears a newer token registered meanwhile', async () => {
  const user = await createUser();
  await query('UPDATE users SET fcm_token = $2 WHERE id = $1', [user.id, TOKEN_A]);
  fcmReply = async () => {
    // The device re-registers while the send is in flight.
    await query('UPDATE users SET fcm_token = $2 WHERE id = $1', [user.id, TOKEN_B]);
    return { status: 404, body: { error: { details: [{ errorCode: 'UNREGISTERED' }] } } };
  };
  await handleNotification({ data: { userId: user.id, title: 'Hi', body: 'There' } });
  // Let the concurrent update land, then check the newer token survived.
  await new Promise((r) => setTimeout(r, 50));
  assert.equal(await tokenOf(user.id), TOKEN_B);
});

test('a transient FCM failure throws so the queue redelivers', async () => {
  const user = await createUser();
  await query('UPDATE users SET fcm_token = $2 WHERE id = $1', [user.id, TOKEN_A]);
  fcmReply = () => ({ status: 503, body: { error: { status: 'UNAVAILABLE' } } });

  await assert.rejects(handleNotification({ data: { userId: user.id, title: 'Hi', body: 'There' } }));
  assert.equal(await tokenOf(user.id), TOKEN_A, 'a transient failure keeps the token');
});

test('no token means no FCM call', async () => {
  const user = await createUser();
  const result = await handleNotification({ data: { userId: user.id, title: 'Hi', body: 'There' } });
  assert.equal(result.status, 'no_token');
  assert.equal(fcmRequests.length, 0);
});

test('admin test push goes through the notification queue', async () => {
  const admin = await createUser();
  await query('UPDATE users SET email = $2 WHERE id = $1', [admin.id, 'pushadmin@moco.test']);
  const adminToken = signToken({ ...admin, email: 'pushadmin@moco.test' });
  const target = await createUser();

  const none = await call('POST', `/api/admin/users/${target.id}/test-push`, { token: adminToken });
  assert.equal(none.status, 400);
  assert.equal(none.body.error.code, 'no_push_token');

  await query('UPDATE users SET fcm_token = $2 WHERE id = $1', [target.id, TOKEN_A]);
  const detail = await call('GET', `/api/admin/users/${target.id}`, { token: adminToken });
  assert.equal(detail.body.pushRegistered, true);
  assert.equal(JSON.stringify(detail.body).includes(TOKEN_A), false, 'the token itself is never shown');

  const res = await call('POST', `/api/admin/users/${target.id}/test-push`, { token: adminToken });
  assert.equal(res.status, 200);
  const queued = jobs.recordedJobs().filter((j) => j.topic === jobs.TOPICS.NOTIFICATION);
  assert.equal(queued.length, 1);
  assert.equal(queued[0].payload.userId, target.id);
  assert.equal(queued[0].payload.data.type, 'test');

  // Non-admins cannot trigger it.
  const forbidden = await call('POST', `/api/admin/users/${target.id}/test-push`, { token: signToken(target) });
  assert.equal(forbidden.status, 403);
});

test('without a service account, production refuses to pretend a push was sent', async () => {
  const saved = env.fcm.serviceAccountJson;
  const savedProd = env.isProduction;
  env.fcm.serviceAccountJson = '';
  env.isProduction = true;
  fcm.resetForTests();
  try {
    const result = await fcm.send({ token: TOKEN_A, title: 'x', body: 'y' });
    assert.deepEqual(result, { ok: false, reason: 'not_configured' });
  } finally {
    env.fcm.serviceAccountJson = saved;
    env.isProduction = savedProd;
    fcm.resetForTests();
  }
});
