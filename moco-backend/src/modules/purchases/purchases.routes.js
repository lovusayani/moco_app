'use strict';

const express = require('express');
const { z } = require('zod');
const purchasesService = require('./purchases.service');
const { validate } = require('../../middleware/validate');
const { asyncHandler } = require('../../middleware/error');
const { authenticate } = require('../../middleware/auth');
const { rateLimit } = require('../../middleware/rateLimit');

const router = express.Router();
router.use(authenticate);

/**
 * Google Play purchase verification.
 *
 * Flutter's job ends at obtaining a purchase token from Google Play Billing
 * and sending it here — it never credits its own wallet. Everything that
 * decides whether coins are actually granted happens server-side: which
 * pack `productId` maps to, whether Google confirms the purchase, and
 * whether this token has already been credited.
 */
router.post(
  '/google/verify',
  rateLimit({ windowSeconds: 60, max: 20, keyPrefix: 'purchase_verify' }),
  validate(
    z.object({
      productId: z.string().min(1).max(60),
      purchaseToken: z.string().min(10).max(4000),
    }),
  ),
  asyncHandler(async (req, res) => {
    const result = await purchasesService.verifyAndCredit({
      userId: req.user.id,
      productId: req.body.productId,
      purchaseToken: req.body.purchaseToken,
    });

    res.json({
      coinBalance: result.balance,
      coinsGranted: result.coinsGranted,
      alreadyProcessed: result.alreadyProcessed,
    });
  }),
);

router.get(
  '/',
  asyncHandler(async (req, res) => {
    const purchases = await purchasesService.history(req.user.id);
    res.json({
      purchases: purchases.map((p) => ({
        id: p.id,
        productId: p.product_id,
        status: p.status,
        coinsGranted: p.coins_granted,
        createdAt: p.created_at,
        verifiedAt: p.verified_at,
      })),
    });
  }),
);

module.exports = router;
