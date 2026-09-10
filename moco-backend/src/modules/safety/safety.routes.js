'use strict';

const express = require('express');
const { z } = require('zod');
const { query, withTransaction } = require('../../config/db');
const { validate } = require('../../middleware/validate');
const { asyncHandler } = require('../../middleware/error');
const { authenticate } = require('../../middleware/auth');
const { rateLimit } = require('../../middleware/rateLimit');
const { badRequest, notFound } = require('../../utils/errors');
const logger = require('../../utils/logger');

const router = express.Router();
router.use(authenticate);

/**
 * Report and block. Google Play requires both to be reachable in-app for any
 * app carrying user-to-user communication, which is why these ship in the
 * first release rather than being deferred.
 */

const REPORT_REASONS = [
  'harassment',
  'nudity',
  'abusive_language',
  'spam',
  'underage',
  'impersonation',
  'other',
];

router.post(
  '/report',
  rateLimit({ windowSeconds: 3600, max: 20, keyPrefix: 'report' }),
  validate(
    z.object({
      userId: z.coerce.number().int().positive(),
      reason: z.enum(REPORT_REASONS),
      details: z.string().max(1000).optional(),
      callId: z.coerce.number().int().positive().optional(),
    }),
  ),
  asyncHandler(async (req, res) => {
    const { userId, reason, details, callId } = req.body;

    if (Number(userId) === Number(req.user.id)) {
      throw badRequest('self_report', 'You cannot report yourself');
    }

    const { rows: exists } = await query('SELECT 1 FROM users WHERE id = $1', [userId]);
    if (!exists[0]) throw notFound('User');

    const { rows } = await query(
      `INSERT INTO reports (reporter_id, reported_id, call_id, reason, details)
       VALUES ($1, $2, $3, $4, $5) RETURNING id, status, created_at`,
      [req.user.id, userId, callId ?? null, reason, details ?? null],
    );

    logger.warn({ reporterId: req.user.id, reportedId: userId, reason }, 'user reported');
    res.status(201).json({ reportId: rows[0].id, status: rows[0].status });
  }),
);

/**
 * Blocking is mutual in effect: the block row is one-directional, but every
 * discovery, call and chat query checks it in both directions, so neither
 * party can reach the other afterwards.
 */
router.post(
  '/block',
  validate(z.object({ userId: z.coerce.number().int().positive() })),
  asyncHandler(async (req, res) => {
    if (Number(req.body.userId) === Number(req.user.id)) {
      throw badRequest('self_block', 'You cannot block yourself');
    }

    await withTransaction(async (client) => {
      await client.query(
        `INSERT INTO blocks (blocker_id, blocked_id) VALUES ($1, $2)
         ON CONFLICT DO NOTHING`,
        [req.user.id, req.body.userId],
      );

      // End any live call between the two immediately — a block that leaves
      // the current call running is not much of a block.
      await client.query(
        `UPDATE calls SET status = 'ended', ended_at = now(), end_reason = 'admin'
          WHERE status IN ('ringing', 'active')
            AND ((caller_id = $1 AND listener_id = $2) OR (caller_id = $2 AND listener_id = $1))`,
        [req.user.id, req.body.userId],
      );
    });

    res.json({ ok: true, blocked: req.body.userId });
  }),
);

router.delete(
  '/block/:userId',
  validate(z.object({ userId: z.coerce.number().int().positive() }), 'params'),
  asyncHandler(async (req, res) => {
    await query('DELETE FROM blocks WHERE blocker_id = $1 AND blocked_id = $2', [
      req.user.id,
      req.params.userId,
    ]);
    res.json({ ok: true });
  }),
);

router.get(
  '/blocks',
  asyncHandler(async (req, res) => {
    const { rows } = await query(
      `SELECT u.id, u.display_name, u.avatar_url, b.created_at
         FROM blocks b JOIN users u ON u.id = b.blocked_id
        WHERE b.blocker_id = $1 ORDER BY b.created_at DESC`,
      [req.user.id],
    );
    res.json({ blocked: rows });
  }),
);

/** Post-call rating, which feeds the listener's discovery ranking. */
router.post(
  '/calls/:callId/rate',
  validate(z.object({ callId: z.coerce.number().int().positive() }), 'params'),
  validate(
    z.object({ rating: z.coerce.number().int().min(1).max(5), comment: z.string().max(500).optional() }),
  ),
  asyncHandler(async (req, res) => {
    const { rows: callRows } = await query(
      `SELECT caller_id, listener_id, status FROM calls WHERE id = $1`,
      [req.params.callId],
    );

    const call = callRows[0];
    if (!call) throw notFound('Call');
    if (Number(call.caller_id) !== Number(req.user.id)) {
      throw badRequest('not_rateable', 'Only the caller can rate this call');
    }

    await withTransaction(async (client) => {
      const { rowCount } = await client.query(
        `INSERT INTO call_ratings (call_id, rater_id, rating, comment)
         VALUES ($1, $2, $3, $4)
         ON CONFLICT (call_id) DO NOTHING`,
        [req.params.callId, req.user.id, req.body.rating, req.body.comment ?? null],
      );

      // Only move the average if this is a first rating for the call, so
      // re-submitting cannot inflate or tank a listener's score.
      if (rowCount > 0) {
        await client.query(
          `UPDATE listener_profiles
              SET rating = ((rating * rating_count) + $2) / (rating_count + 1),
                  rating_count = rating_count + 1,
                  updated_at = now()
            WHERE user_id = $1`,
          [call.listener_id, req.body.rating],
        );
      }
    });

    res.json({ ok: true });
  }),
);

module.exports = router;
