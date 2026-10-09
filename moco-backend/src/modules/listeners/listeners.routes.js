'use strict';

const express = require('express');
const { z } = require('zod');
const { query, withTransaction } = require('../../config/db');
const presence = require('../../realtime/presence');
const listenerStorage = require('../../integrations/listener.storage');
const { validate } = require('../../middleware/validate');
const { asyncHandler } = require('../../middleware/error');
const { authenticate, requireListener } = require('../../middleware/auth');
const { rateLimit } = require('../../middleware/rateLimit');
const notifications = require('../notifications/notifications.service');
const { notFound, badRequest, forbidden } = require('../../utils/errors');
const {
  KYC_STATUS,
  LISTENER_PHOTOS,
  listenerEligibleSql,
} = require('../../utils/constants');

const ELIGIBLE = listenerEligibleSql('lp');

const router = express.Router();

const discoverySchema = z.object({
  language: z.enum(['en', 'hi', 'te']).optional(),
  gender: z.enum(['male', 'female', 'other']).optional(),
  online: z.coerce.boolean().optional(),
  // Free-text search over display name and bio.
  q: z.string().trim().min(1).max(60).optional(),
  // Capability filter: only listeners who actually take this kind of call.
  callType: z.enum(['audio', 'video']).optional(),
  limit: z.coerce.number().int().min(1).max(50).default(20),
  offset: z.coerce.number().int().min(0).default(0),
});

/**
 * Discovery grid.
 *
 * Only eligible listeners — KYC approved AND at least the minimum number of
 * photos — are ever returned; anyone else is not discoverable no matter what
 * else they set. Blocked users are filtered out in the same query so neither
 * side sees the other.
 */
router.get(
  '/',
  authenticate,
  validate(discoverySchema, 'query'),
  asyncHandler(async (req, res) => {
    const { language, gender, online, q, callType, limit, offset } = req.query;

    const { rows } = await query(
      `SELECT u.id, u.display_name, u.avatar_url, u.gender, u.language,
              lp.bio, lp.languages, lp.audio_rate, lp.video_rate,
              lp.is_online, lp.is_busy, lp.rating, lp.total_calls,
              lp.accepts_audio, lp.accepts_video,
              -- Discovery only ever returns approved listeners, but the client
              -- must not have to infer that: publish it as a plain boolean and
              -- never expose the underlying KYC state.
              (lp.kyc_status = $1) AS verified
         FROM listener_profiles lp
         JOIN users u ON u.id = lp.user_id
        WHERE ${ELIGIBLE}
          AND u.status = 'active'
          AND u.id <> $2
          AND ($3::text IS NULL OR $3 = ANY(lp.languages))
          AND ($4::text IS NULL OR u.gender = $4)
          AND ($5::boolean IS NULL OR lp.is_online = $5)
          -- Capability filter. NULL means "either kind", which is what the
          -- client sends when no toggle is applied.
          AND ($6::text IS NULL
               OR ($6 = 'audio' AND lp.accepts_audio)
               OR ($6 = 'video' AND lp.accepts_video))
          -- Server-side search across the whole table, not one loaded page.
          -- Unanchored ILIKE cannot use a btree index; discovery is already
          -- narrowed to approved listeners, so this is acceptable at current
          -- scale. Add a pg_trgm GIN index on (display_name, bio) before the
          -- listener table grows large.
          AND ($7::text IS NULL
               OR u.display_name ILIKE '%' || $7 || '%'
               OR lp.bio ILIKE '%' || $7 || '%')
          AND NOT EXISTS (
                SELECT 1 FROM blocks b
                 WHERE (b.blocker_id = $2 AND b.blocked_id = u.id)
                    OR (b.blocker_id = u.id AND b.blocked_id = $2))
        ORDER BY lp.is_online DESC, lp.is_busy ASC, lp.rating DESC, lp.total_calls DESC
        LIMIT $8 OFFSET $9`,
      [
        KYC_STATUS.APPROVED,
        req.user.id,
        language ?? null,
        gender ?? null,
        online ?? null,
        callType ?? null,
        q ?? null,
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
        acceptsAudio: row.accepts_audio,
        acceptsVideo: row.accepts_video,
        verified: row.verified,
        isOnline: row.is_online && connected.has(row.id),
        isBusy: row.is_busy,
        rating: Number(row.rating),
        totalCalls: row.total_calls,
      })),
      nextOffset: rows.length === limit ? offset + limit : null,
    });
  }),
);

/**
 * Listener profile photos (own). Defined before `/:id` so `me` is never read
 * as a listener id.
 *
 * Upload flow mirrors feed media: request an upload URL (MIME validated here,
 * path minted here) → PUT bytes straight to Supabase Storage → register the
 * path. Registration re-checks everything rather than trusting the client:
 * ownership of the path, the type implied by the minted extension, that the
 * object actually exists, its real size, and the per-listener maximum.
 */
async function serializePhotos(listenerId) {
  const { rows } = await query(
    `SELECT id, storage_path, created_at FROM listener_photos
      WHERE listener_id = $1 ORDER BY created_at, id`,
    [listenerId],
  );
  const photos = await Promise.all(
    rows.map(async (row) => ({
      id: row.id,
      url: await listenerStorage.createViewUrl(row.storage_path),
      createdAt: row.created_at,
    })),
  );
  return {
    photos,
    count: photos.length,
    minCount: LISTENER_PHOTOS.minCount,
    maxCount: LISTENER_PHOTOS.maxCount,
  };
}

router.get(
  '/me/photos',
  authenticate,
  requireListener,
  asyncHandler(async (req, res) => {
    res.json(await serializePhotos(req.user.id));
  }),
);

router.post(
  '/me/photos/upload-url',
  authenticate,
  requireListener,
  rateLimit({ windowSeconds: 3600, max: 30, keyPrefix: 'listener_photo_upload' }),
  validate(z.object({ mimeType: z.enum(LISTENER_PHOTOS.allowedMimeTypes) })),
  asyncHandler(async (req, res) => {
    const { rows } = await query(
      'SELECT photo_count FROM listener_profiles WHERE user_id = $1',
      [req.user.id],
    );
    if (!rows[0]) throw notFound('Listener profile');
    if (rows[0].photo_count >= LISTENER_PHOTOS.maxCount) {
      throw badRequest('photo_limit', `You can have at most ${LISTENER_PHOTOS.maxCount} photos`);
    }
    if (!listenerStorage.isConfigured()) {
      throw badRequest('storage_not_configured', 'Photo uploads are not available right now');
    }

    const { path, uploadUrl, token } = await listenerStorage.createUploadUrl({
      userId: req.user.id,
      mimeType: req.body.mimeType,
    });
    res.json({ path, uploadUrl, token, maxBytes: LISTENER_PHOTOS.maxBytes });
  }),
);

router.post(
  '/me/photos',
  authenticate,
  requireListener,
  rateLimit({ windowSeconds: 3600, max: 30, keyPrefix: 'listener_photo_create' }),
  validate(z.object({ path: z.string().min(1).max(400) })),
  asyncHandler(async (req, res) => {
    const { path } = req.body;

    // Authorization before anything else — and before the storage check, so
    // configuration state can never widen access.
    if (!listenerStorage.pathBelongsToUser(path, req.user.id)) {
      throw forbidden('This photo does not belong to you');
    }
    const mimeType = listenerStorage.mimeTypeForPath(path);
    if (!mimeType) throw badRequest('unsupported_media', 'Only JPEG, PNG or WebP photos are allowed');
    if (!listenerStorage.isConfigured()) {
      throw badRequest('storage_not_configured', 'Photo uploads are not available right now');
    }

    const object = await listenerStorage.statObject(path);
    if (!object) {
      throw badRequest('media_not_uploaded', 'The upload did not finish. Please try again.');
    }
    if (object.sizeBytes !== null && object.sizeBytes > LISTENER_PHOTOS.maxBytes) {
      await listenerStorage.remove(path);
      throw badRequest('media_too_large', 'That photo is too large');
    }

    await withTransaction(async (client) => {
      // Lock the profile row so two concurrent registrations cannot both pass
      // the max-count check.
      const { rows } = await client.query(
        'SELECT photo_count FROM listener_profiles WHERE user_id = $1 FOR UPDATE',
        [req.user.id],
      );
      if (!rows[0]) throw notFound('Listener profile');
      if (rows[0].photo_count >= LISTENER_PHOTOS.maxCount) {
        throw badRequest('photo_limit', `You can have at most ${LISTENER_PHOTOS.maxCount} photos`);
      }
      // UNIQUE(storage_path): a double-tapped save is a no-op, not a duplicate.
      await client.query(
        `INSERT INTO listener_photos (listener_id, storage_path, mime_type, size_bytes)
         VALUES ($1, $2, $3, $4) ON CONFLICT (storage_path) DO NOTHING`,
        [req.user.id, path, mimeType, object.sizeBytes],
      );
    });

    res.status(201).json(await serializePhotos(req.user.id));
  }),
);

router.delete(
  '/me/photos/:photoId',
  authenticate,
  requireListener,
  validate(z.object({ photoId: z.coerce.number().int().positive() }), 'params'),
  asyncHandler(async (req, res) => {
    const removedPath = await withTransaction(async (client) => {
      const { rows: profile } = await client.query(
        'SELECT kyc_status, photo_count FROM listener_profiles WHERE user_id = $1 FOR UPDATE',
        [req.user.id],
      );
      if (!profile[0]) throw notFound('Listener profile');

      const { rows: photo } = await client.query(
        'SELECT storage_path FROM listener_photos WHERE id = $1 AND listener_id = $2',
        [req.params.photoId, req.user.id],
      );
      if (!photo[0]) throw notFound('Photo');

      // An approved listener must stay complete: removing a photo that would
      // drop them below the minimum would silently delist them, so require
      // adding a replacement first.
      if (
        profile[0].kyc_status === KYC_STATUS.APPROVED &&
        profile[0].photo_count <= LISTENER_PHOTOS.minCount
      ) {
        throw badRequest(
          'photos_minimum',
          `Verified listeners need at least ${LISTENER_PHOTOS.minCount} photos. Add another before removing this one.`,
        );
      }

      await client.query('DELETE FROM listener_photos WHERE id = $1', [req.params.photoId]);
      return photo[0].storage_path;
    });

    await listenerStorage.remove(removedPath);
    res.json(await serializePhotos(req.user.id));
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
              lp.is_online, lp.is_busy, lp.rating, lp.rating_count, lp.total_calls,
              lp.accepts_audio, lp.accepts_video,
              (lp.kyc_status = $2) AS verified,
              -- The viewer's own relation state, so the profile can render its
              -- buttons in one round trip instead of two.
              EXISTS (SELECT 1 FROM listener_relations r
                       WHERE r.user_id = $3 AND r.listener_id = lp.user_id
                         AND r.kind = 'favorite') AS is_favorited,
              EXISTS (SELECT 1 FROM listener_relations r
                       WHERE r.user_id = $3 AND r.listener_id = lp.user_id
                         AND r.kind = 'follow') AS is_following,
              (SELECT count(*)::int FROM listener_relations r
                WHERE r.listener_id = lp.user_id AND r.kind = 'follow') AS follower_count
         FROM listener_profiles lp
         JOIN users u ON u.id = lp.user_id
        WHERE lp.user_id = $1 AND ${ELIGIBLE} AND u.status = 'active'`,
      [req.params.id, KYC_STATUS.APPROVED, req.user.id],
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
      acceptsAudio: row.accepts_audio,
      acceptsVideo: row.accepts_video,
      verified: row.verified,
      isOnline: row.is_online && (await presence.isConnected(row.id)),
      isBusy: row.is_busy,
      rating: Number(row.rating),
      ratingCount: row.rating_count,
      totalCalls: row.total_calls,
      isFavorited: row.is_favorited,
      isFollowing: row.is_following,
      followerCount: row.follower_count,
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
      'SELECT kyc_status, photo_count, is_busy FROM listener_profiles WHERE user_id = $1',
      [req.user.id],
    );

    const profile = rows[0];
    if (!profile) throw notFound('Listener profile');

    // Going offline is always allowed; going online requires full eligibility.
    // KYC is reported first because verification itself already requires the
    // photos — an unverified listener's next step is verification.
    if (req.body.isOnline) {
      if (profile.kyc_status !== KYC_STATUS.APPROVED) {
        throw badRequest('kyc_required', 'Complete verification before going online');
      }
      if (profile.photo_count < LISTENER_PHOTOS.minCount) {
        throw badRequest(
          'photos_required',
          `Add at least ${LISTENER_PHOTOS.minCount} profile photos before going online`,
        );
      }
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

/**
 * KYC submission — submitting the listener application for review. Approval
 * is a manual admin action. An application is not complete without the
 * minimum photos, so it cannot be submitted before they are uploaded.
 */
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
    const { rows: current } = await query(
      'SELECT photo_count FROM listener_profiles WHERE user_id = $1',
      [req.user.id],
    );
    if (!current[0]) throw notFound('Listener profile');
    if (current[0].photo_count < LISTENER_PHOTOS.minCount) {
      throw badRequest(
        'photos_required',
        `Add at least ${LISTENER_PHOTOS.minCount} profile photos before submitting for verification`,
      );
    }

    const { rows } = await query(
      `UPDATE listener_profiles
          SET kyc_name = $2, kyc_doc_url = $3, upi_id = $4,
              kyc_status = $5, kyc_submitted_at = now(), updated_at = now()
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

/**
 * Favourite / follow.
 *
 * Both are idempotent by construction: the primary key on
 * (user_id, listener_id, kind) plus ON CONFLICT DO NOTHING means repeating a
 * PUT is a no-op rather than a duplicate row or an error, and repeating a
 * DELETE is equally harmless. That matters because the client applies these
 * optimistically and may retry after a dropped connection.
 *
 * The response always reports the resulting state, so a client that lost track
 * can reconcile from one call.
 */
const relationParams = z.object({
  id: z.coerce.number().int().positive(),
  kind: z.enum(['favorite', 'follow']),
});

router.put(
  '/:id/:kind',
  authenticate,
  rateLimit({ windowSeconds: 60, max: 60, keyPrefix: 'listener_relation' }),
  validate(relationParams, 'params'),
  asyncHandler(async (req, res) => {
    const { id, kind } = req.params;

    if (Number(id) === Number(req.user.id)) {
      throw badRequest('self_relation', 'You cannot do that to your own profile');
    }

    // Only eligible listeners can be followed or favourited — otherwise a user
    // could accumulate relations to accounts they can never actually see.
    const { rows: exists } = await query(
      `SELECT 1 FROM listener_profiles lp JOIN users u ON u.id = lp.user_id
        WHERE lp.user_id = $1 AND ${ELIGIBLE} AND u.status = 'active'`,
      [id],
    );
    if (!exists[0]) throw notFound('Listener');

    const { rowCount: added } = await query(
      `INSERT INTO listener_relations (user_id, listener_id, kind)
       VALUES ($1, $2, $3) ON CONFLICT DO NOTHING`,
      [req.user.id, id, kind],
    );
    if (added === 1 && kind === 'follow') await notifyFollow(id, req.user);

    const { rows } = await query(
      `SELECT count(*)::int AS followers FROM listener_relations
        WHERE listener_id = $1 AND kind = 'follow'`,
      [id],
    );

    res.json({ listenerId: Number(id), kind, active: true, followerCount: rows[0].followers });
  }),
);

/**
 * Tells a listener they have a new follower. Only on a fresh follow row, and
 * at most once per follower per day, so follow/unfollow toggling cannot spam
 * the listener's inbox.
 */
async function notifyFollow(listenerId, follower) {
  const { rows } = await query(
    `SELECT 1 FROM notifications
      WHERE user_id = $1 AND type = 'new_follower' AND data->>'actorId' = $2
        AND created_at > now() - interval '24 hours'
      LIMIT 1`,
    [listenerId, String(follower.id)],
  );
  if (rows[0]) return;
  await notifications.create({
    userId: Number(listenerId),
    type: 'new_follower',
    title: `${follower.display_name || 'Someone'} started following you`,
    data: { actorId: Number(follower.id) },
  });
}

router.delete(
  '/:id/:kind',
  authenticate,
  rateLimit({ windowSeconds: 60, max: 60, keyPrefix: 'listener_relation' }),
  validate(relationParams, 'params'),
  asyncHandler(async (req, res) => {
    const { id, kind } = req.params;

    await query(
      `DELETE FROM listener_relations
        WHERE user_id = $1 AND listener_id = $2 AND kind = $3`,
      [req.user.id, id, kind],
    );

    const { rows } = await query(
      `SELECT count(*)::int AS followers FROM listener_relations
        WHERE listener_id = $1 AND kind = 'follow'`,
      [id],
    );

    res.json({ listenerId: Number(id), kind, active: false, followerCount: rows[0].followers });
  }),
);

module.exports = router;
