'use strict';

const { withTransaction, query } = require('../../config/db');
const { insufficientBalance, notFound, conflict } = require('../../utils/errors');
const { LEDGER_REASON, EARNING_REASON, COIN_PACKS, findCoinPack, packTotalCoins } =
  require('../../utils/constants');
const logger = require('../../utils/logger');

/**
 * The only code in the system permitted to move coins.
 *
 * Every function here takes an optional `client` so it can enlist in a caller's
 * transaction. The billing engine relies on that: a tick's debit, its ledger
 * row, its listener credit and its call_ticks row must all commit together or
 * not at all.
 */

/**
 * Debits a wallet, refusing rather than overdrawing.
 *
 * The `coin_balance >= $1` predicate inside the UPDATE is the race guard from
 * the design: two concurrent debits both read the same balance, but only one
 * can satisfy the predicate at write time, so the second returns no rows
 * instead of driving the balance negative.
 */
async function debit(client, { userId, amount, reason, refId }) {
  if (!Number.isInteger(amount) || amount <= 0) {
    throw new Error(`debit amount must be a positive integer, got ${amount}`);
  }

  const { rows } = await client.query(
    `UPDATE wallets
        SET coin_balance = coin_balance - $1, updated_at = now()
      WHERE user_id = $2 AND coin_balance >= $1
      RETURNING coin_balance`,
    [amount, userId],
  );

  if (rows.length === 0) {
    throw insufficientBalance();
  }

  const balanceAfter = rows[0].coin_balance;

  await client.query(
    `INSERT INTO coin_ledger (user_id, delta, reason, ref_id, balance_after)
     VALUES ($1, $2, $3, $4, $5)`,
    [userId, -amount, reason, refId ?? null, balanceAfter],
  );

  return balanceAfter;
}

/** Credits a wallet and records the matching ledger row. */
async function credit(client, { userId, amount, reason, refId }) {
  if (!Number.isInteger(amount) || amount <= 0) {
    throw new Error(`credit amount must be a positive integer, got ${amount}`);
  }

  const { rows } = await client.query(
    `INSERT INTO wallets (user_id, coin_balance, updated_at)
     VALUES ($1, $2, now())
     ON CONFLICT (user_id)
       DO UPDATE SET coin_balance = wallets.coin_balance + EXCLUDED.coin_balance,
                     updated_at = now()
     RETURNING coin_balance`,
    [userId, amount],
  );

  const balanceAfter = rows[0].coin_balance;

  await client.query(
    `INSERT INTO coin_ledger (user_id, delta, reason, ref_id, balance_after)
     VALUES ($1, $2, $3, $4, $5)`,
    [userId, amount, reason, refId ?? null, balanceAfter],
  );

  return balanceAfter;
}

/**
 * Credits a listener's earnings. Mirrors `credit`, against the separate
 * earnings ledger — a listener's earned rupees are not spendable coins, so the
 * two balances are deliberately kept apart.
 */
async function creditListener(client, { listenerId, amount, reason, refId }) {
  if (!Number.isInteger(amount) || amount <= 0) {
    throw new Error(`listener credit must be a positive integer, got ${amount}`);
  }

  const { rows } = await client.query(
    `UPDATE listener_profiles
        SET earnings_balance = earnings_balance + $1,
            lifetime_earnings = lifetime_earnings + $1,
            updated_at = now()
      WHERE user_id = $2
      RETURNING earnings_balance`,
    [amount, listenerId],
  );

  if (rows.length === 0) throw notFound('Listener profile');

  const balanceAfter = rows[0].earnings_balance;

  await client.query(
    `INSERT INTO listener_earnings (listener_id, delta, reason, ref_id, balance_after)
     VALUES ($1, $2, $3, $4, $5)`,
    [listenerId, amount, reason, refId ?? null, balanceAfter],
  );

  return balanceAfter;
}

/** Debits a listener's earnings balance, used when a payout is approved. */
async function debitListener(client, { listenerId, amount, reason, refId }) {
  const { rows } = await client.query(
    `UPDATE listener_profiles
        SET earnings_balance = earnings_balance - $1, updated_at = now()
      WHERE user_id = $2 AND earnings_balance >= $1
      RETURNING earnings_balance`,
    [amount, listenerId],
  );

  if (rows.length === 0) throw insufficientBalance('Not enough earnings to withdraw');

  const balanceAfter = rows[0].earnings_balance;

  await client.query(
    `INSERT INTO listener_earnings (listener_id, delta, reason, ref_id, balance_after)
     VALUES ($1, $2, $3, $4, $5)`,
    [listenerId, -amount, reason, refId ?? null, balanceAfter],
  );

  return balanceAfter;
}

async function getBalance(userId) {
  const { rows } = await query('SELECT coin_balance FROM wallets WHERE user_id = $1', [userId]);
  return rows[0]?.coin_balance ?? 0;
}

async function getLedger(userId, { limit = 50, before } = {}) {
  const { rows } = await query(
    `SELECT id, delta, reason, ref_id, balance_after, created_at
       FROM coin_ledger
      WHERE user_id = $1 AND ($2::bigint IS NULL OR id < $2)
      ORDER BY id DESC
      LIMIT $3`,
    [userId, before ?? null, Math.min(limit, 100)],
  );
  return rows;
}

/**
 * Applies a completed coin-pack purchase.
 *
 * `paymentRef` is the gateway's order id, and the partial unique index on
 * coin_ledger makes a second call with the same ref fail at the database. That
 * is what makes a duplicated payment webhook safe: the retry cannot double
 * credit, regardless of how many times it is delivered.
 */
async function applyTopup({ userId, packId, paymentRef }) {
  const pack = findCoinPack(packId);
  if (!pack) throw notFound('Coin pack');

  const total = packTotalCoins(pack);

  try {
    return await withTransaction(async (client) => {
      const balance = await credit(client, {
        userId,
        amount: total,
        reason: LEDGER_REASON.TOPUP,
        refId: paymentRef,
      });
      logger.info({ userId, packId, total, paymentRef }, 'topup applied');
      return { balance, coinsCredited: total, pack };
    });
  } catch (err) {
    if (err.code === '23505') {
      // Already credited by an earlier delivery of the same webhook.
      logger.info({ userId, paymentRef }, 'duplicate topup ignored');
      throw conflict('topup_already_applied', 'This payment has already been credited');
    }
    throw err;
  }
}

const listPacks = () => COIN_PACKS;

module.exports = {
  debit,
  credit,
  creditListener,
  debitListener,
  getBalance,
  getLedger,
  applyTopup,
  listPacks,
  LEDGER_REASON,
  EARNING_REASON,
};
