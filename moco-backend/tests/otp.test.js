'use strict';

/**
 * Multi-channel sign-in codes: POST /api/auth/otp/send and /otp/verify.
 *
 * Email is the default channel. Delivery providers are stubbed per test where
 * the code itself must be captured; everything else (Redis state, limits,
 * user lookup/creation, JWT) runs for real against the local test database.
 */

process.env.ADMIN_EMAILS = 'boss@moco.test';

const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('http');
const { createApp } = require('../src/app');
const db = require('../src/config/db');
const redisConfig = require('../src/config/redis');
const env = require('../src/config/env');
const logger = require('../src/utils/logger');
const { CHANNELS } = require('../src/modules/auth/otp.channels');
const emailIntegration = require('../src/integrations/email');
const whatsapp = require('../src/integrations/whatsapp');
const telegram = require('../src/integrations/telegram');
const { resetDb, createUser, balanceOf } = require('./helpers');
const { query } = require('../src/config/db');
const { redis } = require('../src/config/redis');

let server;
let base;

test.before(async () => {
  server = http.createServer(createApp());
  await new Promise((resolve) => server.listen(0, resolve));
  base = `http://127.0.0.1:${server.address().port}`;
});

test.after(async () => {
  await new Promise((resolve) => server.close(resolve));
  await db.close();
  await redisConfig.close();
});

async function post(path, body, headers = {}) {
  const res = await fetch(`${base}/api${path}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', ...headers },
    body: JSON.stringify(body),
  });
  return { status: res.status, body: await res.json() };
}

/** Captures the next code a channel sends (and stops it really sending). */
function captureCodes(channel) {
  const sent = [];
  const original = CHANNELS[channel].send;
  CHANNELS[channel].send = async (to, code, ttl) => {
    sent.push({ to, code, ttl });
    return { ok: true };
  };
  return { sent, restore: () => { CHANNELS[channel].send = original; } };
}

/** Random codes for this test (the suite's default is the fixed dev code). */
async function withRandomCodes(fn) {
  const fixed = env.otp.fixedCode;
  env.otp.fixedCode = null;
  try {
    return await fn();
  } finally {
    env.otp.fixedCode = fixed;
  }
}

const sendEmail = (identifier) => post('/auth/otp/send', { channel: 'email', identifier });
const verifyEmail = (identifier, code) => post('/auth/otp/verify', { channel: 'email', identifier, code });

test.beforeEach(async () => {
  await resetDb();
});

// ---------------------------------------------------------------- email

test('1. sending to a valid email returns a generic acknowledgement, never the code', async () => {
  const cap = captureCodes('email');
  try {
    const r = await withRandomCodes(() => sendEmail('asha@example.com'));
    assert.equal(r.status, 200, JSON.stringify(r.body));
    assert.deepEqual(Object.keys(r.body).sort(), ['channel', 'expiresIn', 'resendIn', 'sent']);
    assert.equal(r.body.channel, 'email');
    assert.equal(cap.sent.length, 1);
    assert.match(cap.sent[0].code, /^\d{6}$/);
    assert.ok(!JSON.stringify(r.body).includes(cap.sent[0].code));
  } finally {
    cap.restore();
  }
});

test('2. an invalid email is rejected before anything is sent', async () => {
  for (const bad of ['not-an-email', 'a@b', 'x@@y.com', '@example.com', 'a b@example.com']) {
    const r = await sendEmail(bad);
    assert.equal(r.status, 400, bad);
    assert.equal(r.body.error.code, 'invalid_email', bad);
  }
});

test('3 + 11 + 12. the right code signs in a NEW user, with a wallet and a working JWT', async () => {
  const cap = captureCodes('email');
  try {
    await withRandomCodes(() => sendEmail('new.user@example.com'));
    const r = await verifyEmail('new.user@example.com', cap.sent[0].code);
    assert.equal(r.status, 200, JSON.stringify(r.body));
    assert.equal(r.body.isNew, true);
    assert.equal(r.body.user.email, 'new.user@example.com');
    assert.equal(r.body.user.phone, null);
    assert.equal(await balanceOf(r.body.user.id), 0);

    const me = await fetch(`${base}/api/users/me`, { headers: { Authorization: `Bearer ${r.body.token}` } });
    assert.equal(me.status, 200);
    const profile = await me.json();
    assert.equal(profile.email, 'new.user@example.com');
  } finally {
    cap.restore();
  }
});

test('4. a wrong code is rejected', async () => {
  const cap = captureCodes('email');
  try {
    await withRandomCodes(() => sendEmail('asha@example.com'));
    const wrong = cap.sent[0].code === '000000' ? '111111' : '000000';
    const r = await verifyEmail('asha@example.com', wrong);
    assert.equal(r.status, 401);
    assert.equal(r.body.error.message, 'Incorrect code');
  } finally {
    cap.restore();
  }
});

test('5. an expired code is rejected', async () => {
  const cap = captureCodes('email');
  try {
    await withRandomCodes(() => sendEmail('asha@example.com'));
    await redis.del('otp:email:asha@example.com'); // what the TTL does
    const r = await verifyEmail('asha@example.com', cap.sent[0].code);
    assert.equal(r.status, 400);
    assert.equal(r.body.error.code, 'otp_expired');
  } finally {
    cap.restore();
  }
});

test('6. a code cannot be used twice', async () => {
  const cap = captureCodes('email');
  try {
    await withRandomCodes(() => sendEmail('asha@example.com'));
    assert.equal((await verifyEmail('asha@example.com', cap.sent[0].code)).status, 200);
    const again = await verifyEmail('asha@example.com', cap.sent[0].code);
    assert.equal(again.status, 400);
    assert.equal(again.body.error.code, 'otp_expired');
  } finally {
    cap.restore();
  }
});

test('7. a resend inside the cooldown is refused with retryAfter', async () => {
  const cap = captureCodes('email');
  try {
    assert.equal((await sendEmail('asha@example.com')).status, 200);
    const r = await sendEmail('asha@example.com');
    assert.equal(r.status, 429);
    assert.equal(r.body.error.code, 'otp_cooldown');
    assert.ok(r.body.error.details.retryAfter > 0);
    assert.equal(cap.sent.length, 1);
  } finally {
    cap.restore();
  }
});

test('8. too many wrong guesses kill the code', async () => {
  const cap = captureCodes('email');
  try {
    await withRandomCodes(() => sendEmail('asha@example.com'));
    const wrong = cap.sent[0].code === '000000' ? '111111' : '000000';
    for (let i = 0; i < env.otp.maxAttempts; i++) await verifyEmail('asha@example.com', wrong);
    const locked = await verifyEmail('asha@example.com', cap.sent[0].code);
    assert.equal(locked.status, 429);
    // And the real code is gone too.
    const after = await verifyEmail('asha@example.com', cap.sent[0].code);
    assert.notEqual(after.status, 200);
  } finally {
    cap.restore();
  }
});

test('9. per-email hourly limit across sends', async () => {
  const cap = captureCodes('email');
  try {
    for (let i = 0; i < env.otp.maxSendsPerHour; i++) {
      await redis.del('otp_cooldown:email:limit@example.com');
      assert.equal((await sendEmail('limit@example.com')).status, 200, `send ${i + 1}`);
    }
    await redis.del('otp_cooldown:email:limit@example.com');
    const r = await sendEmail('limit@example.com');
    assert.equal(r.status, 429);
    assert.equal(r.body.error.code, 'rate_limited');
  } finally {
    cap.restore();
  }
});

test('10. an EXISTING email user keeps their account, balance and role', async () => {
  const existing = await createUser({ balance: 300, listener: true });
  await query('UPDATE users SET email = $2 WHERE id = $1', [existing.id, 'creator@example.com']);
  const cap = captureCodes('email');
  try {
    await withRandomCodes(() => sendEmail('Creator@Example.com'));
    const r = await verifyEmail('creator@example.com', cap.sent[0].code);
    assert.equal(r.status, 200);
    assert.equal(r.body.isNew, false);
    assert.equal(String(r.body.user.id), String(existing.id));
    assert.equal(r.body.user.role, 'listener');
    assert.equal(r.body.user.phone, existing.phone, 'the phone on the account is preserved');
    assert.equal(await balanceOf(existing.id), 300);
  } finally {
    cap.restore();
  }
});

test('emails are normalized: case and spaces map to one account', async () => {
  const cap = captureCodes('email');
  try {
    await sendEmail('  Mixed.Case@Example.COM ');
    assert.equal(cap.sent[0].to, 'mixed.case@example.com');
    const r = await verifyEmail('MIXED.case@example.com', '123456');
    assert.equal(r.status, 200);
    const again = await (async () => {
      await redis.del('otp_cooldown:email:mixed.case@example.com');
      await sendEmail('mixed.case@example.com');
      return verifyEmail('mixed.case@example.com', '123456');
    })();
    assert.equal(String(again.body.user.id), String(r.body.user.id));
    const { rows } = await query(`SELECT count(*)::int AS n FROM users WHERE email = 'mixed.case@example.com'`);
    assert.equal(rows[0].n, 1);
  } finally {
    cap.restore();
  }
});

test('an email sign-in never attaches to a phone account by guesswork', async () => {
  const phoneUser = await createUser({ balance: 50 });
  const cap = captureCodes('email');
  try {
    await sendEmail('someone@example.com');
    const r = await verifyEmail('someone@example.com', '123456');
    assert.equal(r.body.isNew, true);
    assert.notEqual(String(r.body.user.id), String(phoneUser.id));
    assert.equal(await balanceOf(phoneUser.id), 50);
  } finally {
    cap.restore();
  }
});

test('13. no account enumeration: the send response is identical for known and unknown emails', async () => {
  const known = await createUser();
  await query('UPDATE users SET email = $2 WHERE id = $1', [known.id, 'known@example.com']);
  const cap = captureCodes('email');
  try {
    const a = await sendEmail('known@example.com');
    const b = await sendEmail('unknown@example.com');
    assert.equal(a.status, b.status);
    assert.deepEqual(a.body, b.body);
  } finally {
    cap.restore();
  }
});

// ---------------------------------------------------------------- channels

test('GET /api/config: email is the default; unconfigured channels are marked unavailable', async () => {
  const res = await fetch(`${base}/api/config`);
  const { auth } = await res.json();
  assert.equal(auth.defaultChannel, 'email');
  const byId = Object.fromEntries(auth.channels.map((c) => [c.id, c]));
  assert.deepEqual(Object.keys(byId), ['email', 'sms', 'whatsapp', 'telegram']);
  assert.equal(byId.email.identity, 'email');
  assert.equal(byId.sms.identity, 'phone');
  assert.equal(byId.whatsapp.available, false);
  assert.equal(byId.telegram.available, false);
});

test('an unconfigured channel cannot be used (no silent failure)', async () => {
  for (const channel of ['whatsapp', 'telegram']) {
    const r = await post('/auth/otp/send', { channel, identifier: '+919876543210' });
    assert.equal(r.status, 400, channel);
    assert.equal(r.body.error.code, 'channel_unavailable', channel);
  }
});

test('phone channels validate the number', async () => {
  const r = await post('/auth/otp/send', { channel: 'sms', identifier: '98765' });
  assert.equal(r.status, 400);
  assert.equal(r.body.error.code, 'invalid_phone');
});

test('an unknown channel is rejected', async () => {
  const r = await post('/auth/otp/send', { channel: 'pigeon', identifier: 'a@b.com' });
  assert.equal(r.status, 400);
});

test('legacy phone endpoints still sign in an EXISTING phone user (SMS)', async () => {
  const existing = await createUser({ balance: 120 });
  assert.equal((await post('/auth/otp/request', { phone: existing.phone })).status, 200);
  const r = await post('/auth/otp/verify', { phone: existing.phone, code: '123456' });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(String(r.body.user.id), String(existing.id));
  assert.equal(await balanceOf(existing.id), 120);
});

test('one live code per identity: a WhatsApp code replaces the SMS code', async () => {
  const sms = captureCodes('sms');
  const wa = captureCodes('whatsapp');
  const waConfigured = CHANNELS.whatsapp.isConfigured;
  CHANNELS.whatsapp.isConfigured = () => true;
  try {
    await withRandomCodes(async () => {
      await post('/auth/otp/send', { channel: 'sms', identifier: '+919811112222' });
      await redis.del('otp_cooldown:phone:+919811112222');
      await post('/auth/otp/send', { channel: 'whatsapp', identifier: '+919811112222' });
    });
    if (sms.sent[0].code !== wa.sent[0].code) {
      const old = await post('/auth/otp/verify', { channel: 'sms', identifier: '+919811112222', code: sms.sent[0].code });
      assert.equal(old.status, 401, 'the superseded SMS code no longer works');
    }
    const r = await post('/auth/otp/verify', { channel: 'whatsapp', identifier: '+919811112222', code: wa.sent[0].code });
    assert.equal(r.status, 200);
  } finally {
    sms.restore();
    wa.restore();
    CHANNELS.whatsapp.isConfigured = waConfigured;
  }
});

test('24. a code sent to one identity cannot sign in another', async () => {
  const cap = captureCodes('email');
  try {
    await withRandomCodes(() => sendEmail('victim@example.com'));
    const r = await verifyEmail('attacker@example.com', cap.sent[0].code);
    assert.equal(r.status, 400);
    assert.equal(r.body.error.code, 'otp_expired');
  } finally {
    cap.restore();
  }
});

// ---------------------------------------------------------------- delivery

async function withProduction(fn) {
  const saved = { isProduction: env.isProduction, provider: env.email.provider, key: env.email.resendApiKey, from: env.email.from };
  env.isProduction = true;
  try {
    return await fn();
  } finally {
    env.isProduction = saved.isProduction;
    env.email.provider = saved.provider;
    env.email.resendApiKey = saved.key;
    env.email.from = saved.from;
  }
}

/** Intercepts global fetch for provider calls; records requests. */
function mockFetch(respond) {
  const calls = [];
  const original = global.fetch;
  global.fetch = async (url, init) => {
    if (String(url).startsWith(base)) return original(url, init);
    calls.push({ url: String(url), init, body: init?.body ? JSON.parse(init.body) : null });
    return respond(String(url));
  };
  return { calls, restore: () => { global.fetch = original; } };
}

test('Resend: the email request carries the code, the sender and a bearer key', async () => {
  await withProduction(async () => {
    env.email.provider = 'resend';
    env.email.resendApiKey = 're_test_key';
    env.email.from = 'Moco <no-reply@lovcamx.online>';
    const f = mockFetch(() => new Response('{"id":"x"}', { status: 200 }));
    try {
      const result = await emailIntegration.sendOtp('asha@example.com', '482913', 300);
      assert.equal(result.ok, true);
      const [call] = f.calls;
      assert.equal(call.url, 'https://api.resend.com/emails');
      assert.equal(call.init.headers.Authorization, 'Bearer re_test_key');
      assert.equal(call.body.from, 'Moco <no-reply@lovcamx.online>');
      assert.deepEqual(call.body.to, ['asha@example.com']);
      assert.match(call.body.subject, /482913/);
      assert.match(call.body.html, /482913/);
      assert.match(call.body.text, /expires in 5 minutes/);
    } finally {
      f.restore();
    }
  });
});

test('Resend failure: generic 502, code discarded, cooldown lifted', async () => {
  await withProduction(async () => {
    env.email.provider = 'resend';
    env.email.resendApiKey = 're_test_key';
    env.email.from = 'no-reply@lovcamx.online';
    const f = mockFetch(() => new Response('{"message":"domain not verified"}', { status: 403 }));
    try {
      const r = await sendEmail('asha@example.com');
      assert.equal(r.status, 502);
      assert.equal(r.body.error.code, 'otp_delivery_failed');
      assert.equal(r.body.error.message, 'Unable to send email. Please try again later.');
      assert.equal(await redis.exists('otp:email:asha@example.com'), 0);
      assert.equal(await redis.exists('otp_cooldown:email:asha@example.com'), 0);
    } finally {
      f.restore();
    }
  });
});

test('22. no code ever reaches the logs in production (email and SMS log providers refuse)', async () => {
  const seen = [];
  const methods = ['info', 'warn', 'error', 'debug'];
  const originals = Object.fromEntries(methods.map((m) => [m, logger[m]]));
  for (const m of methods) logger[m] = (...args) => { seen.push(JSON.stringify(args)); };
  try {
    await withProduction(async () => {
      env.email.provider = 'log';
      const e = await emailIntegration.sendOtp('asha@example.com', '735102', 300);
      assert.equal(e.ok, false);
      const s = await require('../src/integrations/sms').sendOtp('+919800000000', '735102');
      assert.equal(s.ok, false);
    });
  } finally {
    for (const m of methods) logger[m] = originals[m];
  }
  assert.ok(seen.length > 0);
  assert.ok(seen.every((line) => !line.includes('735102')), 'a code appeared in a log line');
});

test('WhatsApp: Authentication template with the code in body and copy button', () => {
  const saved = { ...env.whatsapp };
  Object.assign(env.whatsapp, { templateName: 'moco_login', templateLanguage: 'en' });
  try {
    const p = whatsapp.templatePayload('+919876543210', '246810');
    assert.equal(p.to, '919876543210');
    assert.equal(p.template.name, 'moco_login');
    assert.equal(p.template.components[0].parameters[0].text, '246810');
    assert.equal(p.template.components[1].sub_type, 'url');
  } finally {
    Object.assign(env.whatsapp, saved);
  }
});

test('Telegram Gateway: our code, E.164 number and TTL; Gateway errors are a failure', async () => {
  const saved = env.telegram.gatewayToken;
  env.telegram.gatewayToken = 'tg_test_token';
  const f = mockFetch(() => new Response('{"ok":false,"error":"PHONE_NUMBER_NOT_FOUND"}', { status: 400 }));
  try {
    const result = await telegram.sendOtp('+919876543210', '135790', 300);
    assert.equal(result.ok, false);
    const [call] = f.calls;
    assert.equal(call.url, 'https://gatewayapi.telegram.org/sendVerificationMessage');
    assert.equal(call.init.headers.Authorization, 'Bearer tg_test_token');
    assert.deepEqual(call.body, { phone_number: '+919876543210', code: '135790', ttl: 300 });
  } finally {
    f.restore();
    env.telegram.gatewayToken = saved;
  }
});

// ---------------------------------------------------------------- admin

test('an email listed in ADMIN_EMAILS signs in to the admin API; others do not', async () => {
  const cap = captureCodes('email');
  try {
    await sendEmail('boss@moco.test');
    const admin = await verifyEmail('boss@moco.test', '123456');
    const me = await fetch(`${base}/api/admin/me`, { headers: { Authorization: `Bearer ${admin.body.token}` } });
    assert.equal(me.status, 200);
    assert.equal((await me.json()).email, 'boss@moco.test');

    await sendEmail('nobody@moco.test');
    const user = await verifyEmail('nobody@moco.test', '123456');
    const denied = await fetch(`${base}/api/admin/me`, { headers: { Authorization: `Bearer ${user.body.token}` } });
    assert.equal(denied.status, 403);
  } finally {
    cap.restore();
  }
});
