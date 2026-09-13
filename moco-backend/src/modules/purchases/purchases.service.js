'use strict';

const crypto = require('crypto');
const { withTransaction, query } = require('../../config/db');
const walletService = require('../wallet/wallet.service');
const defaultVerifier = require('../../integrations/google_play');
const { findCoinPack, packTotalCoins, LEDGER_REASON } = require('../../utils/constants');
const { badRequest } = require('../../utils/errors');
const logger = require('../../utils/logger');

const hashToken = (token) => crypto.createHash('sha256').update(token).digest('hex');

/**
 * Verifies one Google Play purchase and credits the wallet exactly once.
 *
 * `productId` is the coin pack id itself (e.g. `pack_99`) — the Play Console
 * product SKU is configured to match it 1:1, so there is no separate mapping
 * table to keep in sync with COIN_PACKS. `findCoinPack` is the same lookup
 * the mock/Razorpay topup path already uses.
 *
 * The client-supplied coin amount does not exist here — there is no such
 * field. Coins credited are always `packTotalCoins(pack)`, computed
 * server-side from the productId Google itself confirmed, never from
 * anything the request body could claim.
 *
 * `verifier` defaults to the real Google Play integration and is only ever
 * overridden by tests — production code always takes the default.
 */
async function verifyAndCredit({ userId, productId, purchaseToken, verifier = defaultVerifier }) {
  const pack = findCoinPack(productId);
  if (!pack) throw badRequest('unknown_product', 'That product is not a coin pack Moco sells');

  const tokenHash = hashToken(purchaseToken);

  // Idempotency check #1: a purchase already recorded for this token, verified
  // or not, is never re-verified or re-credited — the first outcome stands.
  const { rows: existingRows } = await query(
    `SELECT id, status, coins_granted FROM purchases WHERE token_hash = $1`,
    [tokenHash],
  );
  if (existingRows[0]) {
    const existing = existingRows[0];
    logger.info({ userId, productId, purchaseId: existing.id }, 'purchase already processed');
    return {
      alreadyProcessed: true,
      coinsGranted: existing.coins_granted,
      balance: await walletService.getBalance(userId),
    };
  }

  // Ask Google. Any failure here (including "not configured") is a real,
  // honest failure — never treated as a successful purchase.
  let verification;
  try {
    verification = await verifier.verifyPurchase({ productId, purchaseToken });
  } catch (err) {
    if (err.code === 'google_play_not_configured') {
      throw badRequest(
        'google_play_not_configured',
        'Purchases are not available on this build yet',
      );
    }
    throw err;
  }

  if (!verification.valid) {
    // Recorded as invalid so a retry of the same bad token is also a fast,
    // idempotent no-op rather than a second live call to Google.
    await query(
      `INSERT INTO purchases (user_id, token_hash, product_id, status, order_id)
       VALUES ($1, $2, $3, 'invalid', $4)
       ON CONFLICT (token_hash) DO NOTHING`,
      [userId, tokenHash, productId, verification.orderId ?? null],
    );
    throw badRequest(
      'invalid_purchase',
      `Google Play did not confirm this purchase (${verification.reason ?? 'unknown'})`,
    );
  }

  const totalCoins = packTotalCoins(pack);

  try {
    const result = await withTransaction(async (client) => {
      // Idempotency check #2, inside the transaction: closes the race where
      // two concurrent requests both pass check #1 before either inserts.
      // UNIQUE (token_hash) is what actually enforces this — the row insert
      // below either succeeds once or throws 23505.
      const { rows } = await client.query(
        `INSERT INTO purchases
           (user_id, token_hash, product_id, order_id, status, coins_granted, verified_at)
         VALUES ($1, $2, $3, $4, 'verified', $5, now())
         RETURNING id`,
        [userId, tokenHash, productId, verification.orderId ?? null, totalCoins],
      );

      const balance = await walletService.credit(client, {
        userId,
        amount: totalCoins,
        reason: LEDGER_REASON.TOPUP,
        refId: `google_play:${rows[0].id}`,
      });

      return { balance, purchaseId: rows[0].id };
    });

    logger.info(
      { userId, productId, purchaseId: result.purchaseId, totalCoins },
      'google play purchase verified and credited',
    );

    return { alreadyProcessed: false, coinsGranted: totalCoins, balance: result.balance };
  } catch (err) {
    if (err.code === '23505') {
      // Lost the race to a concurrent request for the same token — that one
      // already credited the wallet; this one must not credit it again.
      logger.info({ userId, productId }, 'duplicate purchase token, already credited');
      const { rows } = await query(
        `SELECT coins_granted FROM purchases WHERE token_hash = $1`,
        [tokenHash],
      );
      return {
        alreadyProcessed: true,
        coinsGranted: rows[0]?.coins_granted ?? totalCoins,
        balance: await walletService.getBalance(userId),
      };
    }
    throw err;
  }
}

async function history(userId) {
  const { rows } = await query(
    `SELECT id, product_id, status, coins_granted, created_at, verified_at
       FROM purchases WHERE user_id = $1 ORDER BY id DESC LIMIT 50`,
    [userId],
  );
  return rows;
}

module.exports = { verifyAndCredit, history, hashToken };
