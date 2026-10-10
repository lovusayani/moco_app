'use strict';

/**
 * Error monitoring: what an error-level log line or a failed job sends to
 * Sentry, and — more importantly — what it never sends. The SDK is a stub;
 * nothing leaves the machine.
 */

require('./guard');

const test = require('node:test');
const assert = require('node:assert/strict');
const monitoring = require('../src/utils/monitoring');
const logger = require('../src/utils/logger');
const handlers = require('../src/jobs/handlers');
const redisConfig = require('../src/config/redis');
const db = require('../src/config/db');

function stubSdk() {
  const events = [];
  let tags = {};
  const scope = { setTag: (k, v) => { tags[k] = v; } };
  return {
    events,
    withScope(fn) {
      tags = {};
      fn(scope);
    },
    captureException(err) {
      events.push({ kind: 'exception', message: err.message, tags: { ...tags } });
    },
    captureMessage(message, level) {
      events.push({ kind: 'message', message, level, tags: { ...tags } });
    },
    flush: async () => true,
  };
}

// Reporting rides on error-level log lines, which the suite's LOG_LEVEL may
// silence; production logs at info.
const savedLevel = logger.level;
test.before(() => {
  logger.level = 'error';
});

test.after(async () => {
  logger.level = savedLevel;
  monitoring.setSdkForTests(null);
  await db.close();
  await redisConfig.close();
});

test('an error-level log line is reported with allow-listed context only', () => {
  const sdk = stubSdk();
  monitoring.setSdkForTests(sdk);

  logger.error(
    {
      err: new Error('connect ETIMEDOUT'),
      path: '/api/auth/otp/send',
      method: 'POST',
      userId: 7,
      token: 'eyJhbGciOi.secret.jwt',
      otp: '123456',
      code: 'E_TIMEOUT',
      email: 'someone@example.com',
      phone: '+919876543210',
      identifier: 'someone@example.com',
      body: { code: '123456' },
      raw: '{"agoraToken":"abc"}',
    },
    'redis error',
  );

  assert.equal(sdk.events.length, 1);
  const [event] = sdk.events;
  assert.equal(event.kind, 'exception');
  assert.equal(event.message, 'connect ETIMEDOUT');
  assert.equal(event.tags.path, '/api/auth/otp/send');
  assert.equal(event.tags.userId, '7');
  const serialized = JSON.stringify(event);
  for (const secret of ['eyJhbGciOi', '123456', 'someone@example.com', '+919876543210', 'agoraToken']) {
    assert.equal(serialized.includes(secret), false, `${secret} must not be reported`);
  }
});

test('warnings and info lines are not reported', () => {
  const sdk = stubSdk();
  monitoring.setSdkForTests(sdk);
  logger.warn({ err: new Error('minor') }, 'presence refresh failed');
  logger.info('otp sent');
  assert.equal(sdk.events.length, 0);
});

test('a burst of the same error is reported once', () => {
  const sdk = stubSdk();
  monitoring.setSdkForTests(sdk);
  for (let i = 0; i < 50; i++) logger.error({ err: new Error('connect ECONNREFUSED') }, 'redis error (burst)');
  assert.equal(sdk.events.length, 1);
});

test('a message-only error line becomes a message event', () => {
  const sdk = stubSdk();
  monitoring.setSdkForTests(sdk);
  logger.error('EMAIL_PROVIDER=log refused in production; no code was sent');
  assert.equal(sdk.events.length, 1);
  assert.equal(sdk.events[0].kind, 'message');
});

test('a failing queue job is reported with its topic and still fails', async () => {
  const sdk = stubSdk();
  monitoring.setSdkForTests(sdk);
  await assert.rejects(handlers.handle('moco-notification', { userId: 'not-a-number' }));
  assert.equal(sdk.events.length >= 1, true);
  assert.equal(sdk.events.at(-1).tags.topic, 'moco-notification');
});

test('request data is stripped from events', () => {
  const event = monitoring.scrubEvent({
    request: { url: 'https://api.lovcamx.online/api/x?token=abc', method: 'POST', data: '{"code":"123456"}', headers: { authorization: 'Bearer x' }, cookies: 'a=b' },
    user: { ip_address: '1.2.3.4' },
  });
  assert.deepEqual(event.request, { method: 'POST', url: 'https://api.lovcamx.online/api/x' });
  assert.equal(event.user, undefined);
});

test('without a DSN, monitoring is off and logging works normally', () => {
  monitoring.setSdkForTests(null);
  assert.equal(monitoring.isEnabled(), false);
  logger.error({ err: new Error('still logged') }, 'no monitoring');
});

test('the admin monitoring test sends one event, and is admin-only', async () => {
  const http = require('http');
  const { createApp } = require('../src/app');
  const { resetDb, createUser } = require('./helpers');
  const { signToken } = require('../src/middleware/auth');

  await resetDb();
  const server = http.createServer(createApp());
  await new Promise((resolve) => server.listen(0, resolve));
  const url = `http://127.0.0.1:${server.address().port}/api/admin/system/monitoring-test`;
  const post = async (token) => {
    const res = await fetch(url, { method: 'POST', headers: { Authorization: `Bearer ${token}` } });
    return { status: res.status, body: await res.json() };
  };
  const savedAdmins = process.env.ADMIN_PHONES;

  try {
    const user = await createUser();
    const admin = await createUser();
    process.env.ADMIN_PHONES = admin.phone;

    assert.equal((await post(signToken(user))).status, 403);

    monitoring.setSdkForTests(null);
    assert.equal((await post(signToken(admin))).body.error.code, 'monitoring_not_configured');

    const sdk = stubSdk();
    monitoring.setSdkForTests(sdk);
    const ok = await post(signToken(admin));
    assert.equal(ok.status, 200);
    assert.equal(sdk.events.length, 1);
    assert.equal(sdk.events[0].message, 'Moco API monitoring test event');
  } finally {
    if (savedAdmins === undefined) delete process.env.ADMIN_PHONES;
    else process.env.ADMIN_PHONES = savedAdmins;
    await new Promise((resolve) => server.close(resolve));
  }
});
