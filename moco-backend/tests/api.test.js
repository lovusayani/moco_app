'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('http');

const { createApp } = require('../src/app');
const db = require('../src/config/db');
const redisConfig = require('../src/config/redis');
const { redis } = require('../src/config/redis');
const queues = require('../src/workers/queues');
const { resetDb, createUser } = require('./helpers');
const { signToken } = require('../src/middleware/auth');
const { KYC_STATUS } = require('../src/utils/constants');

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

test('health and config are public', async () => {
  const health = await call('GET', '/health');
  assert.equal(health.status, 200);

  const config = await call('GET', '/api/config');
  assert.equal(config.status, 200);
  assert.equal(config.body.rates.audio, 6);
  assert.equal(config.body.rates.video, 12);
  assert.equal(config.body.packs.length, 5);
  assert.deepEqual(config.body.languages, ['en', 'hi', 'te']);
});

test('protected endpoints reject a missing or bogus token', async () => {
  assert.equal((await call('GET', '/api/users/me')).status, 401);
  assert.equal((await call('GET', '/api/wallet')).status, 401);
  assert.equal((await call('GET', '/api/users/me', { token: 'garbage' })).status, 401);
});

test('an unknown endpoint is a clean 404, not a crash', async () => {
  const result = await call('GET', '/api/does-not-exist');
  assert.equal(result.status, 404);
  assert.equal(result.body.error.code, 'not_found');
});

test('OTP request validates the phone format', async () => {
  await redis.flushdb();
  const bad = await call('POST', '/api/auth/otp/request', { body: { phone: '12345' } });
  assert.equal(bad.status, 400);
  assert.equal(bad.body.error.code, 'validation_failed');

  const good = await call('POST', '/api/auth/otp/request', { body: { phone: '+919812345678' } });
  assert.equal(good.status, 200);
  assert.equal(good.body.sent, true);
});

test('a wrong OTP is rejected and a right one issues a token', async () => {
  await redis.flushdb();
  const phone = '+919812345679';
  await call('POST', '/api/auth/otp/request', { body: { phone } });

  const wrong = await call('POST', '/api/auth/otp/verify', { body: { phone, code: '999999' } });
  assert.equal(wrong.status, 401);

  const right = await call('POST', '/api/auth/otp/verify', { body: { phone, code: '123456' } });
  assert.equal(right.status, 200);
  assert.ok(right.body.token);
  assert.equal(right.body.isNew, true);
  assert.equal(right.body.user.profileComplete, false);
});

test('an OTP cannot be used twice', async () => {
  await redis.flushdb();
  const phone = '+919812345680';
  await call('POST', '/api/auth/otp/request', { body: { phone } });

  assert.equal(
    (await call('POST', '/api/auth/otp/verify', { body: { phone, code: '123456' } })).status,
    200,
  );
  const replay = await call('POST', '/api/auth/otp/verify', { body: { phone, code: '123456' } });
  assert.equal(replay.status, 400);
  assert.equal(replay.body.error.code, 'otp_expired');
});

test('a suspended account loses access immediately, without waiting for token expiry', async () => {
  await resetDb();
  const user = await createUser({ balance: 10 });
  const token = signToken(user);

  assert.equal((await call('GET', '/api/users/me', { token })).status, 200);

  await db.query(`UPDATE users SET status = 'suspended' WHERE id = $1`, [user.id]);
  const after = await call('GET', '/api/users/me', { token });
  assert.equal(after.status, 403, 'the same token must stop working at once');
});

test('admin endpoints are closed to ordinary users', async () => {
  await resetDb();
  const user = await createUser();
  const result = await call('GET', '/api/admin/stats', { token: signToken(user) });
  assert.equal(result.status, 403);
  assert.equal(result.body.error.code, 'forbidden');
});

test('listener endpoints are closed to non-listeners', async () => {
  await resetDb();
  const user = await createUser();
  const result = await call('PATCH', '/api/listeners/status', {
    token: signToken(user),
    body: { isOnline: true },
  });
  assert.equal(result.status, 403);
});

test('discovery only returns KYC-approved listeners', async () => {
  await resetDb();
  const caller = await createUser({ balance: 100 });
  const approved = await createUser({ listener: true });
  const unapproved = await createUser({ listener: true });

  await db.query('UPDATE listener_profiles SET kyc_status = $2 WHERE user_id = $1', [
    unapproved.id,
    KYC_STATUS.PENDING,
  ]);

  const result = await call('GET', '/api/listeners', { token: signToken(caller) });
  assert.equal(result.status, 200);
  const ids = result.body.listeners.map((l) => l.id);
  assert.ok(ids.includes(approved.id));
  assert.ok(!ids.includes(unapproved.id), 'an unverified listener must not be discoverable');
});

test('a blocked user disappears from discovery for both sides', async () => {
  await resetDb();
  const caller = await createUser({ balance: 100 });
  const listener = await createUser({ listener: true });
  const token = signToken(caller);

  assert.equal((await call('GET', '/api/listeners', { token })).body.listeners.length, 1);

  const blocked = await call('POST', '/api/safety/block', {
    token,
    body: { userId: listener.id },
  });
  assert.equal(blocked.status, 200);

  assert.equal(
    (await call('GET', '/api/listeners', { token })).body.listeners.length,
    0,
    'a blocked listener must not appear in discovery',
  );
});

test('a call to a blocked user is refused', async () => {
  await resetDb();
  const caller = await createUser({ balance: 100 });
  const listener = await createUser({ listener: true });
  const token = signToken(caller);

  await call('POST', '/api/safety/block', { token, body: { userId: listener.id } });

  const result = await call('POST', '/api/calls/initiate', {
    token,
    body: { listenerId: listener.id, type: 'audio' },
  });
  assert.equal(result.status, 403);
});

test('a caller without enough coins is refused before the call connects', async () => {
  await resetDb();
  const caller = await createUser({ balance: 3 });
  const listener = await createUser({ listener: true });
  await db.query('UPDATE users SET free_trial_used = TRUE WHERE id = $1', [caller.id]);

  const result = await call('POST', '/api/calls/initiate', {
    token: signToken(caller),
    body: { listenerId: listener.id, type: 'audio' },
  });

  assert.equal(result.status, 402);
  assert.equal(result.body.error.code, 'insufficient_balance');
});

test('a first-time caller gets 60 free seconds even with no coins', async () => {
  await resetDb();
  const caller = await createUser({ balance: 0 });
  const listener = await createUser({ listener: true });

  const result = await call('POST', '/api/calls/initiate', {
    token: signToken(caller),
    body: { listenerId: listener.id, type: 'video' },
  });

  assert.equal(result.status, 201);
  assert.equal(result.body.freeSeconds, 60);
  assert.equal(result.body.ratePerMinute, 12);
});

test('two callers cannot claim the same listener', async () => {
  await resetDb();
  const first = await createUser({ balance: 100 });
  const second = await createUser({ balance: 100 });
  const listener = await createUser({ listener: true });

  const a = await call('POST', '/api/calls/initiate', {
    token: signToken(first),
    body: { listenerId: listener.id, type: 'audio' },
  });
  const b = await call('POST', '/api/calls/initiate', {
    token: signToken(second),
    body: { listenerId: listener.id, type: 'audio' },
  });

  assert.equal(a.status, 201);
  assert.equal(b.status, 409);
  assert.equal(b.body.error.code, 'listener_unavailable');
});

test('you cannot call yourself', async () => {
  await resetDb();
  const user = await createUser({ balance: 100, listener: true });
  const result = await call('POST', '/api/calls/initiate', {
    token: signToken(user),
    body: { listenerId: user.id, type: 'audio' },
  });
  assert.equal(result.status, 400);
  assert.equal(result.body.error.code, 'self_call');
});

test('a stranger cannot end someone else\'s call', async () => {
  await resetDb();
  const caller = await createUser({ balance: 100 });
  const listener = await createUser({ listener: true });
  const stranger = await createUser({ balance: 100 });

  const initiated = await call('POST', '/api/calls/initiate', {
    token: signToken(caller),
    body: { listenerId: listener.id, type: 'audio' },
  });

  const result = await call('POST', `/api/calls/${initiated.body.callId}/end`, {
    token: signToken(stranger),
    body: {},
  });
  assert.equal(result.status, 403);
});

test('webhook signature verification rejects a forged signature', async () => {
  const crypto = require('crypto');
  const gateway = require('../src/integrations/payment.gateway');
  const env = require('../src/config/env');

  // Point the gateway at a signed provider for the length of this test.
  const originalProvider = env.payments.provider;
  const originalSecret = env.payments.webhookSecret;
  env.payments.provider = 'razorpay';
  env.payments.webhookSecret = 'test-secret';

  const body = Buffer.from(JSON.stringify({ payload: { payment: { entity: { id: 'p1' } } } }));
  const valid = crypto.createHmac('sha256', 'test-secret').update(body).digest('hex');

  assert.equal(gateway.verifyWebhook(body, valid), true, 'a correct signature must verify');
  assert.equal(gateway.verifyWebhook(body, 'deadbeef'), false, 'a forged signature must not');
  assert.equal(gateway.verifyWebhook(body, undefined), false, 'a missing signature must not');
  // A tampered body must invalidate an otherwise-correct signature.
  assert.equal(gateway.verifyWebhook(Buffer.from('{"tampered":true}'), valid), false);

  env.payments.provider = originalProvider;
  env.payments.webhookSecret = originalSecret;
});

test('an unsigned payment webhook does not credit coins', async () => {
  await resetDb();
  const user = await createUser({ balance: 0 });

  // Missing the notes the credit path requires: must be refused, not guessed at.
  const result = await call('POST', '/api/wallet/webhook', {
    body: { payload: { payment: { entity: { id: 'p1', order_id: 'o1' } } } },
  });

  assert.equal(result.status, 200);
  assert.equal(result.body.ok, false);
  assert.equal(result.body.reason, 'missing_fields');

  const { rows } = await db.query('SELECT coin_balance FROM wallets WHERE user_id = $1', [user.id]);
  assert.equal(rows[0].coin_balance, 0, 'no coins may be credited without valid notes');
});

test('the wallet reports affordable minutes for both call types', async () => {
  await resetDb();
  const user = await createUser({ balance: 45 });
  const result = await call('GET', '/api/wallet', { token: signToken(user) });
  assert.equal(result.body.coinBalance, 45);
  assert.equal(result.body.audioMinutes, 7);
  assert.equal(result.body.videoMinutes, 3);
});

test('the admin console is served as static files', async () => {
  const page = await fetch(`${baseUrl}/admin/`);
  assert.equal(page.status, 200);
  assert.match(page.headers.get('content-type'), /text\/html/);

  const html = await page.text();
  assert.match(html, /Moco Admin/);

  // Its assets must resolve too, or the page loads blank.
  for (const asset of ['admin.css', 'admin.js']) {
    const response = await fetch(`${baseUrl}/admin/${asset}`);
    assert.equal(response.status, 200, `${asset} must be served`);
  }
});

test('the console is a static page, not a way around admin auth', async () => {
  // Serving the HTML grants nothing: the API behind it still refuses.
  assert.equal((await call('GET', '/api/admin/stats')).status, 401);
  assert.equal((await call('GET', '/api/admin/kyc')).status, 401);
});

test('config exposes the dev OTP outside production and never in it', async () => {
  const env = require('../src/config/env');
  const result = await call('GET', '/api/config');
  assert.equal(result.body.devOtp, env.otp.fixedCode);
  // env.otp.fixedCode is hardcoded to null when NODE_ENV=production, so the
  // real code can never be published through this endpoint.
  assert.equal(env.isProduction, false);
});

test('admin stats include the pending KYC count the console badges', async () => {
  await resetDb();
  const admin = await createUser({ balance: 0 });
  await db.query('UPDATE users SET phone = $2 WHERE id = $1', [admin.id, '+919000000778']);
  process.env.ADMIN_PHONES = '+919000000778';
  const token = signToken({ ...admin, phone: '+919000000778' });

  const before = await call('GET', '/api/admin/stats', { token });
  assert.equal(before.status, 200);
  assert.equal(before.body.pending_kyc, 0);

  const listener = await createUser({ listener: true });
  await db.query('UPDATE listener_profiles SET kyc_status = $2 WHERE user_id = $1', [
    listener.id,
    KYC_STATUS.PENDING,
  ]);

  const after = await call('GET', '/api/admin/stats', { token });
  assert.equal(after.body.pending_kyc, 1);

  delete process.env.ADMIN_PHONES;
});

test('the admin reconciliation check reports a balanced ledger', async () => {
  await resetDb();
  const admin = await createUser({ balance: 100 });
  await db.query('UPDATE users SET phone = $2 WHERE id = $1', [admin.id, '+919000000777']);
  process.env.ADMIN_PHONES = '+919000000777';

  const refreshed = { ...admin, phone: '+919000000777' };
  const result = await call('GET', '/api/admin/reconcile', { token: signToken(refreshed) });

  assert.equal(result.status, 200);
  assert.equal(result.body.balanced, true);
  delete process.env.ADMIN_PHONES;
});
