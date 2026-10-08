'use strict';

const express = require('express');
const { z } = require('zod');
const { query, withTransaction } = require('../../config/db');
const { validate } = require('../../middleware/validate');
const { asyncHandler } = require('../../middleware/error');
const { isAdminUser } = require('../../middleware/auth');
const { notFound, badRequest, conflict } = require('../../utils/errors');
const { USER_STATUS, listenerEligibleSql, listenerBlockers } = require('../../utils/constants');
const audit = require('./audit.service');
const { listSchema, Where, orderBy, limitOffset, pageOf, likeTerm } = require('./admin.list');

/**
 * Admin: users. Mounted under /api/admin, which already requires an
 * authenticated admin for every route — nothing here is reachable otherwise.
 */
const router = express.Router();

const PHONE = z.string().trim().regex(/^\+[1-9]\d{7,14}$/, 'Use international format, e.g. +919876543210');
const idParam = z.object({ id: z.coerce.number().int().positive() });

const USER_SORT = {
  id: 'u.id',
  created: 'u.created_at',
  name: 'lower(u.display_name)',
  balance: 'COALESCE(w.coin_balance, 0)',
  lastActive: 'la.last_login',
  status: 'u.status',
};

router.get(
  '/users',
  validate(
    listSchema(Object.keys(USER_SORT), {
      status: z.enum(['active', 'suspended', 'deleted']).optional(),
      role: z.enum(['user', 'listener', 'both']).optional(),
      listener: z
        .enum(['none', 'unsubmitted', 'pending', 'approved', 'rejected', 'eligible'])
        .optional(),
    }),
    'query',
  ),
  asyncHandler(async (req, res) => {
    const { q, status, role, listener, from, to, sort, dir } = req.query;
    const where = new Where()
      .maybe(status, 'u.status = ?')
      .maybe(role, 'u.role = ?')
      .dateRange('u.created_at', from, to);

    if (q) {
      const term = likeTerm(q);
      where.add('(u.display_name ILIKE ? OR u.phone ILIKE ? OR u.id::text = ?)', term, term, q);
    }
    if (listener === 'none') where.add('lp.user_id IS NULL');
    else if (listener === 'eligible') where.add(listenerEligibleSql('lp'));
    else if (listener) where.add('lp.kyc_status = ?', listener);

    const { rows } = await query(
      `SELECT u.id, u.phone, u.email, u.display_name, u.role, u.status, u.gender, u.language,
              u.created_at, COALESCE(w.coin_balance, 0) AS coin_balance,
              lp.kyc_status, lp.photo_count, lp.is_online,
              ${listenerEligibleSql('lp')} AS listener_eligible,
              la.last_login,
              count(*) OVER () AS total_count
         FROM users u
         LEFT JOIN wallets w ON w.user_id = u.id
         LEFT JOIN listener_profiles lp ON lp.user_id = u.id
         LEFT JOIN LATERAL (
           SELECT max(ae.created_at) AS last_login
             FROM auth_events ae WHERE ae.user_id = u.id AND ae.event = 'login'
         ) la ON TRUE
         ${where.sql}
         ${orderBy(USER_SORT, sort, dir, 'created', 'u.id')}
         ${limitOffset(where, req.query)}`,
      where.params,
    );

    res.json(
      pageOf(rows, req.query, (r) => ({
        id: r.id,
        phone: r.phone,
        name: r.display_name,
        role: r.role,
        status: r.status,
        gender: r.gender,
        language: r.language,
        createdAt: r.created_at,
        coinBalance: Number(r.coin_balance),
        lastActive: r.last_login,
        listener: r.kyc_status
          ? {
              kycStatus: r.kyc_status,
              photoCount: r.photo_count,
              isOnline: r.is_online,
              eligible: r.listener_eligible,
            }
          : null,
        isAdmin: isAdminUser(r),
      })),
    );
  }),
);

router.get(
  '/users/:id',
  validate(idParam, 'params'),
  asyncHandler(async (req, res) => {
    const id = req.params.id;
    const { rows } = await query(
      `SELECT u.*, COALESCE(w.coin_balance, 0) AS coin_balance,
              lp.kyc_status, lp.photo_count, lp.is_online, lp.is_busy,
              lp.earnings_balance, lp.lifetime_earnings, lp.total_calls,
              ${listenerEligibleSql('lp')} AS listener_eligible,
              (SELECT max(created_at) FROM auth_events
                WHERE user_id = u.id AND event = 'login') AS last_login,
              (SELECT count(*)::int FROM blocks WHERE blocker_id = u.id) AS blocks_given,
              (SELECT count(*)::int FROM blocks WHERE blocked_id = u.id) AS blocks_received
         FROM users u
         LEFT JOIN wallets w ON w.user_id = u.id
         LEFT JOIN listener_profiles lp ON lp.user_id = u.id
        WHERE u.id = $1`,
      [id],
    );
    const u = rows[0];
    if (!u) throw notFound('User');

    // Independent reads in parallel — each is one query, no per-row fan-out.
    const [ledger, calls, reports, history] = await Promise.all([
      query(
        `SELECT id, delta, reason, ref_id, balance_after, created_at
           FROM coin_ledger WHERE user_id = $1
          ORDER BY created_at DESC, id DESC LIMIT 20`,
        [id],
      ),
      query(
        `SELECT c.id, c.type, c.status, c.created_at, c.started_at, c.ended_at, c.end_reason,
                c.billed_minutes, c.coins_spent, c.listener_earned,
                c.caller_id, c.listener_id,
                CASE WHEN c.caller_id = $1 THEN 'caller' ELSE 'listener' END AS side,
                other.display_name AS other_name
           FROM calls c
           JOIN users other ON other.id = CASE WHEN c.caller_id = $1 THEN c.listener_id ELSE c.caller_id END
          WHERE c.caller_id = $1 OR c.listener_id = $1
          ORDER BY c.created_at DESC LIMIT 20`,
        [id],
      ),
      query(
        `SELECT r.id, r.reason, r.status, r.created_at, r.call_id,
                CASE WHEN r.reported_id = $1 THEN 'against' ELSE 'filed' END AS direction,
                other.display_name AS other_name, other.id AS other_id
           FROM reports r
           JOIN users other ON other.id = CASE WHEN r.reported_id = $1 THEN r.reporter_id ELSE r.reported_id END
          WHERE r.reported_id = $1 OR r.reporter_id = $1
          ORDER BY r.created_at DESC LIMIT 20`,
        [id],
      ),
      audit.historyFor('user', id),
    ]);

    const callStats = await query(
      `SELECT count(*)::int AS total,
              count(*) FILTER (WHERE caller_id = $1)::int AS as_caller,
              count(*) FILTER (WHERE listener_id = $1)::int AS as_listener,
              COALESCE(SUM(coins_spent) FILTER (WHERE caller_id = $1), 0)::bigint AS coins_spent
         FROM calls WHERE caller_id = $1 OR listener_id = $1`,
      [id],
    );

    res.json({
      id: u.id,
      phone: u.phone,
      email: u.email,
      name: u.display_name,
      avatarUrl: u.avatar_url,
      role: u.role,
      status: u.status,
      gender: u.gender,
      language: u.language,
      freeTrialUsed: u.free_trial_used,
      createdAt: u.created_at,
      updatedAt: u.updated_at,
      lastActive: u.last_login,
      isAdmin: isAdminUser(u),
      wallet: { coinBalance: Number(u.coin_balance) },
      listener: u.kyc_status
        ? {
            kycStatus: u.kyc_status,
            photoCount: u.photo_count,
            isOnline: u.is_online,
            isBusy: u.is_busy,
            eligible: u.listener_eligible,
            blockers: listenerBlockers({ kycStatus: u.kyc_status, photoCount: u.photo_count }),
            earningsBalance: Number(u.earnings_balance),
            lifetimeEarnings: Number(u.lifetime_earnings),
            totalCalls: u.total_calls,
          }
        : null,
      moderation: {
        status: u.status,
        reportsAgainst: reports.rows.filter((r) => r.direction === 'against').length,
        blocksGiven: u.blocks_given,
        blocksReceived: u.blocks_received,
      },
      callStats: callStats.rows[0],
      ledger: ledger.rows,
      calls: calls.rows,
      reports: reports.rows,
      history,
    });
  }),
);

/**
 * Admin-created user. Follows the OTP identity model exactly: an account is
 * a phone number plus its wallet — there is no password to set. The person
 * signs in later with an OTP to that number and lands in this account.
 */
router.post(
  '/users',
  validate(
    z.object({
      phone: PHONE,
      displayName: z.string().trim().min(2).max(40).optional(),
      language: z.enum(['en', 'hi', 'te']).optional(),
      gender: z.enum(['male', 'female', 'other']).optional(),
      reason: z.string().trim().max(500).optional(),
    }),
  ),
  asyncHandler(async (req, res) => {
    const { phone, displayName, language, gender, reason } = req.body;

    const user = await withTransaction(async (client) => {
      const existing = await client.query('SELECT id FROM users WHERE phone = $1', [phone]);
      if (existing.rows[0]) {
        throw conflict('user_exists', `An account with ${phone} already exists (user #${existing.rows[0].id})`);
      }
      const { rows } = await client.query(
        `INSERT INTO users (phone, display_name, language, gender)
         VALUES ($1, $2, COALESCE($3, 'en'), $4) RETURNING *`,
        [phone, displayName ?? null, language ?? null, gender ?? null],
      );
      await client.query('INSERT INTO wallets (user_id, coin_balance) VALUES ($1, 0)', [rows[0].id]);
      await audit.record(client, {
        admin: req.user,
        action: 'user.create',
        targetType: 'user',
        targetId: rows[0].id,
        reason,
        metadata: { phone, displayName: displayName ?? null },
      });
      return rows[0];
    });

    res.status(201).json({ id: user.id, phone: user.phone, name: user.display_name, status: user.status });
  }),
);

/** Suspend / restore. A suspended account loses API access on its next
 * request (authenticate re-reads status every time) and leaves discovery. */
router.post(
  '/users/:id/status',
  validate(idParam, 'params'),
  validate(
    z.object({
      status: z.enum([USER_STATUS.ACTIVE, USER_STATUS.SUSPENDED]),
      reason: z.string().trim().min(3).max(500),
    }),
  ),
  asyncHandler(async (req, res) => {
    const { status, reason } = req.body;
    const id = Number(req.params.id);

    if (id === Number(req.user.id)) throw badRequest('self_action', 'You cannot change your own account status');

    const result = await withTransaction(async (client) => {
      const { rows: found } = await client.query(
        'SELECT id, phone, email, status FROM users WHERE id = $1 FOR UPDATE',
        [id],
      );
      const target = found[0];
      if (!target) throw notFound('User');
      if (target.status === USER_STATUS.DELETED) {
        throw badRequest('account_deleted', 'Deleted accounts cannot be suspended or restored');
      }
      if (status === USER_STATUS.SUSPENDED && isAdminUser(target)) {
        throw badRequest('admin_account', 'Admin accounts cannot be suspended from the console');
      }
      if (target.status === status) {
        throw badRequest('no_change', `This account is already ${status}`);
      }

      await client.query('UPDATE users SET status = $2, updated_at = now() WHERE id = $1', [id, status]);
      if (status === USER_STATUS.SUSPENDED) {
        await client.query('UPDATE listener_profiles SET is_online = FALSE WHERE user_id = $1', [id]);
      }
      await audit.record(client, {
        admin: req.user,
        action: status === USER_STATUS.SUSPENDED ? 'user.suspend' : 'user.restore',
        targetType: 'user',
        targetId: id,
        reason,
        metadata: { from: target.status, to: status },
      });
      return { id, status };
    });

    res.json(result);
  }),
);

module.exports = router;
