'use strict';

const express = require('express');
const { z } = require('zod');
const { query, withTransaction } = require('../../config/db');
const { validate } = require('../../middleware/validate');
const { asyncHandler } = require('../../middleware/error');
const { isAdminUser } = require('../../middleware/auth');
const { notFound, badRequest } = require('../../utils/errors');
const { USER_STATUS } = require('../../utils/constants');
const audit = require('./audit.service');
const { listSchema, Where, orderBy, limitOffset, pageOf, likeTerm } = require('./admin.list');

/**
 * Admin: reports and the audit log. Mounted under /api/admin behind
 * authenticate + requireAdmin.
 *
 * Reports are filed against a user; when filed from a call they also carry
 * that call, so "target type" is `call` (a user, in a specific call) or
 * `user`. The moderation history of a report is its audit trail.
 */
const router = express.Router();
const idParam = z.object({ id: z.coerce.number().int().positive() });

const REPORT_SORT = {
  created: 'r.created_at',
  status: 'r.status',
  reason: 'r.reason',
  againstCount: 'against.total',
};

router.get(
  '/reports',
  validate(
    listSchema(Object.keys(REPORT_SORT), {
      status: z.enum(['open', 'reviewing', 'actioned', 'dismissed', 'unresolved']).optional(),
      reason: z.string().trim().max(40).optional(),
      target: z.enum(['user', 'call']).optional(),
      reporter: z.coerce.number().int().positive().optional(),
      reported: z.coerce.number().int().positive().optional(),
    }),
    'query',
  ),
  asyncHandler(async (req, res) => {
    const { q, status, reason, target, reporter, reported, from, to, sort, dir } = req.query;
    const where = new Where()
      .maybe(reason, 'r.reason = ?')
      .maybe(reporter, 'r.reporter_id = ?')
      .maybe(reported, 'r.reported_id = ?')
      .dateRange('r.created_at', from, to);
    if (status === 'unresolved') where.add(`r.status IN ('open', 'reviewing')`);
    else if (status) where.add('r.status = ?', status);
    if (target === 'call') where.add('r.call_id IS NOT NULL');
    if (target === 'user') where.add('r.call_id IS NULL');
    if (q) {
      const term = likeTerm(q);
      where.add(
        `(reporter.display_name ILIKE ? OR reported.display_name ILIKE ? OR reporter.phone ILIKE ?
          OR reported.phone ILIKE ? OR r.details ILIKE ? OR r.id::text = ?)`,
        term, term, term, term, term, q,
      );
    }

    const { rows } = await query(
      `SELECT r.id, r.reason, r.details, r.status, r.created_at, r.resolved_at, r.call_id,
              r.reporter_id, reporter.display_name AS reporter_name, reporter.phone AS reporter_phone,
              r.reported_id, reported.display_name AS reported_name, reported.phone AS reported_phone,
              reported.status AS reported_status, against.total AS reports_against,
              count(*) OVER () AS total_count
         FROM reports r
         JOIN users reporter ON reporter.id = r.reporter_id
         JOIN users reported ON reported.id = r.reported_id
         JOIN LATERAL (SELECT count(*)::int AS total FROM reports r2
                        WHERE r2.reported_id = r.reported_id) against ON TRUE
         ${where.sql}
         ${orderBy(REPORT_SORT, sort, dir, 'created', 'r.id')}
         ${limitOffset(where, req.query)}`,
      where.params,
    );

    res.json(
      pageOf(rows, req.query, (r) => ({
        ...r,
        targetType: r.call_id ? 'call' : 'user',
      })),
    );
  }),
);

/** Distinct reasons actually present, for the console's filter dropdown. */
router.get(
  '/reports/meta',
  asyncHandler(async (req, res) => {
    const { rows } = await query('SELECT DISTINCT reason FROM reports ORDER BY reason');
    res.json({ reasons: rows.map((r) => r.reason) });
  }),
);

router.get(
  '/reports/:id',
  validate(idParam, 'params'),
  asyncHandler(async (req, res) => {
    const { rows } = await query(
      `SELECT r.*, reporter.display_name AS reporter_name, reporter.phone AS reporter_phone,
              reporter.status AS reporter_status,
              reported.display_name AS reported_name, reported.phone AS reported_phone,
              reported.status AS reported_status, reported.role AS reported_role,
              resolver.phone AS resolved_by_phone
         FROM reports r
         JOIN users reporter ON reporter.id = r.reporter_id
         JOIN users reported ON reported.id = r.reported_id
         LEFT JOIN users resolver ON resolver.id = r.resolved_by
        WHERE r.id = $1`,
      [req.params.id],
    );
    const report = rows[0];
    if (!report) throw notFound('Report');

    const [call, related, history] = await Promise.all([
      report.call_id
        ? query(
            `SELECT id, type, status, created_at, started_at, ended_at, end_reason,
                    billed_minutes, coins_spent, listener_earned, caller_id, listener_id
               FROM calls WHERE id = $1`,
            [report.call_id],
          )
        : Promise.resolve({ rows: [] }),
      query(
        `SELECT r.id, r.reason, r.status, r.created_at, reporter.display_name AS reporter_name
           FROM reports r JOIN users reporter ON reporter.id = r.reporter_id
          WHERE r.reported_id = $1 AND r.id <> $2
          ORDER BY r.created_at DESC LIMIT 10`,
        [report.reported_id, report.id],
      ),
      audit.historyFor('report', report.id),
    ]);

    res.json({
      ...report,
      targetType: report.call_id ? 'call' : 'user',
      call: call.rows[0] ?? null,
      otherReportsAgainst: related.rows,
      history,
    });
  }),
);

/**
 * Moderation actions:
 *   review   — mark as being looked at (status reviewing)
 *   resolve  — handled, no account action (status actioned)
 *   dismiss  — not a violation (status dismissed)
 *   suspend  — actioned AND the reported account is suspended
 * Every action is audited; suspend writes a second entry against the user so
 * the account's own history shows it too.
 */
router.post(
  '/reports/:id',
  validate(idParam, 'params'),
  validate(
    z
      .object({
        action: z.enum(['review', 'resolve', 'dismiss', 'suspend']),
        note: z.string().trim().max(1000).optional(),
      })
      .refine((b) => b.action === 'review' || (b.note && b.note.length >= 3), {
        message: 'A moderation note is required',
        path: ['note'],
      }),
  ),
  asyncHandler(async (req, res) => {
    const { action, note } = req.body;
    const nextStatus = { review: 'reviewing', resolve: 'actioned', dismiss: 'dismissed', suspend: 'actioned' }[action];

    const result = await withTransaction(async (client) => {
      const { rows: found } = await client.query(
        `SELECT r.id, r.status, r.reported_id, u.phone AS reported_phone, u.email AS reported_email, u.status AS reported_status
           FROM reports r JOIN users u ON u.id = r.reported_id
          WHERE r.id = $1 FOR UPDATE OF r`,
        [req.params.id],
      );
      const report = found[0];
      if (!report) throw notFound('Report');
      if (['actioned', 'dismissed'].includes(report.status) && action !== 'suspend') {
        throw badRequest('already_resolved', `This report is already ${report.status}`);
      }
      if (action === 'suspend') {
        if (isAdminUser({ phone: report.reported_phone, email: report.reported_email })) {
          throw badRequest('admin_account', 'Admin accounts cannot be suspended from the console');
        }
        if (report.reported_status === USER_STATUS.DELETED) {
          throw badRequest('account_deleted', 'The reported account has been deleted');
        }
      }

      const resolving = action !== 'review';
      await client.query(
        `UPDATE reports
            SET status = $2,
                resolved_at = CASE WHEN $3 THEN now() ELSE resolved_at END,
                resolved_by = CASE WHEN $3 THEN $4::bigint ELSE resolved_by END,
                resolution_note = CASE WHEN $3 THEN $5 ELSE resolution_note END
          WHERE id = $1`,
        [report.id, nextStatus, resolving, req.user.id, note ?? null],
      );

      await audit.record(client, {
        admin: req.user,
        action: `report.${action}`,
        targetType: 'report',
        targetId: report.id,
        reason: note,
        metadata: { from: report.status, to: nextStatus, reportedId: report.reported_id },
      });

      if (action === 'suspend' && report.reported_status !== USER_STATUS.SUSPENDED) {
        await client.query(`UPDATE users SET status = 'suspended', updated_at = now() WHERE id = $1`, [
          report.reported_id,
        ]);
        // A suspended listener must stop appearing in discovery at once.
        await client.query('UPDATE listener_profiles SET is_online = FALSE WHERE user_id = $1', [
          report.reported_id,
        ]);
        await audit.record(client, {
          admin: req.user,
          action: 'user.suspend',
          targetType: 'user',
          targetId: report.reported_id,
          reason: note,
          metadata: { viaReport: report.id },
        });
      }
      return { reportId: report.id, status: nextStatus };
    });

    res.json(result);
  }),
);

// ----------------------------------------------------------------- audit log

const AUDIT_SORT = { created: 'a.created_at', action: 'a.action', admin: 'a.admin_phone', target: 'a.target_type' };

router.get(
  '/audit',
  validate(
    listSchema(Object.keys(AUDIT_SORT), {
      action: z.string().trim().max(60).optional(),
      admin: z.string().trim().max(20).optional(),
      targetType: z.string().trim().max(30).optional(),
      targetId: z.string().trim().max(40).optional(),
    }),
    'query',
  ),
  asyncHandler(async (req, res) => {
    const { q, action, admin, targetType, targetId, from, to, sort, dir } = req.query;
    const where = new Where()
      .maybe(action, 'a.action = ?')
      .maybe(admin, 'a.admin_phone = ?')
      .maybe(targetType, 'a.target_type = ?')
      .maybe(targetId, 'a.target_id = ?')
      .dateRange('a.created_at', from, to);
    if (q) {
      const term = likeTerm(q);
      where.add('(a.action ILIKE ? OR a.reason ILIKE ? OR a.target_id = ? OR a.metadata::text ILIKE ?)', term, term, q, term);
    }

    const { rows } = await query(
      `SELECT a.id, a.admin_user_id, a.admin_phone, a.action, a.target_type, a.target_id,
              a.reason, a.metadata, a.created_at, count(*) OVER () AS total_count
         FROM admin_audit_log a
         ${where.sql}
         ${orderBy(AUDIT_SORT, sort, dir, 'created', 'a.id')}
         ${limitOffset(where, req.query)}`,
      where.params,
    );
    res.json(pageOf(rows, req.query));
  }),
);

/** Values actually present, for the console's filter dropdowns. */
router.get(
  '/audit/meta',
  asyncHandler(async (req, res) => {
    const [actions, admins, targets] = await Promise.all([
      query('SELECT DISTINCT action FROM admin_audit_log ORDER BY action'),
      query('SELECT DISTINCT admin_phone FROM admin_audit_log ORDER BY admin_phone'),
      query('SELECT DISTINCT target_type FROM admin_audit_log ORDER BY target_type'),
    ]);
    res.json({
      actions: actions.rows.map((r) => r.action),
      admins: admins.rows.map((r) => r.admin_phone),
      targetTypes: targets.rows.map((r) => r.target_type),
    });
  }),
);

module.exports = router;
