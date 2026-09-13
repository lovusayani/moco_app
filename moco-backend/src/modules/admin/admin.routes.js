'use strict';

const express = require('express');
const { z } = require('zod');
const { query, withTransaction } = require('../../config/db');
const { payoutQueue } = require('../../workers/queues');
const notifications = require('../notifications/notifications.service');
const { validate } = require('../../middleware/validate');
const { asyncHandler } = require('../../middleware/error');
const { authenticate, requireAdmin } = require('../../middleware/auth');
const { notFound, badRequest } = require('../../utils/errors');
const { KYC_STATUS, PAYOUT_STATUS } = require('../../utils/constants');
const logger = require('../../utils/logger');

const router = express.Router();
router.use(authenticate, requireAdmin);

/** KYC queue. */
router.get(
  '/kyc',
  asyncHandler(async (req, res) => {
    const { rows } = await query(
      `SELECT lp.user_id, lp.kyc_name, lp.kyc_doc_url, lp.upi_id, lp.updated_at,
              u.phone, u.display_name
         FROM listener_profiles lp JOIN users u ON u.id = lp.user_id
        WHERE lp.kyc_status = $1
        ORDER BY lp.updated_at ASC LIMIT 100`,
      [KYC_STATUS.PENDING],
    );
    res.json({ pending: rows });
  }),
);

router.post(
  '/kyc/:userId',
  validate(z.object({ userId: z.coerce.number().int().positive() }), 'params'),
  validate(z.object({ approve: z.boolean(), note: z.string().max(500).optional() })),
  asyncHandler(async (req, res) => {
    const nextStatus = req.body.approve ? KYC_STATUS.APPROVED : KYC_STATUS.REJECTED;

    const { rows } = await query(
      `UPDATE listener_profiles SET kyc_status = $2, updated_at = now()
        WHERE user_id = $1 RETURNING user_id, kyc_status`,
      [req.params.userId, nextStatus],
    );

    if (rows.length === 0) throw notFound('Listener profile');

    await notifications.create({
      userId: rows[0].user_id,
      type: req.body.approve ? 'kyc_approved' : 'kyc_rejected',
      title: req.body.approve ? 'You are verified!' : 'Verification was not approved',
      body: req.body.approve
        ? 'You can now go online and take calls.'
        : req.body.note || 'Please review your details and try again.',
    });

    logger.info(
      { adminId: req.user.id, userId: req.params.userId, status: nextStatus },
      'kyc reviewed',
    );
    res.json({ userId: rows[0].user_id, kycStatus: rows[0].kyc_status });
  }),
);

/** Payout queue and approval. Approval enqueues the worker that actually pays. */
router.get(
  '/payouts',
  asyncHandler(async (req, res) => {
    const { rows } = await query(
      `SELECT p.id, p.listener_id, p.amount, p.status, p.created_at,
              u.display_name, u.phone, lp.upi_id, lp.earnings_balance
         FROM payouts p
         JOIN users u ON u.id = p.listener_id
         JOIN listener_profiles lp ON lp.user_id = p.listener_id
        WHERE p.status = $1
        ORDER BY p.created_at ASC LIMIT 100`,
      [PAYOUT_STATUS.REQUESTED],
    );
    res.json({ pending: rows });
  }),
);

router.post(
  '/payouts/:id',
  validate(z.object({ id: z.coerce.number().int().positive() }), 'params'),
  validate(z.object({ approve: z.boolean(), note: z.string().max(500).optional() })),
  asyncHandler(async (req, res) => {
    const payout = await withTransaction(async (client) => {
      const { rows } = await client.query(
        `UPDATE payouts SET status = $2, note = $3
          WHERE id = $1 AND status = $4
          RETURNING *`,
        [
          req.params.id,
          req.body.approve ? PAYOUT_STATUS.APPROVED : PAYOUT_STATUS.REJECTED,
          req.body.note ?? null,
          PAYOUT_STATUS.REQUESTED,
        ],
      );

      if (rows.length === 0) {
        throw badRequest('not_pending', 'This payout is not awaiting approval');
      }
      return rows[0];
    });

    // The worker does the debit; approving only authorises it.
    if (req.body.approve) {
      await payoutQueue.add('payout', { payoutId: payout.id }, { jobId: `payout-${payout.id}` });
    }

    await notifications.create({
      userId: payout.listener_id,
      type: req.body.approve ? 'payout_approved' : 'payout_rejected',
      title: req.body.approve ? 'Withdrawal approved' : 'Withdrawal rejected',
      body: req.body.approve
        ? `Your withdrawal of ₹${payout.amount} is on its way.`
        : req.body.note || `Your withdrawal of ₹${payout.amount} was rejected.`,
      data: { payoutId: payout.id },
    });

    logger.info({ adminId: req.user.id, payoutId: payout.id, approved: req.body.approve }, 'payout reviewed');
    res.json({ payoutId: payout.id, status: payout.status });
  }),
);

/** Report queue and moderation actions. */
router.get(
  '/reports',
  asyncHandler(async (req, res) => {
    const { rows } = await query(
      `SELECT r.id, r.reason, r.details, r.status, r.created_at, r.call_id,
              reporter.display_name AS reporter_name,
              reported.id AS reported_id, reported.display_name AS reported_name,
              (SELECT count(*)::int FROM reports r2 WHERE r2.reported_id = r.reported_id) AS total_reports
         FROM reports r
         JOIN users reporter ON reporter.id = r.reporter_id
         JOIN users reported ON reported.id = r.reported_id
        WHERE r.status IN ('open', 'reviewing')
        ORDER BY total_reports DESC, r.created_at ASC LIMIT 100`,
    );
    res.json({ reports: rows });
  }),
);

router.post(
  '/reports/:id',
  validate(z.object({ id: z.coerce.number().int().positive() }), 'params'),
  validate(
    z.object({
      action: z.enum(['dismiss', 'suspend']),
      note: z.string().max(500).optional(),
    }),
  ),
  asyncHandler(async (req, res) => {
    const result = await withTransaction(async (client) => {
      const { rows } = await client.query(
        `UPDATE reports SET status = $2, resolved_at = now()
          WHERE id = $1 RETURNING reported_id, status`,
        [req.params.id, req.body.action === 'suspend' ? 'actioned' : 'dismissed'],
      );

      if (rows.length === 0) throw notFound('Report');

      if (req.body.action === 'suspend') {
        await client.query(`UPDATE users SET status = 'suspended' WHERE id = $1`, [
          rows[0].reported_id,
        ]);
        // A suspended listener must stop appearing in discovery at once.
        await client.query(
          `UPDATE listener_profiles SET is_online = FALSE WHERE user_id = $1`,
          [rows[0].reported_id],
        );
      }

      return rows[0];
    });

    logger.warn(
      { adminId: req.user.id, reportId: req.params.id, action: req.body.action },
      'report actioned',
    );
    res.json({ reportId: Number(req.params.id), status: result.status });
  }),
);

/** Platform metrics for the admin dashboard. */
router.get(
  '/stats',
  asyncHandler(async (req, res) => {
    const { rows } = await query(`
      SELECT
        (SELECT count(*)::int FROM users WHERE status = 'active') AS active_users,
        (SELECT count(*)::int FROM listener_profiles WHERE kyc_status = 'approved') AS approved_listeners,
        (SELECT count(*)::int FROM listener_profiles WHERE is_online) AS online_listeners,
        (SELECT count(*)::int FROM calls WHERE status = 'active') AS live_calls,
        (SELECT count(*)::int FROM calls WHERE created_at >= date_trunc('day', now())) AS calls_today,
        (SELECT COALESCE(SUM(coins_debited), 0)::bigint FROM call_ticks
          WHERE created_at >= date_trunc('day', now())) AS coins_spent_today,
        (SELECT COALESCE(SUM(platform_share), 0)::bigint FROM call_ticks
          WHERE created_at >= date_trunc('day', now())) AS platform_revenue_today,
        (SELECT COALESCE(SUM(delta), 0)::bigint FROM coin_ledger
          WHERE reason = 'topup' AND created_at >= date_trunc('day', now())) AS coins_purchased_today,
        (SELECT count(*)::int FROM listener_profiles WHERE kyc_status = 'pending') AS pending_kyc,
        (SELECT count(*)::int FROM payouts WHERE status = 'requested') AS pending_payouts,
        (SELECT count(*)::int FROM reports WHERE status IN ('open', 'reviewing')) AS open_reports
    `);
    res.json(rows[0]);
  }),
);

/**
 * Reconciliation check: every wallet balance must equal the sum of its ledger.
 * A non-empty result means money moved without a ledger row, which would be a
 * serious bug — this endpoint exists so that is detectable rather than silent.
 */
router.get(
  '/reconcile',
  asyncHandler(async (req, res) => {
    const { rows } = await query(`
      SELECT w.user_id, w.coin_balance,
             COALESCE(SUM(cl.delta), 0)::bigint AS ledger_total
        FROM wallets w
        LEFT JOIN coin_ledger cl ON cl.user_id = w.user_id
       GROUP BY w.user_id, w.coin_balance
      HAVING w.coin_balance <> COALESCE(SUM(cl.delta), 0)
       LIMIT 100
    `);
    res.json({ balanced: rows.length === 0, discrepancies: rows });
  }),
);

module.exports = router;
