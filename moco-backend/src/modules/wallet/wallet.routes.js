'use strict';

const express = require('express');
const { z } = require('zod');
const walletService = require('./wallet.service');
const paymentGateway = require('../../integrations/payment.gateway');
const { validate } = require('../../middleware/validate');
const { asyncHandler } = require('../../middleware/error');
const { authenticate } = require('../../middleware/auth');
const { rateLimit } = require('../../middleware/rateLimit');
const { badRequest, notFound } = require('../../utils/errors');
const { findCoinPack, packTotalCoins, RATES } = require('../../utils/constants');
const logger = require('../../utils/logger');

const router = express.Router();

/**
 * Coin packs and rates. Public so the client can render the wallet screen and
 * the rate card before the user signs in.
 */
router.get('/packs', (req, res) => {
  res.json({
    packs: walletService.listPacks().map((pack) => ({
      id: pack.id,
      priceInr: pack.priceInr,
      coins: pack.coins,
      bonus: pack.bonus,
      totalCoins: packTotalCoins(pack),
    })),
    rates: {
      audio: RATES.audio.coinsPerMinute,
      video: RATES.video.coinsPerMinute,
    },
  });
});

router.get(
  '/',
  authenticate,
  asyncHandler(async (req, res) => {
    const balance = await walletService.getBalance(req.user.id);
    res.json({
      coinBalance: balance,
      audioMinutes: Math.floor(balance / RATES.audio.coinsPerMinute),
      videoMinutes: Math.floor(balance / RATES.video.coinsPerMinute),
    });
  }),
);

router.get(
  '/ledger',
  authenticate,
  validate(
    z.object({
      limit: z.coerce.number().int().min(1).max(100).default(50),
      before: z.coerce.number().int().positive().optional(),
    }),
    'query',
  ),
  asyncHandler(async (req, res) => {
    const entries = await walletService.getLedger(req.user.id, {
      limit: req.query.limit,
      before: req.query.before,
    });
    res.json({
      entries: entries.map((entry) => ({
        id: entry.id,
        delta: entry.delta,
        reason: entry.reason,
        refId: entry.ref_id,
        balanceAfter: entry.balance_after,
        createdAt: entry.created_at,
      })),
      nextCursor: entries.length > 0 ? entries[entries.length - 1].id : null,
    });
  }),
);

/**
 * Starts a coin purchase. This only creates the gateway order — no coins are
 * credited here. Credit happens in the webhook, because a client can lie about
 * a payment succeeding but it cannot forge a signed webhook.
 */
router.post(
  '/topup',
  authenticate,
  rateLimit({ windowSeconds: 60, max: 10, keyPrefix: 'topup' }),
  validate(z.object({ packId: z.string().min(1) })),
  asyncHandler(async (req, res) => {
    const pack = findCoinPack(req.body.packId);
    if (!pack) throw notFound('Coin pack');

    const order = await paymentGateway.createOrder({ pack, userId: req.user.id });

    res.json({
      order,
      pack: {
        id: pack.id,
        priceInr: pack.priceInr,
        totalCoins: packTotalCoins(pack),
      },
    });
  }),
);

/**
 * Payment webhook. Mounted with a raw body parser (see app.js) so the exact
 * bytes the gateway signed are available for verification — a re-serialised
 * JSON body would not match the signature.
 */
router.post(
  '/webhook',
  asyncHandler(async (req, res) => {
    const signature =
      req.headers['x-razorpay-signature'] || req.headers['x-webhook-signature'];

    if (!paymentGateway.verifyWebhook(req.body, signature)) {
      logger.warn({ ip: req.ip }, 'rejected payment webhook with bad signature');
      // 400, not 500: this is a client error and the gateway should not retry.
      throw badRequest('invalid_signature', 'Signature verification failed');
    }

    const event = JSON.parse(req.body.toString('utf8'));
    const payment = event?.payload?.payment?.entity || event;
    const notes = payment.notes || {};
    const userId = Number(notes.userId);
    const packId = notes.packId;
    const paymentRef = payment.order_id || payment.id;

    if (!userId || !packId || !paymentRef) {
      logger.error({ event }, 'payment webhook missing required notes');
      // 200 so the gateway stops retrying something we can never process.
      return res.json({ ok: false, reason: 'missing_fields' });
    }

    try {
      const result = await walletService.applyTopup({ userId, packId, paymentRef });
      return res.json({ ok: true, balance: result.balance });
    } catch (err) {
      // A duplicate delivery is a success from the gateway's point of view.
      if (err.code === 'topup_already_applied') return res.json({ ok: true, duplicate: true });
      throw err;
    }
  }),
);

module.exports = router;
