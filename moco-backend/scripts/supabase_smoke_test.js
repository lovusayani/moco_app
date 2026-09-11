'use strict';

// One-off smoke test against Supabase Postgres + Upstash Redis, run manually.
// Not part of `npm test` — this hits the real running server on :3000.
require('dotenv').config();
const { pool, close: closeDb } = require('../src/config/db');

const BASE = 'http://127.0.0.1:3000/api';
const CALLER_PHONE = '+919800000001'; // seeded, balance 45

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

let passed = 0;
let failed = 0;

function check(label, condition, extra) {
  if (condition) {
    passed += 1;
    console.log(`  ok   ${label}`);
  } else {
    failed += 1;
    console.error(`  FAIL ${label}`, extra ?? '');
  }
}

async function call(method, path, { token, body } = {}) {
  const response = await fetch(`${BASE}${path}`, {
    method,
    headers: {
      'Content-Type': 'application/json',
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await response.text();
  let json;
  try {
    json = text ? JSON.parse(text) : {};
  } catch {
    json = { raw: text };
  }
  return { status: response.status, body: json };
}

async function login(phone) {
  const req = await call('POST', '/auth/otp/request', { body: { phone } });
  check(`otp request (${phone})`, req.status === 200 && req.body.sent === true, req.body);

  const verify = await call('POST', '/auth/otp/verify', {
    body: { phone, code: '123456' },
  });
  check(`otp verify (${phone})`, verify.status === 200 && !!verify.body.token, verify.body);
  return verify.body;
}

async function main() {
  console.log('== Auth ==');
  const session = await login(CALLER_PHONE);
  const token = session.token;
  const callerId = session.user.id;

  console.log('== GET /users/me ==');
  const me = await call('GET', '/users/me', { token });
  check('users/me returns canonical shape', me.status === 200 && me.body.id === callerId, me.body);
  console.log(`  balance: ${me.body.coinBalance}, freeTrialAvailable: ${me.body.freeTrialAvailable}`);

  console.log('== Discovery ==');
  const discovery = await call('GET', '/listeners?limit=10', { token });
  check(
    'discovery returns approved listeners',
    discovery.status === 200 && Array.isArray(discovery.body.listeners) && discovery.body.listeners.length > 0,
    discovery.body,
  );
  const listener = discovery.body.listeners[0];
  console.log(`  first listener: id=${listener?.id} name=${listener?.name} audioRate=${listener?.audioRate}`);

  // The API never exposes a phone number — looked up directly from the DB
  // purely so this script can sign in as the listener to accept the call.
  const { rows: listenerRows } = await pool.query('SELECT phone FROM users WHERE id = $1', [
    listener.id,
  ]);
  const listenerPhone = listenerRows[0].phone;

  console.log('== Listener Profile ==');
  const profile = await call('GET', `/listeners/${listener.id}`, { token });
  check('listener profile loads', profile.status === 200 && profile.body.id === listener.id, profile.body);

  console.log('== Favorite / Follow ==');
  const fav = await call('PUT', `/listeners/${listener.id}/favorite`, { token });
  check('favorite set (idempotent)', fav.status === 200 && fav.body.active === true, fav.body);
  const favAgain = await call('PUT', `/listeners/${listener.id}/favorite`, { token });
  check('favorite is idempotent on repeat PUT', favAgain.status === 200 && favAgain.body.active === true, favAgain.body);
  const follow = await call('PUT', `/listeners/${listener.id}/follow`, { token });
  check('follow set', follow.status === 200 && follow.body.active === true, follow.body);
  const unfollow = await call('DELETE', `/listeners/${listener.id}/follow`, { token });
  check('unfollow clears', unfollow.status === 200 && unfollow.body.active === false, unfollow.body);

  console.log('== Call 1: burn the free trial (end before any tick) ==');
  const initiate1 = await call('POST', '/calls/initiate', {
    token,
    body: { listenerId: listener.id, type: 'audio' },
  });
  check('call 1 initiates', initiate1.status === 201, initiate1.body);
  check('call 1 is free-trial eligible', initiate1.body.freeSeconds > 0, initiate1.body);

  const listenerSession = await login(listenerPhone);
  const accept1 = await call('POST', `/calls/${initiate1.body.callId}/accept`, {
    token: listenerSession.token,
  });
  check('call 1 accepts', accept1.status === 200 && accept1.body.status === 'active', accept1.body);

  const end1 = await call('POST', `/calls/${initiate1.body.callId}/end`, { token });
  check(
    'call 1 ends with zero billed minutes (trial burned, no tick fired yet)',
    end1.status === 200 && end1.body.billedMinutes === 0 && end1.body.coinsSpent === 0,
    end1.body,
  );

  console.log('== Call 2: real billing tick ==');
  const initiate2 = await call('POST', '/calls/initiate', {
    token,
    body: { listenerId: listener.id, type: 'audio' },
  });
  check('call 2 initiates', initiate2.status === 201, initiate2.body);
  check('call 2 is no longer free-trial eligible', initiate2.body.freeSeconds === 0, initiate2.body);
  const balanceBeforeTick = initiate2.body.balance;

  const accept2 = await call('POST', `/calls/${initiate2.body.callId}/accept`, {
    token: listenerSession.token,
  });
  check('call 2 accepts', accept2.status === 200, accept2.body);

  // Minute 1 is scheduled with 0 delay (non-trial accept) — give the tick
  // worker a few seconds to pick the BullMQ job up and settle it.
  let ticked = false;
  for (let i = 0; i < 8 && !ticked; i += 1) {
    await sleep(1000);
    const live = await call('GET', `/calls/${initiate2.body.callId}`, { token });
    if (live.body.billedMinutes > 0) ticked = true;
  }
  check('call 2 billed at least one minute via the tick worker', ticked);

  const end2 = await call('POST', `/calls/${initiate2.body.callId}/end`, { token });
  check('call 2 ends with billedMinutes >= 1', end2.status === 200 && end2.body.billedMinutes >= 1, end2.body);
  check(
    'call 2 end response carries callerBalance',
    typeof end2.body.callerBalance === 'number',
    end2.body,
  );

  console.log('== Wallet debit + ledger reconciliation ==');
  const wallet = await call('GET', '/wallet', { token });
  check(
    'wallet balance matches call-end callerBalance',
    wallet.status === 200 && wallet.body.coinBalance === end2.body.callerBalance,
    { wallet: wallet.body, end2: end2.body },
  );
  check(
    'wallet balance dropped from the pre-tick snapshot',
    wallet.body.coinBalance < balanceBeforeTick,
    { before: balanceBeforeTick, after: wallet.body.coinBalance },
  );

  const ledger = await call('GET', '/wallet/ledger?limit=5', { token });
  const debitEntry = ledger.body.entries?.find((e) => e.reason === 'call_debit');
  check('ledger has a call_debit entry', ledger.status === 200 && !!debitEntry, ledger.body);

  console.log(`\n${passed} passed, ${failed} failed`);
  await closeDb();
  process.exit(failed > 0 ? 1 : 0);
}

main().catch(async (err) => {
  console.error('SMOKE TEST CRASHED', err);
  await closeDb();
  process.exit(1);
});
