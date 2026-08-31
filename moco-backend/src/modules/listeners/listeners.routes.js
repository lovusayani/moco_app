'use strict';

const express = require('express');
const { z } = require('zod');
const { query } = require('../../config/db');
const presence = require('../../realtime/presence');
const { validate } = require('../../middleware/validate');
const { asyncHandler } = require('../../middleware/error');
const { authenticate, requireListener } = require('../../middleware/auth');
const { notFound, badRequest } = require('../../utils/errors');
const { KYC_STATUS } = require('../../utils/constants');

const router = express.Router();

const discoverySchema = z.object({
  language: z.enum(['en', 'hi', 'te']).optional(),
  gender: z.enum(['male', 'female', 'other']).optional(),
  online: z.coerce.boolean().optional(),
  limit: z.coerce.number().int().min(1).max(50).default(20),
  offset: z.coerce.number().int().min(0).default(0),
});

/**
 * Discovery grid.
 *
 * Only KYC-approved listeners are ever returned — an unverified listener is
 * not discoverable no matter what else they set. Blocked users are filtered
 * out in the same query so neither side sees the other.
 */
router.get(
  '/',
  authenticate,
  validate(discoverySchema, 'query'),
  asyncHandler(async (req, res) => {
    const { language, gender, online, limit, offset } = req.query;

    const { rows } = await query(
      `SELECT u.id, u.display_name, u.avatar_url, u.gender, u.language,
              lp.bio, lp.languages, lp.audio_rate, lp.video_rate,
              lp.is_online, lp.is_busy, lp.rating, lp.total_calls
         FROM listener_profiles lp
         JOIN users u ON u.id = lp.user_id
        WHERE lp.kyc_status = $1
          AND u.status = 'active'
          AND u.id <> $2
          AND ($3::text IS NULL OR $3 = ANY(lp.languages))
          AND ($4::text IS NULL OR u.gender = $4)
          AND ($5::boolean IS NULL OR lp.is_online = $5)
          AND NOT EXISTS (
                SELECT 1 FROM blocks b
                 WHERE (b.blocker_id = $2 AND b.blocked_id = u.id)
                    OR (b.blocker_id = u.id AND b.blocked_id = $2))
        ORDER BY lp.is_online DESC, lp.is_busy ASC, lp.rating DESC, lp.total_calls DESC
        LIMIT $6 OFFSET $7`,
      [
        KYC_STATUS.APPROVED,
        req.user.id,
        language ?? null,
        gender ?? null,
        online ?? null,
        limit,
        offset,
      ],
    );

    // A listener is only truly callable if a socket is actually connected;
    // is_online alone can be stale if their app was killed.
    const connected = new Set(
      await presence.filterConnected(rows.filter((r) => r.is_online).map((r) => r.id)),
    );

    res.json({
      listeners: rows.map((row) => ({
        id: row.id,
        name: row.display_name,
        avatarUrl: row.avatar_url,
        bio: row.bio,
        languages: row.languages,
        gender: row.gender,
        audioRate: row.audio_rate,
        videoRate: row.video_rate,
        isOnline: row.is_online && connected.has(row.id),
        isBusy: row.is_busy,
        rating: Number(row.rating),
        totalCalls: row.total_calls,
      })),
      nextOffset: rows.length === limit ? offset + limit : null,
    });
  }),
);

router.get(
  '/:id',
  authenticate,
  validate(z.object({ id: z.coerce.number().int().positive() }), 'params'),
  asyncHandler(async (req, res) => {
    const { rows } = await query(
      `SELECT u.id, u.display_name, u.avatar_url, u.gender,
              lp.bio, lp.languages, lp.audio_rate, lp.video_rate,
              lp.is_online, lp.is_busy, lp.rating, lp.rating_count, lp.total_calls
         FROM listener_profiles lp
         JOIN users u ON u.id = lp.user_id
        WHERE lp.user_id = $1 AND lp.kyc_status = $2 AND u.status = 'active'`,
      [req.params.id, KYC_STATUS.APPROVED],
    );

    const row = rows[0];
    if (!row) throw notFound('Listener');

    res.json({
      id: row.id,
      name: row.display_name,
      avatarUrl: row.avatar_url,
      bio: row.bio,
      languages: row.languages,
      gender: row.gender,
      audioRate: row.audio_rate,
      videoRate: row.video_rate,
      isOnline: row.is_online && (await presence.isConnected(row.id)),
      isBusy: row.is_busy,
      rating: Number(row.rating),
      ratingCount: row.rating_count,
      totalCalls: row.total_calls,
    });
  }),
);

/** The listener's own online/offline toggle. */
router.patch(
  '/status',
  authenticate,
  requireListener,
  validate(z.object({ isOnline: z.boolean() })),
  asyncHandler(async (req, res) => {
    const { rows } = await query(
      'SELECT kyc_status, is_busy FROM listener_profiles WHERE user_id = $1',
      [req.user.id],
    );

    const profile = rows[0];
    if (!profile) throw notFound('Listener profile');

    if (req.body.isOnline && profile.kyc_status !== KYC_STATUS.APPROVED) {
      throw badRequest('kyc_required', 'Complete verification before going online');
    }

    await presence.setOnline(req.user.id, req.body.isOnline);
    res.json({ isOnline: req.body.isOnline, isBusy: profile.is_busy });
  }),
);

/** Listener-editable profile fields. Rates stay admin-controlled for now. */
router.patch(
  '/me',
  authenticate,
  requireListener,
  validate(
    z.object({
      bio: z.string().max(300).optional(),
      languages: z.array(z.enum(['en', 'hi', 'te'])).min(1).max(3).optional(),
    }),
  ),
  asyncHandler(async (req, res) => {
    const { rows } = await query(
      `UPDATE listener_profiles
          SET bio = COALESCE($2, bio),
              languages = COALESCE($3, languages),
              updated_at = now()
        WHERE user_id = $1
        RETURNING bio, languages, audio_rate, video_rate`,
      [req.user.id, req.body.bio ?? null, req.body.languages ?? null],
    );
    res.json({ profile: rows[0] });
  }),
);

/** KYC submission. Approval is a manual admin action. */
router.post(
  '/kyc',
  authenticate,
  requireListener,
  validate(
    z.object({
      fullName: z.string().min(2).max(120),
      docUrl: z.string().url().max(500),
      upiId: z.string().min(3).max(120),
    }),
  ),
  asyncHandler(async (req, res) => {
    const { rows } = await query(
      `UPDATE listener_profiles
          SET kyc_name = $2, kyc_doc_url = $3, upi_id = $4,
              kyc_status = $5, updated_at = now()
        WHERE user_id = $1 AND kyc_status <> $6
        RETURNING kyc_status`,
      [
        req.user.id,
        req.body.fullName,
        req.body.docUrl,
        req.body.upiId,
        KYC_STATUS.PENDING,
        KYC_STATUS.APPROVED,
      ],
    );

    if (rows.length === 0) {
      // Already approved — resubmitting must not knock them back to pending.
      return res.json({ kycStatus: KYC_STATUS.APPROVED, unchanged: true });
    }

    return res.json({ kycStatus: rows[0].kyc_status });
  }),
);

module.exports = router;
