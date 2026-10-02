'use strict';

const express = require('express');
const { z } = require('zod');
const { query, withTransaction } = require('../../config/db');
const { payoutQueue } = require('../../workers/queues');
const notifications = require('../notifications/notifications.service');
const { validate } = require('../../middleware/validate');
const { asyncHandler } = require('../../middleware/error');
const { authenticate, requireAdmin } = require('../../middleware/auth');
const { badRequest } = require('../../utils/errors');
const { PAYOUT_STATUS, listenerEligibleSql } = require('../../utils/constants');
const audit = require('./audit.service');

/**
 * /api/admin — every route below, including every mounted module, sits
 * behind authenticate + requireAdmin (server-side ADMIN_PHONES allow-list).
 * Hiding a button in the console is never the access control.
 */
const router = express.Router();
router.use(authenticate, requireAdmin);

router.get('/me', (req, res) => {
  res.json({ id: req.user.id, phone: req.user.phone, name: req.user.display_name, isAdmin: true });
});

router.use(require('./users.admin'));
router.use(require('./listeners.admin'));
router.use(require('./reports.admin'));

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
      await audit.record(client, {
        admin: req.user,
        action: req.body.approve ? 'payout.approve' : 'payout.reject',
        targetType: 'payout',
        targetId: rows[0].id,
        reason: req.body.note,
        metadata: { listenerId: rows[0].listener_id, amount: Number(rows[0].amount) },
      });
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

    res.json({ payoutId: payout.id, status: payout.status });
  }),
);

/** Platform metrics for the admin dashboard. */
router.get(
  '/stats',
  asyncHandler(async (req, res) => {
    const { rows } = await query(`
      SELECT
        (SELECT count(*)::int FROM users WHERE status = 'active') AS active_users,
        (SELECT count(*)::int FROM users WHERE status = 'suspended') AS suspended_users,
        (SELECT count(*)::int FROM users WHERE created_at >= date_trunc('day', now())) AS new_users_today,
        (SELECT count(*)::int FROM listener_profiles WHERE kyc_status = 'approved') AS approved_listeners,
        (SELECT count(*)::int FROM listener_profiles lp WHERE ${listenerEligibleSql('lp')}) AS active_listeners,
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
        (SELECT count(*)::int FROM reports WHERE status IN ('open', 'reviewing')) AS open_reports,
        (SELECT count(*)::int FROM admin_audit_log WHERE created_at >= date_trunc('day', now())) AS admin_actions_today
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
