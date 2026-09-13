'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('http');

const { createApp } = require('../src/app');
const db = require('../src/config/db');
const redisConfig = require('../src/config/redis');
const queues = require('../src/workers/queues');
const { resetDb, createUser, balanceOf, ledgerCount } = require('./helpers');
const { signToken } = require('../src/middleware/auth');
const purchasesService = require('../src/modules/purchases/purchases.service');

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

/** A fake Google Play verifier — the same seam production code injects the
 * real integrations/google_play.js through, but never overrides. */
function fakeVerifier(result) {
  return { verifyPurchase: async () => result };
}

test('an unknown product id is rejected before any verification is attempted', async () => {
  await resetDb();
  const user = await createUser();
  let verifierCalled = false;

  await assert.rejects(
    () =>
      purchasesService.verifyAndCredit({
        userId: user.id,
        productId: 'not_a_real_pack',
        purchaseToken: 'tok',
        verifier: { verifyPurchase: async () => { verifierCalled = true; } },
      }),
    /unknown_product|not.*coin pack/i,
  );
  assert.equal(verifierCalled, false);
});

test('an invalid purchase (Google says no) grants nothing', async () => {
  await resetDb();
  const user = await createUser();

  await assert.rejects(
    () =>
      purchasesService.verifyAndCredit({
        userId: user.id,
        productId: 'pack_49',
        purchaseToken: 'bad-token',
        verifier: fakeVerifier({ valid: false, reason: 'not_found' }),
      }),
    /invalid_purchase/,
  );

  assert.equal(await balanceOf(user.id), 0);
  assert.equal(await ledgerCount(user.id), 0);
});

test('a verified purchase credits the wallet transactionally with a ledger row', async () => {
  await resetDb();
  const user = await createUser();

  const result = await purchasesService.verifyAndCredit({
    userId: user.id,
    productId: 'pack_99', // 99 coins + 5 bonus = 104
    purchaseToken: 'good-token',
    verifier: fakeVerifier({ valid: true, orderId: 'GPA.order-1' }),
  });

  assert.equal(result.alreadyProcessed, false);
  assert.equal(result.coinsGranted, 104);
  assert.equal(result.balance, 104);
  assert.equal(await balanceOf(user.id), 104);
  assert.equal(await ledgerCount(user.id), 1);
});

test('the same purchase token is never credited twice', async () => {
  await resetDb();
  const user = await createUser();
  const verifier = fakeVerifier({ valid: true, orderId: 'GPA.order-2' });

  const first = await purchasesService.verifyAndCredit({
    userId: user.id,
    productId: 'pack_49',
    purchaseToken: 'same-token',
    verifier,
  });
  const second = await purchasesService.verifyAndCredit({
    userId: user.id,
    productId: 'pack_49',
    purchaseToken: 'same-token',
    verifier,
  });

  assert.equal(first.alreadyProcessed, false);
  assert.equal(second.alreadyProcessed, true);
  assert.equal(second.coinsGranted, first.coinsGranted);
  // Only one credit ever landed, no matter how many times the token is sent.
  assert.equal(await balanceOf(user.id), 49);
  assert.equal(await ledgerCount(user.id), 1);
});

test('concurrent verify calls for the same token credit exactly once', async () => {
  await resetDb();
  const user = await createUser();
  const verifier = fakeVerifier({ valid: true, orderId: 'GPA.order-3' });

  const [a, b] = await Promise.all([
    purchasesService.verifyAndCredit({
      userId: user.id,
      productId: 'pack_49',
      purchaseToken: 'race-token',
      verifier,
    }),
    purchasesService.verifyAndCredit({
      userId: user.id,
      productId: 'pack_49',
      purchaseToken: 'race-token',
      verifier,
    }),
  ]);

  const processedFlags = [a.alreadyProcessed, b.alreadyProcessed].sort();
  assert.deepEqual(processedFlags, [false, true]);
  assert.equal(await balanceOf(user.id), 49);
  assert.equal(await ledgerCount(user.id), 1);
});

test('a client-supplied coin amount does not exist — coins come only from the pack', async () => {
  await resetDb();
  const user = await createUser();

  // verifyAndCredit accepts no coins/amount field at all; this asserts the
  // credited amount is always what the server's own pack table says for
  // pack_299, regardless of anything a request could have claimed.
  const result = await purchasesService.verifyAndCredit({
    userId: user.id,
    productId: 'pack_299',
    purchaseToken: 'tok-amount-check',
    verifier: fakeVerifier({ valid: true }),
  });

  assert.equal(result.coinsGranted, 324); // 299 + 25 bonus
});

test('the raw purchase token is never stored — only its hash', async () => {
  await resetDb();
  const user = await createUser();
  const token = 'super-secret-play-token';

  await purchasesService.verifyAndCredit({
    userId: user.id,
    productId: 'pack_49',
    purchaseToken: token,
    verifier: fakeVerifier({ valid: true }),
  });

  const { query } = require('../src/config/db');
  const { rows } = await query('SELECT token_hash FROM purchases');
  assert.equal(rows.length, 1);
  assert.notEqual(rows[0].token_hash, token);
  assert.equal(rows[0].token_hash, purchasesService.hashToken(token));
});

test('the HTTP route requires authentication', async () => {
  await resetDb();
  const res = await call('POST', '/api/purchases/google/verify', {
    body: { productId: 'pack_49', purchaseToken: 'tok' },
  });
  assert.equal(res.status, 401);
});

test('the HTTP route rejects a malformed body', async () => {
  await resetDb();
  const user = await createUser();
  const res = await call('POST', '/api/purchases/google/verify', {
    token: signToken(user),
    body: { productId: 'pack_49' }, // missing purchaseToken
  });
  assert.equal(res.status, 400);
});

test('without Google Play configured, the route fails honestly rather than crediting', async () => {
  await resetDb();
  const user = await createUser();

  // This test environment has no GOOGLE_PLAY_SERVICE_ACCOUNT_JSON set, so
  // the route falls through to the real (unconfigured) integration — the
  // exact path a production deployment without Play credentials would hit.
  const res = await call('POST', '/api/purchases/google/verify', {
    token: signToken(user),
    body: { productId: 'pack_49', purchaseToken: 'tok' },
  });

  assert.equal(res.status, 400);
  assert.equal(res.body.error.code, 'google_play_not_configured');
  assert.equal(await balanceOf(user.id), 0);
});

test('purchase history lists verified purchases newest first', async () => {
  await resetDb();
  const user = await createUser();
  await purchasesService.verifyAndCredit({
    userId: user.id,
    productId: 'pack_49',
    purchaseToken: 'tok-a',
    verifier: fakeVerifier({ valid: true }),
  });
  await purchasesService.verifyAndCredit({
    userId: user.id,
    productId: 'pack_99',
    purchaseToken: 'tok-b',
    verifier: fakeVerifier({ valid: true }),
  });

  const res = await call('GET', '/api/purchases', { token: signToken(user) });
  assert.equal(res.status, 200);
  assert.equal(res.body.purchases.length, 2);
  assert.equal(res.body.purchases[0].productId, 'pack_99');
  assert.equal(res.body.purchases[0].status, 'verified');
});
