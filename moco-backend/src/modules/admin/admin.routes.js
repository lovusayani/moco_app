'use strict';

const express = require('express');
const { query } = require('../../config/db');
const { asyncHandler } = require('../../middleware/error');
const { authenticate, requireAdmin } = require('../../middleware/auth');
const { listenerEligibleSql } = require('../../utils/constants');

/**
 * /api/admin — every route below, including every mounted module, sits
 * behind authenticate + requireAdmin (server-side ADMIN_PHONES allow-list).
 * Hiding a button in the console is never the access control.
 */
const router = express.Router();
router.use(authenticate, requireAdmin);

router.get('/me', (req, res) => {
  res.json({ id: req.user.id, phone: req.user.phone, email: req.user.email, name: req.user.display_name, isAdmin: true });
});

router.use(require('./users.admin'));
router.use(require('./listeners.admin'));
router.use(require('./reports.admin'));
router.use(require('./operations.admin'));
router.use(require('../settings/login_background').router);
router.use(require('./deletion.admin'));

/** Platform metrics for the admin dashboard. */
router.get(
  '/stats',
  asyncHandler(async (req, res) => {
    const { rows } = await query(`
      SELECT
        (SELECT count(*)::int FROM users WHERE status = 'active') AS active_users,
        (SELECT count(*)::int FROM users WHERE status = 'suspended') AS suspended_users,
        (SELECT count(*)::int FROM users WHERE created_at >= date_trunc('day', now())) AS new_users_today,
        (SELECT count(*)::int FROM listener_profiles lp WHERE lp.kyc_status = 'approved' AND lp.user_id IN (SELECT id FROM users WHERE status <> 'deleted')) AS approved_listeners,
        (SELECT count(*)::int FROM listener_profiles lp WHERE ${listenerEligibleSql('lp')} AND lp.user_id IN (SELECT id FROM users WHERE status <> 'deleted')) AS active_listeners,
        (SELECT count(*)::int FROM listener_profiles WHERE is_online) AS online_listeners,
        (SELECT count(*)::int FROM calls WHERE status = 'active') AS live_calls,
        (SELECT count(*)::int FROM calls WHERE created_at >= date_trunc('day', now())) AS calls_today,
        (SELECT COALESCE(SUM(coins_debited), 0)::bigint FROM call_ticks
          WHERE created_at >= date_trunc('day', now())) AS coins_spent_today,
        (SELECT COALESCE(SUM(platform_share), 0)::bigint FROM call_ticks
          WHERE created_at >= date_trunc('day', now())) AS platform_revenue_today,
        (SELECT COALESCE(SUM(delta), 0)::bigint FROM coin_ledger
          WHERE reason = 'topup' AND created_at >= date_trunc('day', now())) AS coins_purchased_today,
        (SELECT count(*)::int FROM listener_profiles lp WHERE lp.kyc_status = 'pending' AND lp.user_id IN (SELECT id FROM users WHERE status <> 'deleted')) AS pending_kyc,
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
