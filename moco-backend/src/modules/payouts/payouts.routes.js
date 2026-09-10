'use strict';

const express = require('express');
const { z } = require('zod');
const { query, withTransaction } = require('../../config/db');
const { validate } = require('../../middleware/validate');
const { asyncHandler } = require('../../middleware/error');
const { authenticate, requireListener } = require('../../middleware/auth');
const { badRequest, notFound } = require('../../utils/errors');
const { MIN_PAYOUT_INR, PAYOUT_STATUS, KYC_STATUS } = require('../../utils/constants');

const router = express.Router();
router.use(authenticate, requireListener);

/** Earnings dashboard: balance, lifetime total, and a recent breakdown. */
router.get(
  '/earnings',
  asyncHandler(async (req, res) => {
    const { rows } = await query(
      `SELECT earnings_balance, lifetime_earnings, total_calls, rating, upi_id, kyc_status
         FROM listener_profiles WHERE user_id = $1`,
      [req.user.id],
    );

    const profile = rows[0];
    if (!profile) throw notFound('Listener profile');

    // Today's and this month's earnings, for the dashboard's summary cards.
    const { rows: totals } = await query(
      `SELECT
         COALESCE(SUM(delta) FILTER (WHERE created_at >= date_trunc('day', now())), 0)::bigint AS today,
         COALESCE(SUM(delta) FILTER (WHERE created_at >= date_trunc('month', now())), 0)::bigint AS month
       FROM listener_earnings
      WHERE listener_id = $1 AND reason = 'call_credit'`,
      [req.user.id],
    );

    res.json({
      balance: profile.earnings_balance,
      lifetime: profile.lifetime_earnings,
      today: totals[0].today,
      thisMonth: totals[0].month,
      totalCalls: profile.total_calls,
      rating: Number(profile.rating),
      upiId: profile.upi_id,
      minWithdrawal: MIN_PAYOUT_INR,
      canWithdraw:
        profile.kyc_status === KYC_STATUS.APPROVED &&
        profile.earnings_balance >= MIN_PAYOUT_INR &&
        Boolean(profile.upi_id),
    });
  }),
);

router.get(
  '/earnings/ledger',
  validate(
    z.object({
      limit: z.coerce.number().int().min(1).max(100).default(50),
      before: z.coerce.number().int().positive().optional(),
    }),
    'query',
  ),
  asyncHandler(async (req, res) => {
    const { rows } = await query(
      `SELECT id, delta, reason, ref_id, balance_after, created_at
         FROM listener_earnings
        WHERE listener_id = $1 AND ($2::bigint IS NULL OR id < $2)
        ORDER BY id DESC LIMIT $3`,
      [req.user.id, req.query.before ?? null, req.query.limit],
    );
    res.json({ entries: rows, nextCursor: rows.length > 0 ? rows[rows.length - 1].id : null });
  }),
);

/**
 * Requests a withdrawal.
 *
 * The earnings balance is *not* debited here — that happens in the payout
 * worker once an admin approves. But the pending amount is checked against the
 * balance inside a transaction so a listener cannot stack several requests that
 * together exceed what they have earned.
 */
router.post(
  '/',
  validate(z.object({ amount: z.coerce.number().int().positive() })),
  asyncHandler(async (req, res) => {
    const { amount } = req.body;

    if (amount < MIN_PAYOUT_INR) {
      throw badRequest('below_minimum', `Minimum withdrawal is ${MIN_PAYOUT_INR}`);
    }

    const payout = await withTransaction(async (client) => {
      const { rows } = await client.query(
        `SELECT earnings_balance, kyc_status, upi_id
           FROM listener_profiles WHERE user_id = $1 FOR UPDATE`,
        [req.user.id],
      );

      const profile = rows[0];
      if (!profile) throw notFound('Listener profile');
      if (profile.kyc_status !== KYC_STATUS.APPROVED) {
        throw badRequest('kyc_required', 'Complete verification before withdrawing');
      }
      if (!profile.upi_id) {
        throw badRequest('upi_required', 'Add a UPI ID before withdrawing');
      }

      const { rows: pendingRows } = await client.query(
        `SELECT COALESCE(SUM(amount), 0)::bigint AS pending
           FROM payouts WHERE listener_id = $1 AND status IN ($2, $3)`,
        [req.user.id, PAYOUT_STATUS.REQUESTED, PAYOUT_STATUS.APPROVED],
      );

      const available = profile.earnings_balance - pendingRows[0].pending;
      if (amount > available) {
        throw badRequest(
          'insufficient_earnings',
          `You can withdraw at most ${available} right now`,
        );
      }

      const { rows: created } = await client.query(
        `INSERT INTO payouts (listener_id, amount) VALUES ($1, $2) RETURNING *`,
        [req.user.id, amount],
      );
      return created[0];
    });

    res.status(201).json({
      payoutId: payout.id,
      amount: payout.amount,
      status: payout.status,
      createdAt: payout.created_at,
    });
  }),
);

router.get(
  '/',
  asyncHandler(async (req, res) => {
    const { rows } = await query(
      `SELECT id, amount, status, upi_ref, note, created_at, processed_at
         FROM payouts WHERE listener_id = $1 ORDER BY id DESC LIMIT 50`,
      [req.user.id],
    );
    res.json({ payouts: rows });
  }),
);

module.exports = router;
