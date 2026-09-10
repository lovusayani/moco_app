'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const walletService = require('../src/modules/wallet/wallet.service');
const db = require('../src/config/db');
const redisConfig = require('../src/config/redis');
const { createUser, balanceOf, resetDb } = require('./helpers');
const { LEDGER_REASON, findCoinPack, packTotalCoins } = require('../src/utils/constants');

test.after(async () => {
  await db.close();
  await redisConfig.close();
});

test('every coin pack credits its face value plus bonus', async () => {
  await resetDb();
  const expected = {
    pack_49: 49,
    pack_99: 104,
    pack_299: 324,
    pack_599: 674,
    pack_999: 1149,
  };

  for (const [packId, total] of Object.entries(expected)) {
    const user = await createUser();
    const result = await walletService.applyTopup({
      userId: user.id,
      packId,
      paymentRef: `ref_${packId}_${user.id}`,
    });
    assert.equal(result.coinsCredited, total, `${packId} should credit ${total}`);
    assert.equal(await balanceOf(user.id), total);
    assert.equal(packTotalCoins(findCoinPack(packId)), total);
  }
});

test('a replayed payment webhook credits only once', async () => {
  await resetDb();
  const user = await createUser();

  await walletService.applyTopup({ userId: user.id, packId: 'pack_99', paymentRef: 'order_1' });

  await assert.rejects(
    () => walletService.applyTopup({ userId: user.id, packId: 'pack_99', paymentRef: 'order_1' }),
    (err) => err.code === 'topup_already_applied',
  );

  assert.equal(await balanceOf(user.id), 104, 'balance must not double');
});

test('distinct payments both credit', async () => {
  await resetDb();
  const user = await createUser();
  await walletService.applyTopup({ userId: user.id, packId: 'pack_49', paymentRef: 'order_a' });
  await walletService.applyTopup({ userId: user.id, packId: 'pack_49', paymentRef: 'order_b' });
  assert.equal(await balanceOf(user.id), 98);
});

test('a debit cannot overdraw', async () => {
  await resetDb();
  const user = await createUser({ balance: 10 });

  await assert.rejects(
    () =>
      db.withTransaction((client) =>
        walletService.debit(client, {
          userId: user.id,
          amount: 11,
          reason: LEDGER_REASON.CALL_DEBIT,
        }),
      ),
    (err) => err.code === 'insufficient_balance',
  );

  assert.equal(await balanceOf(user.id), 10, 'a refused debit must leave the balance untouched');
});

test('concurrent debits cannot drive a balance negative', async () => {
  await resetDb();
  // 10 coins: exactly one 6-coin debit can succeed.
  const user = await createUser({ balance: 10 });

  const attempts = Array.from({ length: 8 }, () =>
    db
      .withTransaction((client) =>
        walletService.debit(client, {
          userId: user.id,
          amount: 6,
          reason: LEDGER_REASON.CALL_DEBIT,
        }),
      )
      .then(() => 'ok')
      .catch(() => 'refused'),
  );

  const results = await Promise.all(attempts);
  assert.equal(results.filter((r) => r === 'ok').length, 1);
  assert.equal(await balanceOf(user.id), 4);
});

test('the ledger always reconstructs the balance', async () => {
  await resetDb();
  const user = await createUser({ balance: 0 });

  await walletService.applyTopup({ userId: user.id, packId: 'pack_299', paymentRef: 'o1' });
  await db.withTransaction((client) =>
    walletService.debit(client, { userId: user.id, amount: 12, reason: LEDGER_REASON.CALL_DEBIT }),
  );
  await db.withTransaction((client) =>
    walletService.credit(client, { userId: user.id, amount: 5, reason: LEDGER_REASON.REFUND }),
  );

  const { rows } = await db.query(
    'SELECT COALESCE(SUM(delta),0)::bigint AS total FROM coin_ledger WHERE user_id = $1',
    [user.id],
  );
  assert.equal(rows[0].total, await balanceOf(user.id));
  assert.equal(await balanceOf(user.id), 324 - 12 + 5);
});

test('the ledger is append-only', async () => {
  await resetDb();
  const user = await createUser({ balance: 50 });

  await assert.rejects(
    () => db.query('UPDATE coin_ledger SET delta = 9999 WHERE user_id = $1', [user.id]),
    /append-only/,
  );
  await assert.rejects(
    () => db.query('DELETE FROM coin_ledger WHERE user_id = $1', [user.id]),
    /append-only/,
  );
});

test('a listener earnings credit is mirrored in the earnings ledger', async () => {
  await resetDb();
  const listener = await createUser({ listener: true });

  await db.withTransaction((client) =>
    walletService.creditListener(client, {
      listenerId: listener.id,
      amount: 2,
      reason: 'call_credit',
      refId: '1',
    }),
  );

  const { rows } = await db.query(
    'SELECT delta, balance_after FROM listener_earnings WHERE listener_id = $1',
    [listener.id],
  );
  assert.equal(rows.length, 1);
  assert.equal(rows[0].delta, 2);
  assert.equal(rows[0].balance_after, 2);
});

test('a listener cannot withdraw more than they have earned', async () => {
  await resetDb();
  const listener = await createUser({ listener: true });

  await db.withTransaction((client) =>
    walletService.creditListener(client, {
      listenerId: listener.id,
      amount: 100,
      reason: 'call_credit',
    }),
  );

  await assert.rejects(
    () =>
      db.withTransaction((client) =>
        walletService.debitListener(client, {
          listenerId: listener.id,
          amount: 101,
          reason: 'payout',
        }),
      ),
    (err) => err.code === 'insufficient_balance',
  );
});
