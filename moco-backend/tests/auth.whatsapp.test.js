'use strict';

// WhatsApp configuration must be in place before the app (and env) loads.
// These are test placeholders, not real credentials.
process.env.WHATSAPP_ACCESS_TOKEN = 'test-access-token';
process.env.WHATSAPP_PHONE_NUMBER_ID = '100000000000001';
process.env.WHATSAPP_OTP_TEMPLATE_NAME = 'moco_login_code';
process.env.WHATSAPP_OTP_TEMPLATE_LANGUAGE = 'en';
process.env.WHATSAPP_WEBHOOK_VERIFY_TOKEN = 'test-verify-token';
process.env.WHATSAPP_APP_SECRET = 'test-app-secret';

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('crypto');
const http = require('http');

const { resetDb } = require('./helpers');
const { createApp } = require('../src/app');
const db = require('../src/config/db');
const redisConfig = require('../src/config/redis');
const { redis } = require('../src/config/redis');
const env = require('../src/config/env');
const sms = require('../src/integrations/sms');
const logger = require('../src/utils/logger');

let server;
let baseUrl;

// --- Delivery doubles -------------------------------------------------------
// Real random codes (not the fixed dev code), so a test can tell an SMS code
// from a WhatsApp code and prove the second replaced the first.
const delivered = { sms: [], whatsapp: [] };
let smsFails = false;
let whatsappResponse = null; // null = success; else { status, body }
const graphCalls = [];

const realFetch = global.fetch;
global.fetch = async (url, init = {}) => {
  if (String(url).startsWith('https://graph.facebook.com/')) {
    const body = JSON.parse(init.body);
    graphCalls.push({ url: String(url), headers: init.headers, body });
    if (whatsappResponse) {
      return new Response(JSON.stringify(whatsappResponse.body), { status: whatsappResponse.status });
    }
    delivered.whatsapp.push({ to: body.to, code: body.template.components[0].parameters[0].text });
    return new Response(JSON.stringify({ messages: [{ id: `wamid.test${graphCalls.length}` }] }), { status: 200 });
  }
  return realFetch(url, init);
};
sms.sendOtp = async (phone, code) => {
  if (smsFails) return { ok: false };
  delivered.sms.push({ phone, code });
  return { ok: true, provider: 'test' };
};

// Every log line, to prove no code is ever logged.
const logged = [];
for (const level of ['trace', 'debug', 'info', 'warn', 'error', 'fatal']) {
  const original = logger[level].bind(logger);
  logger[level] = (...args) => {
    logged.push(JSON.stringify(args));
    return original(...args);
  };
}

test.before(async () => {
  env.otp.fixedCode = null;
  await resetDb();
  server = http.createServer(createApp());
  await new Promise((resolve) => server.listen(0, resolve));
  baseUrl = `http://127.0.0.1:${server.address().port}`;
});

test.after(async () => {
  global.fetch = realFetch;
  await new Promise((resolve) => server.close(resolve));
  await db.close();
  await redisConfig.close();
});

test.beforeEach(async () => {
  await redis.flushdb();
  delivered.sms.length = 0;
  delivered.whatsapp.length = 0;
  graphCalls.length = 0;
  smsFails = false;
  whatsappResponse = null;
});

async function call(method, path, { body, headers, raw } = {}) {
  const response = await realFetch(`${baseUrl}${path}`, {
    method,
    headers: { 'Content-Type': 'application/json', ...headers },
    body: raw ?? (body ? JSON.stringify(body) : undefined),
  });
  const text = await response.text();
  let json;
  try { json = JSON.parse(text); } catch { json = text; }
  return { status: response.status, body: json };
}

const clearCooldown = (phone) => redis.del(`otp_cooldown:${phone}`);
const lastWhatsappCode = () => delivered.whatsapp.at(-1).code;
const lastSmsCode = () => delivered.sms.at(-1).code;

test('channels report WhatsApp as an available fallback when configured', async () => {
  const res = await call('GET', '/api/auth/otp/channels');
  assert.equal(res.status, 200);
  assert.deepEqual(res.body, { sms: true, whatsapp: true });
});

test('an SMS request defaults to SMS and offers WhatsApp as the fallback', async () => {
  const res = await call('POST', '/api/auth/otp/request', { body: { phone: '+919811100001' } });
  assert.equal(res.status, 200);
  assert.equal(res.body.channel, 'sms');
  assert.deepEqual(res.body.fallbackChannels, ['whatsapp']);
  assert.equal(res.body.resendIn, env.otp.resendCooldownSeconds);
  assert.equal(delivered.sms.length, 1);
  assert.equal(graphCalls.length, 0, 'SMS and WhatsApp are never both sent');
});

test('the resend cooldown applies across channels', async () => {
  const phone = '+919811100002';
  await call('POST', '/api/auth/otp/request', { body: { phone } });
  const again = await call('POST', '/api/auth/otp/request', { body: { phone, channel: 'whatsapp' } });
  assert.equal(again.status, 429);
  assert.equal(again.body.error.code, 'otp_cooldown');
  assert.ok(again.body.error.details.retryAfter > 0);
  assert.equal(graphCalls.length, 0);
});

test('the WhatsApp fallback sends the approved authentication template', async () => {
  const phone = '+919811100003';
  await call('POST', '/api/auth/otp/request', { body: { phone } });
  await clearCooldown(phone);
  const res = await call('POST', '/api/auth/otp/request', { body: { phone, channel: 'whatsapp' } });
  assert.equal(res.status, 200);
  assert.equal(res.body.channel, 'whatsapp');
  assert.deepEqual(res.body.fallbackChannels, []);

  assert.equal(graphCalls.length, 1);
  const { url, headers, body } = graphCalls[0];
  assert.equal(url, `https://graph.facebook.com/${env.whatsapp.graphVersion}/100000000000001/messages`);
  assert.equal(headers.Authorization, 'Bearer test-access-token');
  assert.equal(body.messaging_product, 'whatsapp');
  assert.equal(body.to, '919811100003', 'E.164 without the plus sign');
  assert.equal(body.type, 'template', 'never a free-form message');
  assert.equal(body.template.name, 'moco_login_code');
  assert.equal(body.template.language.code, 'en');
  const [bodyComponent, button] = body.template.components;
  assert.equal(bodyComponent.type, 'body');
  assert.match(bodyComponent.parameters[0].text, /^\d{6}$/);
  assert.equal(button.type, 'button');
  assert.equal(button.sub_type, 'url');
  assert.equal(button.parameters[0].text, bodyComponent.parameters[0].text);
});

test('the WhatsApp code verifies; the earlier SMS code no longer does', async () => {
  const phone = '+919811100004';
  await call('POST', '/api/auth/otp/request', { body: { phone } });
  const smsCode = lastSmsCode();
  await clearCooldown(phone);
  await call('POST', '/api/auth/otp/request', { body: { phone, channel: 'whatsapp' } });
  const waCode = lastWhatsappCode();
  assert.notEqual(smsCode, waCode);

  const oldCode = await call('POST', '/api/auth/otp/verify', { body: { phone, code: smsCode } });
  assert.equal(oldCode.status, 401, 'one live code per phone');
  const ok = await call('POST', '/api/auth/otp/verify', { body: { phone, code: waCode } });
  assert.equal(ok.status, 200);
  assert.ok(ok.body.token);
  assert.equal(ok.body.user.phone, phone);
});

test('invalid, expired and reused WhatsApp codes are rejected', async () => {
  const phone = '+919811100005';
  await call('POST', '/api/auth/otp/request', { body: { phone, channel: 'whatsapp' } });
  const code = lastWhatsappCode();
  const wrong = await call('POST', '/api/auth/otp/verify', { body: { phone, code: code === '111111' ? '222222' : '111111' } });
  assert.equal(wrong.status, 401);

  const ok = await call('POST', '/api/auth/otp/verify', { body: { phone, code } });
  assert.equal(ok.status, 200);
  const reused = await call('POST', '/api/auth/otp/verify', { body: { phone, code } });
  assert.equal(reused.status, 400);
  assert.equal(reused.body.error.code, 'otp_expired');

  await clearCooldown(phone);
  await call('POST', '/api/auth/otp/request', { body: { phone, channel: 'whatsapp' } });
  await redis.del(`otp:${phone}`); // the TTL ran out
  const expired = await call('POST', '/api/auth/otp/verify', { body: { phone, code: lastWhatsappCode() } });
  assert.equal(expired.status, 400);
  assert.equal(expired.body.error.code, 'otp_expired');
});

test('WhatsApp sends are capped per phone per hour', async () => {
  const phone = '+919811100006';
  for (let i = 0; i < env.otp.maxWhatsappPerHour; i += 1) {
    await clearCooldown(phone);
    const ok = await call('POST', '/api/auth/otp/request', { body: { phone, channel: 'whatsapp' } });
    assert.equal(ok.status, 200);
  }
  await clearCooldown(phone);
  const capped = await call('POST', '/api/auth/otp/request', { body: { phone, channel: 'whatsapp' } });
  assert.equal(capped.status, 429);
  assert.equal(capped.body.error.code, 'whatsapp_limit');
  assert.equal(graphCalls.length, env.otp.maxWhatsappPerHour);
});

test('the hourly cap counts SMS and WhatsApp together', async () => {
  const phone = '+919811100007';
  for (let i = 0; i < env.otp.maxRequestsPerHour; i += 1) {
    await clearCooldown(phone);
    const channel = i % 2 ? 'whatsapp' : 'sms';
    const ok = await call('POST', '/api/auth/otp/request', { body: { phone, channel } });
    assert.equal(ok.status, 200, `request ${i + 1} (${channel})`);
  }
  await clearCooldown(phone);
  const capped = await call('POST', '/api/auth/otp/request', { body: { phone } });
  assert.equal(capped.status, 429);
});

test('an existing user logs in through WhatsApp without a duplicate account', async () => {
  const phone = '+919811100008';
  await call('POST', '/api/auth/otp/request', { body: { phone } });
  const first = await call('POST', '/api/auth/otp/verify', { body: { phone, code: lastSmsCode() } });
  assert.equal(first.body.isNew, true);

  await call('POST', '/api/auth/otp/request', { body: { phone, channel: 'whatsapp' } });
  const second = await call('POST', '/api/auth/otp/verify', { body: { phone, code: lastWhatsappCode() } });
  assert.equal(second.status, 200);
  assert.equal(second.body.isNew, false);
  assert.equal(second.body.user.id, first.body.user.id);

  const rows = await db.query('SELECT count(*)::int AS n FROM users WHERE phone = $1', [phone]);
  assert.equal(rows.rows[0].n, 1);
});

test('a new user signing in through WhatsApp gets an account and a wallet', async () => {
  const phone = '+919811100009';
  await call('POST', '/api/auth/otp/request', { body: { phone, channel: 'whatsapp' } });
  const res = await call('POST', '/api/auth/otp/verify', { body: { phone, code: lastWhatsappCode() } });
  assert.equal(res.status, 200);
  assert.equal(res.body.isNew, true);
  const wallet = await db.query('SELECT coin_balance FROM wallets WHERE user_id = $1', [res.body.user.id]);
  assert.equal(wallet.rowCount, 1);
});

test('an SMS hard failure offers WhatsApp at once and WhatsApp then works', async () => {
  const phone = '+919811100010';
  smsFails = true;
  const failed = await call('POST', '/api/auth/otp/request', { body: { phone } });
  assert.equal(failed.status, 502);
  assert.equal(failed.body.error.code, 'sms_delivery_failed');
  assert.deepEqual(failed.body.error.details.fallbackChannels, ['whatsapp']);

  // No waiting: the failed SMS lifted the cooldown.
  const wa = await call('POST', '/api/auth/otp/request', { body: { phone, channel: 'whatsapp' } });
  assert.equal(wa.status, 200);
  const ok = await call('POST', '/api/auth/otp/verify', { body: { phone, code: lastWhatsappCode() } });
  assert.equal(ok.status, 200);
});

test('a WhatsApp provider error is reported as a friendly, typed failure', async () => {
  const phone = '+919811100011';
  whatsappResponse = { status: 400, body: { error: { code: 131026, message: 'Message undeliverable', fbtrace_id: 'x' } } };
  const res = await call('POST', '/api/auth/otp/request', { body: { phone, channel: 'whatsapp' } });
  assert.equal(res.status, 502);
  assert.equal(res.body.error.code, 'whatsapp_delivery_failed');
  assert.equal(res.body.error.details.reason, 'not_on_whatsapp');
  assert.doesNotMatch(JSON.stringify(res.body), /131026|undeliverable|fbtrace/i, 'no provider internals reach the client');
  assert.equal(await redis.exists(`otp:${phone}`), 0, 'the undelivered code is dropped');

  whatsappResponse = { status: 401, body: { error: { code: 190 } } };
  await clearCooldown(phone);
  const auth = await call('POST', '/api/auth/otp/request', { body: { phone, channel: 'whatsapp' } });
  assert.equal(auth.body.error.details.reason, 'unavailable');
});

test('WhatsApp is refused when it is not configured', async () => {
  const saved = env.whatsapp.accessToken;
  env.whatsapp.accessToken = '';
  try {
    const res = await call('POST', '/api/auth/otp/request', { body: { phone: '+919811100012', channel: 'whatsapp' } });
    assert.equal(res.status, 400);
    assert.equal(res.body.error.code, 'whatsapp_unavailable');
    const sms = await call('POST', '/api/auth/otp/request', { body: { phone: '+919811100013' } });
    assert.deepEqual(sms.body.fallbackChannels, [], 'no WhatsApp fallback offered');
  } finally {
    env.whatsapp.accessToken = saved;
  }
});

test('an unknown channel is rejected', async () => {
  const res = await call('POST', '/api/auth/otp/request', { body: { phone: '+919811100014', channel: 'email' } });
  assert.equal(res.status, 400);
});

test('no OTP code ever appears in the logs', async () => {
  const phone = '+919811100015';
  await call('POST', '/api/auth/otp/request', { body: { phone } });
  await clearCooldown(phone);
  await call('POST', '/api/auth/otp/request', { body: { phone, channel: 'whatsapp' } });
  whatsappResponse = { status: 500, body: { error: { code: 1 } } };
  await clearCooldown(phone);
  await call('POST', '/api/auth/otp/request', { body: { phone, channel: 'whatsapp' } });
  const codes = [...delivered.sms, ...delivered.whatsapp].map((d) => d.code);
  assert.ok(codes.length >= 2);
  const all = logged.join('\n');
  assert.match(all, /otp requested/, 'the log capture is live');
  assert.match(all, /whatsapp otp sent/);
  assert.match(all, /whatsapp send failed/);
  for (const code of codes) assert.ok(!all.includes(code), 'an OTP code was logged');
  assert.ok(!all.includes('test-access-token'), 'the access token was logged');
  assert.ok(!all.includes('9811100015'), 'a full phone number was logged');
});

test('webhook: the verification handshake needs the right token', async () => {
  const ok = await call('GET', '/api/webhooks/whatsapp?hub.mode=subscribe&hub.verify_token=test-verify-token&hub.challenge=12345');
  assert.equal(ok.status, 200);
  assert.equal(String(ok.body), '12345');
  const bad = await call('GET', '/api/webhooks/whatsapp?hub.mode=subscribe&hub.verify_token=nope&hub.challenge=12345');
  assert.equal(bad.status, 403);
});

test('webhook: status callbacks are accepted only with a valid signature', async () => {
  const payload = JSON.stringify({
    entry: [{ changes: [{ value: { statuses: [{ id: 'wamid.x', status: 'failed', recipient_id: '919811100016', errors: [{ code: 131026 }] }] } }] }],
  });
  const unsigned = await call('POST', '/api/webhooks/whatsapp', { raw: payload });
  assert.equal(unsigned.status, 401);
  const forged = await call('POST', '/api/webhooks/whatsapp', { raw: payload, headers: { 'X-Hub-Signature-256': 'sha256=deadbeef' } });
  assert.equal(forged.status, 401);
  const signature = `sha256=${crypto.createHmac('sha256', 'test-app-secret').update(payload).digest('hex')}`;
  const signed = await call('POST', '/api/webhooks/whatsapp', { raw: payload, headers: { 'X-Hub-Signature-256': signature } });
  assert.equal(signed.status, 200);
});
