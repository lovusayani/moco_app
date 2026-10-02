'use strict';

const express = require('express');
const fs = require('fs');
const path = require('path');
const { z } = require('zod');
const { query, withTransaction, pool } = require('../../config/db');
const { redis } = require('../../config/redis');
const storage = require('../../integrations/storage');
const feedStorage = require('../../integrations/feed.storage');
const walletService = require('../wallet/wallet.service');
const notifications = require('../notifications/notifications.service');
const { tickQueue, payoutQueue, notificationQueue } = require('../../workers/queues');
const { validate } = require('../../middleware/validate');
const { asyncHandler } = require('../../middleware/error');
const { notFound, badRequest } = require('../../utils/errors');
const { LEDGER_REASON, PAYOUT_STATUS, REDIS } = require('../../utils/constants');
const audit = require('./audit.service');
const { listSchema, Where, orderBy, limitOffset, pageOf, likeTerm } = require('./admin.list');

/**
 * Admin operations: feed content moderation, call history (read-only),
 * wallet/ledger lookup with append-only adjustments, payouts, and system
 * health. Mounted under /api/admin behind authenticate + requireAdmin.
 */
const router = express.Router();
const idParam = z.object({ id: z.coerce.number().int().positive() });
const userIdParam = z.object({ userId: z.coerce.number().int().positive() });

// ------------------------------------------------------------------- content

const POST_SORT = { created: 'p.created_at', author: 'lower(u.display_name)', reports: 'rep.total' };

router.get(
  '/posts',
  validate(
    listSchema(Object.keys(POST_SORT), {
      status: z.enum(['active', 'removed']).optional(),
      type: z.enum(['image', 'video']).optional(),
      author: z.coerce.number().int().positive().optional(),
    }),
    'query',
  ),
  asyncHandler(async (req, res) => {
    const { q, status, type, author, from, to, sort, dir } = req.query;
    const where = new Where()
      .maybe(status, 'p.status = ?')
      .maybe(type, 'p.media_type = ?')
      .maybe(author, 'p.author_user_id = ?')
      .dateRange('p.created_at', from, to);
    if (q) {
      const term = likeTerm(q);
      where.add('(p.caption ILIKE ? OR u.display_name ILIKE ? OR u.phone ILIKE ? OR p.id::text = ?)', term, term, term, q);
    }

    const { rows } = await query(
      `SELECT p.id, p.media_type, p.media_path, p.caption, p.status, p.created_at,
              p.removed_at, p.removal_reason, remover.phone AS removed_by_phone,
              (p.removed_by IS NOT NULL) AS removed_by_admin,
              u.id AS author_id, u.display_name AS author_name, u.phone AS author_phone,
              u.status AS author_status, rep.total AS author_reports,
              count(*) OVER () AS total_count
         FROM posts p
         JOIN users u ON u.id = p.author_user_id
         LEFT JOIN users remover ON remover.id = p.removed_by
         -- Reports are filed against users, not individual posts, so the
         -- honest signal available is the author's report count.
         JOIN LATERAL (SELECT count(*)::int AS total FROM reports r WHERE r.reported_id = p.author_user_id) rep ON TRUE
         ${where.sql}
         ${orderBy(POST_SORT, sort, dir, 'created', 'p.id')}
         ${limitOffset(where, req.query)}`,
      where.params,
    );

    // Admin-removed posts keep their media (restorable); author-deleted ones
    // do not, so only sign what can exist.
    const signable = rows.filter((r) => r.status === 'active' || r.removed_by_admin).map((r) => r.media_path);
    const urls = await feedStorage.createViewUrls(signable);
    res.json(
      pageOf(rows, req.query, ({ media_path: mediaPath, ...r }) => ({
        ...r,
        mediaUrl: urls.get(mediaPath) ?? null,
        restorable: r.status === 'removed' && r.removed_by_admin,
      })),
    );
  }),
);

router.post(
  '/posts/:id',
  validate(idParam, 'params'),
  validate(
    z.object({
      action: z.enum(['remove', 'restore']),
      reason: z.string().trim().min(3).max(500),
    }),
  ),
  asyncHandler(async (req, res) => {
    const { action, reason } = req.body;
    const result = await withTransaction(async (client) => {
      const { rows } = await client.query(
        'SELECT id, status, author_user_id, removed_by FROM posts WHERE id = $1 FOR UPDATE',
        [req.params.id],
      );
      const post = rows[0];
      if (!post) throw notFound('Post');

      if (action === 'remove') {
        if (post.status === 'removed') throw badRequest('already_removed', 'This post is already removed');
        await client.query(
          `UPDATE posts SET status = 'removed', removed_at = now(), removed_by = $2, removal_reason = $3
            WHERE id = $1`,
          [post.id, req.user.id, reason],
        );
      } else {
        if (post.status === 'active') throw badRequest('not_removed', 'This post is not removed');
        // The author deleted it themselves — its media is gone, so there is
        // nothing to restore (and it was their choice).
        if (!post.removed_by) throw badRequest('author_deleted', 'The author deleted this post; it cannot be restored');
        await client.query(
          `UPDATE posts SET status = 'active', removed_at = NULL, removed_by = NULL, removal_reason = NULL
            WHERE id = $1`,
          [post.id],
        );
      }
      await audit.record(client, {
        admin: req.user,
        action: action === 'remove' ? 'content.remove' : 'content.restore',
        targetType: 'post',
        targetId: post.id,
        reason,
        metadata: { authorId: post.author_user_id },
      });
      return { id: post.id, status: action === 'remove' ? 'removed' : 'active' };
    });
    res.json(result);
  }),
);

// --------------------------------------------------------------------- calls

const CALL_SORT = {
  created: 'c.created_at',
  duration: '(c.ended_at - c.started_at)',
  minutes: 'c.billed_minutes',
  coins: 'c.coins_spent',
  earned: 'c.listener_earned',
};

router.get(
  '/calls',
  validate(
    listSchema(Object.keys(CALL_SORT), {
      type: z.enum(['audio', 'video']).optional(),
      status: z.enum(['ringing', 'active', 'ended', 'failed']).optional(),
      endReason: z.string().trim().max(40).optional(),
      caller: z.coerce.number().int().positive().optional(),
      listener: z.coerce.number().int().positive().optional(),
      user: z.coerce.number().int().positive().optional(),
    }),
    'query',
  ),
  asyncHandler(async (req, res) => {
    const { q, type, status, endReason, caller, listener, user, from, to, sort, dir } = req.query;
    const where = new Where()
      .maybe(type, 'c.type = ?')
      .maybe(status, 'c.status = ?')
      .maybe(endReason, 'c.end_reason = ?')
      .maybe(caller, 'c.caller_id = ?')
      .maybe(listener, 'c.listener_id = ?')
      .dateRange('c.created_at', from, to);
    if (user) where.add('(c.caller_id = ? OR c.listener_id = ?)', user, user);
    if (q) {
      const term = likeTerm(q);
      where.add(
        '(cu.display_name ILIKE ? OR cu.phone ILIKE ? OR lu.display_name ILIKE ? OR lu.phone ILIKE ? OR c.id::text = ?)',
        term, term, term, term, q,
      );
    }

    const { rows } = await query(
      `SELECT c.id, c.type, c.status, c.created_at, c.started_at, c.ended_at, c.end_reason,
              c.billed_minutes, c.coins_spent, c.listener_earned, c.rate_per_minute,
              c.free_seconds_granted,
              EXTRACT(EPOCH FROM (c.ended_at - c.started_at))::int AS duration_seconds,
              c.caller_id, cu.display_name AS caller_name, cu.phone AS caller_phone,
              c.listener_id, lu.display_name AS listener_name, lu.phone AS listener_phone,
              count(*) OVER () AS total_count
         FROM calls c
         JOIN users cu ON cu.id = c.caller_id
         JOIN users lu ON lu.id = c.listener_id
         ${where.sql}
         ${orderBy(CALL_SORT, sort, dir, 'created', 'c.id')}
         ${limitOffset(where, req.query)}`,
      where.params,
    );
    res.json(pageOf(rows, req.query));
  }),
);

router.get(
  '/calls/meta',
  asyncHandler(async (req, res) => {
    const { rows } = await query('SELECT DISTINCT end_reason FROM calls WHERE end_reason IS NOT NULL ORDER BY 1');
    res.json({ endReasons: rows.map((r) => r.end_reason) });
  }),
);

/** One call with its per-minute billing ticks. Read-only: historical
 * billing is never edited from the console. */
router.get(
  '/calls/:id',
  validate(idParam, 'params'),
  asyncHandler(async (req, res) => {
    const { rows } = await query(
      `SELECT c.*, EXTRACT(EPOCH FROM (c.ended_at - c.started_at))::int AS duration_seconds,
              cu.display_name AS caller_name, cu.phone AS caller_phone,
              lu.display_name AS listener_name, lu.phone AS listener_phone
         FROM calls c JOIN users cu ON cu.id = c.caller_id JOIN users lu ON lu.id = c.listener_id
        WHERE c.id = $1`,
      [req.params.id],
    );
    if (!rows[0]) throw notFound('Call');
    const [ticks, reports] = await Promise.all([
      query(
        `SELECT minute_index, coins_debited, listener_share, platform_share, created_at
           FROM call_ticks WHERE call_id = $1 ORDER BY minute_index`,
        [req.params.id],
      ),
      query(
        `SELECT r.id, r.reason, r.status, r.created_at, u.display_name AS reporter_name
           FROM reports r JOIN users u ON u.id = r.reporter_id WHERE r.call_id = $1`,
        [req.params.id],
      ),
    ]);
    const { agora_channel: _channel, ...call } = rows[0];
    res.json({ ...call, ticks: ticks.rows, reports: reports.rows });
  }),
);

// ------------------------------------------------------------ wallet / ledger

async function walletUser(userId) {
  const { rows } = await query(
    `SELECT u.id, u.display_name, u.phone, u.status, COALESCE(w.coin_balance, 0) AS coin_balance,
            w.updated_at AS wallet_updated_at,
            lp.user_id IS NOT NULL AS is_listener, lp.earnings_balance, lp.lifetime_earnings
       FROM users u
       LEFT JOIN wallets w ON w.user_id = u.id
       LEFT JOIN listener_profiles lp ON lp.user_id = u.id
      WHERE u.id = $1`,
    [userId],
  );
  if (!rows[0]) throw notFound('User');
  return rows[0];
}

router.get(
  '/wallet/:userId',
  validate(userIdParam, 'params'),
  asyncHandler(async (req, res) => {
    const u = await walletUser(req.params.userId);
    const [byReason, reconcile] = await Promise.all([
      query(
        `SELECT reason, count(*)::int AS entries, COALESCE(SUM(delta), 0)::bigint AS total
           FROM coin_ledger WHERE user_id = $1 GROUP BY reason ORDER BY reason`,
        [u.id],
      ),
      query('SELECT COALESCE(SUM(delta), 0)::bigint AS ledger_total FROM coin_ledger WHERE user_id = $1', [u.id]),
    ]);
    res.json({
      user: { id: u.id, name: u.display_name, phone: u.phone, status: u.status },
      coinBalance: Number(u.coin_balance),
      ledgerTotal: Number(reconcile.rows[0].ledger_total),
      balanced: Number(reconcile.rows[0].ledger_total) === Number(u.coin_balance),
      updatedAt: u.wallet_updated_at,
      byReason: byReason.rows.map((r) => ({ ...r, total: Number(r.total) })),
      listener: u.is_listener
        ? { earningsBalance: Number(u.earnings_balance), lifetimeEarnings: Number(u.lifetime_earnings) }
        : null,
    });
  }),
);

const LEDGER_SORT = { created: 'l.created_at', delta: 'l.delta' };
const ledgerQuery = (table, reasons) =>
  validate(
    listSchema(Object.keys(LEDGER_SORT), { reason: z.enum(reasons).optional() }),
    'query',
  );

function ledgerHandler(table, ownerColumn) {
  return asyncHandler(async (req, res) => {
    await walletUser(req.params.userId);
    const { q, reason, from, to, sort, dir } = req.query;
    const where = new Where()
      .add(`l.${ownerColumn} = ?`, req.params.userId)
      .maybe(reason, 'l.reason = ?')
      .dateRange('l.created_at', from, to);
    if (q) where.add('(l.ref_id ILIKE ? OR l.id::text = ?)', likeTerm(q), q);
    const { rows } = await query(
      `SELECT l.id, l.delta, l.reason, l.ref_id, l.balance_after, l.created_at,
              count(*) OVER () AS total_count
         FROM ${table} l
         ${where.sql}
         ${orderBy(LEDGER_SORT, sort, dir, 'created', 'l.id')}
         ${limitOffset(where, req.query)}`,
      where.params,
    );
    res.json(pageOf(rows, req.query, (r) => ({ ...r, delta: Number(r.delta), balance_after: Number(r.balance_after) })));
  });
}

router.get(
  '/ledger/:userId',
  validate(userIdParam, 'params'),
  ledgerQuery('coin_ledger', Object.values(LEDGER_REASON)),
  ledgerHandler('coin_ledger', 'user_id'),
);

router.get(
  '/earnings/:userId',
  validate(userIdParam, 'params'),
  ledgerQuery('listener_earnings', ['call_credit', 'payout']),
  ledgerHandler('listener_earnings', 'listener_id'),
);

/**
 * Manual coin adjustment. Append-only: a NEW ledger row with reason
 * admin_adjustment, written through the same wallet service every other
 * balance change uses (so balance and ledger can never disagree). The audit
 * row is written first in the same transaction and its id becomes the
 * ledger ref, tying the two together; if the debit fails (insufficient
 * coins), both roll back. Existing ledger rows are never edited.
 */
router.post(
  '/wallet/:userId/adjust',
  validate(userIdParam, 'params'),
  validate(
    z.object({
      amount: z
        .number()
        .int()
        .refine((n) => n !== 0, 'Amount cannot be zero')
        .refine((n) => Math.abs(n) <= 100_000, 'At most 100,000 coins per adjustment'),
      reason: z.string().trim().min(5).max(500),
    }),
  ),
  asyncHandler(async (req, res) => {
    const { amount, reason } = req.body;
    const target = await walletUser(req.params.userId);
    if (target.status === 'deleted') throw badRequest('account_deleted', 'Cannot adjust a deleted account');

    const outcome = await withTransaction(async (client) => {
      const auditId = await audit.record(client, {
        admin: req.user,
        action: 'wallet.adjust',
        targetType: 'user',
        targetId: target.id,
        reason,
        metadata: { amount, balanceBefore: Number(target.coin_balance) },
      });
      const refId = `admin_adj:${auditId}`;
      const op = amount > 0 ? walletService.credit : walletService.debit;
      const balanceAfter = await op(client, {
        userId: target.id,
        amount: Math.abs(amount),
        reason: LEDGER_REASON.ADMIN_ADJUSTMENT,
        refId,
      });
      return { auditId, refId, balanceAfter: Number(balanceAfter) };
    });

    res.status(201).json({ userId: target.id, amount, ...outcome });
  }),
);

// ------------------------------------------------------------------- payouts

const PAYOUT_SORT = { created: 'p.created_at', amount: 'p.amount', processed: 'p.processed_at' };

router.get(
  '/payouts',
  validate(
    listSchema(Object.keys(PAYOUT_SORT), {
      status: z.enum(['requested', 'approved', 'paid', 'rejected', 'all']).default('requested'),
    }),
    'query',
  ),
  asyncHandler(async (req, res) => {
    const { q, status, from, to, sort, dir } = req.query;
    const where = new Where().dateRange('p.created_at', from, to);
    if (status !== 'all') where.add('p.status = ?', status);
    if (q) {
      const term = likeTerm(q);
      where.add('(u.display_name ILIKE ? OR u.phone ILIKE ? OR lp.upi_id ILIKE ? OR p.upi_ref ILIKE ? OR p.id::text = ?)', term, term, term, term, q);
    }
    const effectiveDir = !sort && status === 'requested' ? 'asc' : dir;
    const { rows } = await query(
      `SELECT p.id, p.listener_id, p.amount, p.status, p.note, p.upi_ref, p.created_at, p.processed_at,
              p.reviewed_at, reviewer.phone AS reviewed_by_phone,
              u.display_name, u.phone, lp.upi_id, lp.earnings_balance, lp.kyc_status,
              count(*) OVER () AS total_count
         FROM payouts p
         JOIN users u ON u.id = p.listener_id
         JOIN listener_profiles lp ON lp.user_id = p.listener_id
         LEFT JOIN users reviewer ON reviewer.id = p.reviewed_by
         ${where.sql}
         ${orderBy(PAYOUT_SORT, sort, effectiveDir, 'created', 'p.id')}
         ${limitOffset(where, req.query)}`,
      where.params,
    );
    res.json(pageOf(rows, req.query, (r) => ({ ...r, amount: Number(r.amount), earnings_balance: Number(r.earnings_balance) })));
  }),
);

router.post(
  '/payouts/:id',
  validate(idParam, 'params'),
  validate(
    z
      .object({ approve: z.boolean(), note: z.string().trim().max(500).optional() })
      .refine((b) => b.approve || (b.note && b.note.length >= 3), { message: 'A rejection reason is required', path: ['note'] }),
  ),
  asyncHandler(async (req, res) => {
    const payout = await withTransaction(async (client) => {
      const { rows } = await client.query(
        `UPDATE payouts SET status = $2, note = $3, reviewed_by = $5, reviewed_at = now()
          WHERE id = $1 AND status = $4
          RETURNING *`,
        [
          req.params.id,
          req.body.approve ? PAYOUT_STATUS.APPROVED : PAYOUT_STATUS.REJECTED,
          req.body.note ?? null,
          PAYOUT_STATUS.REQUESTED,
          req.user.id,
        ],
      );
      if (rows.length === 0) throw badRequest('not_pending', 'This payout is not awaiting approval');
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

    // The worker debits earnings and marks it paid; approving only authorises.
    // No money is transferred by any code path — see the payout worker.
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

/**
 * Records the reference of a transfer an operator made OUTSIDE Moco (no
 * payout provider is integrated). It documents a real-world payment; it does
 * not make one. Only for payouts the worker has already marked paid.
 */
router.post(
  '/payouts/:id/reference',
  validate(idParam, 'params'),
  validate(z.object({ upiRef: z.string().trim().min(4).max(120), note: z.string().trim().max(500).optional() })),
  asyncHandler(async (req, res) => {
    const result = await withTransaction(async (client) => {
      const { rows } = await client.query(
        `UPDATE payouts SET upi_ref = $2 WHERE id = $1 AND status = $3 RETURNING id, listener_id, amount`,
        [req.params.id, req.body.upiRef, PAYOUT_STATUS.PAID],
      );
      if (!rows[0]) throw badRequest('not_paid', 'A reference can only be recorded on a paid payout');
      await audit.record(client, {
        admin: req.user,
        action: 'payout.reference',
        targetType: 'payout',
        targetId: rows[0].id,
        reason: req.body.note,
        metadata: { upiRef: req.body.upiRef, amount: Number(rows[0].amount) },
      });
      return rows[0];
    });
    res.json({ payoutId: result.id, upiRef: req.body.upiRef });
  }),
);

// -------------------------------------------------------------------- system

const MIGRATIONS_DIR = path.join(__dirname, '..', '..', 'db', 'migrations');

async function timed(fn) {
  const started = Date.now();
  try {
    const detail = await fn();
    return { ok: true, latencyMs: Date.now() - started, ...detail };
  } catch (err) {
    return { ok: false, latencyMs: Date.now() - started, error: err.message };
  }
}

/**
 * Live dependency health. Reports state only — never connection strings,
 * hosts, keys or credentials.
 */
router.get(
  '/system/health',
  asyncHandler(async (req, res) => {
    const [database, cache, objectStorage, tickWorker, queues] = await Promise.all([
      timed(async () => {
        await query('SELECT 1');
        const files = fs.readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith('.sql') && !f.endsWith('.down.sql')).sort();
        const { rows } = await query('SELECT name FROM schema_migrations');
        const applied = new Set(rows.map((r) => r.name));
        return {
          migrations: { files: files.length, applied: applied.size, pending: files.filter((f) => !applied.has(f)) },
          pool: { total: pool.totalCount, idle: pool.idleCount, waiting: pool.waitingCount },
        };
      }),
      timed(async () => ({ pong: await redis.ping() })),
      storage.health(),
      timed(async () => {
        const last = await redis.get(REDIS.workerHeartbeatKey('tick'));
        if (!last) throw new Error('no heartbeat — the tick worker is not running (calls are not being billed)');
        return { lastBeat: new Date(Number(last)).toISOString(), ageSeconds: Math.round((Date.now() - Number(last)) / 1000) };
      }),
      timed(async () => {
        const counts = async (q) => q.getJobCounts('waiting', 'active', 'delayed', 'failed');
        return { tick: await counts(tickQueue), payout: await counts(payoutQueue), notification: await counts(notificationQueue) };
      }),
    ]);

    res.json({
      api: { ok: true, uptimeSeconds: Math.round(process.uptime()), node: process.version, env: process.env.NODE_ENV || 'development' },
      database,
      redis: cache,
      storage: objectStorage,
      tickWorker,
      queues,
      checkedAt: new Date().toISOString(),
    });
  }),
);

/** Listener earnings ↔ earnings ledger, the counterpart of the coin check. */
router.get(
  '/reconcile/earnings',
  asyncHandler(async (req, res) => {
    const { rows } = await query(`
      SELECT lp.user_id, lp.earnings_balance, COALESCE(SUM(le.delta), 0)::bigint AS ledger_total
        FROM listener_profiles lp
        LEFT JOIN listener_earnings le ON le.listener_id = lp.user_id
       GROUP BY lp.user_id, lp.earnings_balance
      HAVING lp.earnings_balance <> COALESCE(SUM(le.delta), 0)
       LIMIT 100`);
    res.json({ balanced: rows.length === 0, discrepancies: rows });
  }),
);

module.exports = router;
