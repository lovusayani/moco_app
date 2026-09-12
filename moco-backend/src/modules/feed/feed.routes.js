'use strict';

const express = require('express');
const { z } = require('zod');
const { query } = require('../../config/db');
const feedStorage = require('../../integrations/feed.storage');
const { validate } = require('../../middleware/validate');
const { asyncHandler } = require('../../middleware/error');
const { authenticate } = require('../../middleware/auth');
const { rateLimit } = require('../../middleware/rateLimit');
const { forbidden, notFound, badRequest } = require('../../utils/errors');
const {
  FEED_MEDIA,
  FEED_MEDIA_MIME_TYPES,
  KYC_STATUS,
  POST_STATUS,
  postMediaTypeForMime,
  feedMaxBytesFor,
} = require('../../utils/constants');

const router = express.Router();
router.use(authenticate);

/**
 * The Feed.
 *
 * Newest-first and deterministic — there is deliberately no ranking or
 * recommendation here. Ordering is by post id descending, which for an
 * identity column is creation order, so keyset pagination on the same column
 * cannot skip or repeat a post the way an OFFSET page can when someone posts
 * mid-scroll. The client dedupes by id as well, but it should never have to.
 */

/**
 * Shapes one row for the client, minting a signed media URL per read.
 *
 * `author.isListener` exists so the client knows whether tapping the author
 * has a destination: the only profile screen that exists is the listener
 * profile, so a non-listener author's name is not a link. That is an honest
 * "no screen for this yet", not a silently broken tap.
 */
async function toPost(row) {
  return {
    id: row.id,
    mediaType: row.media_type,
    mediaUrl: await feedStorage.createViewUrl(row.media_path),
    caption: row.caption,
    createdAt: row.created_at,
    author: {
      id: row.author_user_id,
      name: row.display_name,
      avatarUrl: row.avatar_url,
      isListener: row.is_listener,
      verified: row.verified,
    },
  };
}

const feedQuerySchema = z.object({
  limit: z.coerce.number().int().min(1).max(30).default(10),
  /** Keyset cursor: the id of the last post the client already has. */
  cursor: z.coerce.number().int().positive().optional(),
});

router.get(
  '/',
  validate(feedQuerySchema, 'query'),
  asyncHandler(async (req, res) => {
    const { limit, cursor } = req.query;

    const { rows } = await query(
      `SELECT p.id, p.author_user_id, p.media_type, p.media_path, p.caption, p.created_at,
              u.display_name, u.avatar_url,
              (lp.user_id IS NOT NULL) AS is_listener,
              -- Same rule as discovery: publish the derived boolean, never the
              -- underlying KYC state.
              (lp.kyc_status = $4) AS verified
         FROM posts p
         JOIN users u ON u.id = p.author_user_id
         LEFT JOIN listener_profiles lp ON lp.user_id = p.author_user_id
        WHERE p.status = $1
          AND u.status = 'active'
          -- Keyset pagination. id DESC is creation order, so this is a stable
          -- "everything older than what I have" with no OFFSET drift.
          AND ($2::bigint IS NULL OR p.id < $2)
          -- The existing one-directional block row, checked in both
          -- directions — the same predicate discovery and chat already use.
          -- No second block system.
          AND NOT EXISTS (
                SELECT 1 FROM blocks b
                 WHERE (b.blocker_id = $3 AND b.blocked_id = p.author_user_id)
                    OR (b.blocker_id = p.author_user_id AND b.blocked_id = $3))
        ORDER BY p.id DESC
        LIMIT $5`,
      [POST_STATUS.ACTIVE, cursor ?? null, req.user.id, KYC_STATUS.APPROVED, limit],
    );

    const posts = await Promise.all(rows.map(toPost));

    return res.json({
      posts,
      // Null only when this page was short, which is the one reliable signal
      // that there is nothing older — a full page always gets a cursor even
      // if the next page turns out to be empty.
      nextCursor: rows.length === limit ? rows[rows.length - 1].id : null,
    });
  }),
);

/**
 * Authorizes a post media upload. The client PUTs the bytes straight to
 * Supabase Storage with the returned URL and then calls `POST /feed` with the
 * path — media never travels through this API.
 *
 * The MIME type is validated here, before a URL exists, and it is what
 * decides the stored extension. Everything downstream derives the media type
 * from that path rather than believing the client a second time.
 */
router.post(
  '/media/upload-url',
  rateLimit({ windowSeconds: 3600, max: 30, keyPrefix: 'feed_media_upload' }),
  validate(z.object({ mimeType: z.enum(FEED_MEDIA_MIME_TYPES) })),
  asyncHandler(async (req, res) => {
    if (!feedStorage.isConfigured()) {
      throw badRequest('storage_not_configured', 'Posting is not available right now');
    }

    const mediaType = postMediaTypeForMime(req.body.mimeType);
    const { path, uploadUrl, token } = await feedStorage.createUploadUrl({
      userId: req.user.id,
      mimeType: req.body.mimeType,
    });

    res.json({
      path,
      uploadUrl,
      token,
      mediaType,
      maxBytes: feedMaxBytesFor(mediaType),
      maxVideoSeconds: FEED_MEDIA.maxVideoSeconds,
    });
  }),
);

/**
 * Publishes a post for media the caller has already uploaded.
 *
 * Four things are checked, none of them taken on trust from the request:
 *  1. the path is one minted for THIS user (prefix check — the upload URL was
 *     already scoped to it, this rejects referencing someone else's upload);
 *  2. the media type comes from the path's extension, not the body;
 *  3. the object actually exists in the bucket, so a client cannot publish a
 *     post whose media was never uploaded and would render as a broken item;
 *  4. its real size is within the cap for its type — the signed upload URL
 *     cannot enforce that itself, so it is enforced here before any row
 *     references the object.
 */
router.post(
  '/',
  rateLimit({ windowSeconds: 3600, max: 20, keyPrefix: 'feed_create' }),
  validate(
    z.object({
      mediaPath: z.string().min(1).max(400),
      caption: z.string().trim().max(FEED_MEDIA.maxCaptionLength).optional(),
    }),
  ),
  asyncHandler(async (req, res) => {
    const { mediaPath } = req.body;

    // Authorization first, and deliberately before the storage-availability
    // check: a path that is not this user's is refused whether or not storage
    // happens to be configured. Config state must never widen access.
    if (!feedStorage.pathBelongsToUser(mediaPath, req.user.id)) {
      throw forbidden('This media does not belong to you');
    }

    const mediaType = feedStorage.mediaTypeForPath(mediaPath);
    if (!mediaType) {
      throw badRequest('unsupported_media', 'That file type cannot be posted');
    }

    if (!feedStorage.isConfigured()) {
      throw badRequest('storage_not_configured', 'Posting is not available right now');
    }

    const object = await feedStorage.statObject(mediaPath);
    if (!object) {
      throw badRequest('media_not_uploaded', 'The upload did not finish. Please try again.');
    }

    const maxBytes = feedMaxBytesFor(mediaType);
    if (object.sizeBytes !== null && object.sizeBytes > maxBytes) {
      // Remove it rather than leave a too-large object paid for but unusable.
      await feedStorage.remove(mediaPath);
      throw badRequest('media_too_large', 'That file is too large to post');
    }

    // A blank caption and no caption are the same thing (and the schema's
    // CHECK rejects ''), so normalise to null.
    const caption = req.body.caption && req.body.caption.length > 0 ? req.body.caption : null;

    const { rows } = await query(
      `INSERT INTO posts (author_user_id, media_type, media_path, caption)
       VALUES ($1, $2, $3, $4)
       -- UNIQUE(media_path): a double-tapped Publish re-registering the same
       -- upload is a no-op rather than a duplicate post.
       ON CONFLICT (media_path) DO NOTHING
       RETURNING id, author_user_id, media_type, media_path, caption, created_at`,
      [req.user.id, mediaType, mediaPath, caption],
    );

    if (!rows[0]) {
      throw badRequest('already_posted', 'That media has already been posted');
    }

    const { rows: author } = await query(
      `SELECT u.display_name, u.avatar_url,
              (lp.user_id IS NOT NULL) AS is_listener,
              (lp.kyc_status = $2) AS verified
         FROM users u LEFT JOIN listener_profiles lp ON lp.user_id = u.id
        WHERE u.id = $1`,
      [req.user.id, KYC_STATUS.APPROVED],
    );

    res.status(201).json({ post: await toPost({ ...rows[0], ...author[0] }) });
  }),
);

/**
 * Soft-deletes the caller's own post. Author-only: there is no moderation
 * path here — an admin removing someone else's post goes through the report
 * queue, not this endpoint.
 */
router.delete(
  '/:postId',
  validate(z.object({ postId: z.coerce.number().int().positive() }), 'params'),
  asyncHandler(async (req, res) => {
    const { rows } = await query(
      `UPDATE posts SET status = $1
        WHERE id = $2 AND author_user_id = $3 AND status = $4
        RETURNING id, media_path`,
      [POST_STATUS.REMOVED, req.params.postId, req.user.id, POST_STATUS.ACTIVE],
    );

    if (!rows[0]) {
      const { rows: existing } = await query(
        'SELECT author_user_id, status FROM posts WHERE id = $1',
        [req.params.postId],
      );
      if (!existing[0]) throw notFound('Post');
      // Someone else's post reads as "not found" rather than "forbidden":
      // a post id must not be confirmable by probing this endpoint.
      if (Number(existing[0].author_user_id) !== Number(req.user.id)) throw notFound('Post');
      // Own post, already removed — deleting twice is a success, not an error.
      return res.json({ ok: true, postId: Number(req.params.postId) });
    }

    // The row is already hidden; losing the object is a cost, not a bug.
    await feedStorage.remove(rows[0].media_path);

    res.json({ ok: true, postId: rows[0].id });
  }),
);

module.exports = router;
